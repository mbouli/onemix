import CoreAudio
import Foundation
import Synchronization

/// Gain shared between the main thread (writer) and the realtime IOProc (reader).
final class TapGain: @unchecked Sendable {
    private let targetBits: Atomic<UInt32>
    private var current: Float  // audio thread only

    /// Full-scale ramp of ~10 ms at 48 kHz, to avoid zipper noise.
    private static let maxStepPerFrame: Float = 1.0 / 480

    /// Ramps from `startGain` to `gain`, so a newly routed app fades from its native level.
    init(_ gain: Float, startGain: Float) {
        targetBits = Atomic(gain.bitPattern)
        current = startGain
    }

    func setTarget(_ gain: Float) {
        targetBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// - Parameter tapChannelCount: Used to locate the tap's buffers in `input`. The output
    ///   device may have its own input streams (a headset mic, for example), and these come
    ///   before the tap's streams in the aggregate's buffer list.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, tapChannelCount: Int) {
        let target = Float(bitPattern: targetBits.load(ordering: .relaxed))
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        current = SampleMixer.process(
            input: inputList,
            output: UnsafeMutableAudioBufferListPointer(output),
            currentGain: current,
            targetGain: target,
            maxStepPerFrame: Self.maxStepPerFrame,
            firstInputBuffer: Self.firstTapBuffer(in: inputList, tapChannelCount: tapChannelCount)
        )
    }

    /// Index of the first tap buffer, found by summing channels backward from the last
    /// buffer. Returns 0 if the counts don't line up. Allocation-free.
    private static func firstTapBuffer(in input: UnsafeMutableAudioBufferListPointer, tapChannelCount: Int) -> Int {
        guard tapChannelCount > 0 else { return 0 }
        var channelsSeen = 0
        var index = input.count
        while index > 0 {
            index -= 1
            channelsSeen += Int(input[index].mNumberChannels)
            if channelsSeen >= tapChannelCount { return index }
        }
        return 0
    }
}

/// Abstraction over `ProcessTap` so `AppVolumeController` can be tested.
protocol AudioTap: AnyObject {
    var processObjectIDs: [AudioObjectID] { get }
    var outputUID: String { get }
    /// Retargets the running tap to another output device without stopping IO.
    func retarget(outputUID: String) throws
    func setGain(_ value: Float)
    func invalidate()
}

/// A process tap, a private aggregate device combining it with the output, and an IOProc
/// that replays the tapped audio with gain. Invalidating it restores native playback.
final class ProcessTap: AudioTap {
    let processObjectIDs: [AudioObjectID]
    private(set) var outputUID: String

    private let gain: TapGain
    private let queue = DispatchQueue(label: "com.onemix.tap", qos: .userInteractive)
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjectIDs: [AudioObjectID], outputUID: String, gain: Float, startGain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputUID
        self.gain = TapGain(gain, startGain: startGain)
        do {
            try start()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    func setGain(_ value: Float) {
        gain.setTarget(value)
    }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "OneMix"
        description.isPrivate = true
        // Mute only while the IOProc is reading, so there is no gap before the aggregate starts.
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        let tapChannelCount: Int
        if let format = try? CA.get(tapID, CA.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription()),
            format.mChannelsPerFrame > 0
        {
            tapChannelCount = Int(format.mChannelsPerFrame)
        } else {
            tapChannelCount = 2
        }

        let driftCompensation = OutputDeviceManager.outputDevice(uid: outputUID)?.transport.usesTapDriftCompensation ?? true
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OneMix",
            kAudioAggregateDeviceUIDKey: OneMixIDs.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: driftCompensation,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        let gain = self.gain
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
                gain.render(input: input, output: output, tapChannelCount: tapChannelCount)
            },
            "create IOProc"
        )
        try check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
    }

    /// Swaps the aggregate's output sub-device in place. Restarting IO instead triggers
    /// Bluetooth automatic switching, which routes output back to AirPods that are in-ear.
    func retarget(outputUID newUID: String) throws {
        let subDevices = [newUID] as CFArray
        var address = CA.address(kAudioAggregateDevicePropertyFullSubDeviceList)
        try withUnsafePointer(to: subDevices) {
            try check(
                AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0),
                "set aggregate sub-devices"
            )
        }
        let mainUID = newUID as CFString
        address = CA.address(kAudioAggregateDevicePropertyMainSubDevice)
        try withUnsafePointer(to: mainUID) {
            try check(
                AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), $0),
                "set aggregate main sub-device"
            )
        }
        outputUID = newUID
    }

    /// Tears down the tap and restores native playback. Safe to call more than once.
    func invalidate() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }
}
