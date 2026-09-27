import CoreAudio
import Foundation
import Synchronization

/// Gain shared between the main thread (writer) and the realtime IOProc (reader).
final class TapGain: @unchecked Sendable {
    private let targetBits: Atomic<UInt32>
    private var current: Float  // touched only on the audio thread

    /// ~10 ms full-scale ramp at 48 kHz, which avoids clicks when the slider moves.
    private static let maxStepPerFrame: Float = 1.0 / 480

    /// Starts at `startGain` and ramps to `gain`, e.g. from native full volume (1) down
    /// to the slider's value when an app is first routed.
    init(_ gain: Float, startGain: Float) {
        targetBits = Atomic(gain.bitPattern)
        current = startGain
    }

    func setTarget(_ gain: Float) {
        targetBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// - Parameter tapChannelCount: The tap's channel count, used to find where the
    ///   tap's own buffer(s) start in `input`. The aggregate's sub-device (the real
    ///   output device) may itself have input streams — e.g. a USB headset or a
    ///   display's built-in mic — which precede the tap's stream(s) in the IOProc's
    ///   input buffer list. Mixing those in would replay the microphone instead of
    ///   (or in addition to) the tapped app.
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

    /// Walks backward from the last input buffer, summing channels, until the tap's
    /// channel count is reached — that index is where the tap's own buffer(s) begin.
    /// Falls back to 0 (use everything) if the buffers never add up to that count.
    /// Allocation-free: a fixed-size loop over the buffer list.
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

/// A process tap, abstracted so `AppVolumeController` can be tested with a fake.
/// `ProcessTap` is the only production conformance.
protocol AudioTap: AnyObject {
    var processObjectIDs: [AudioObjectID] { get }
    var outputUID: String { get }
    /// Moves the running tap to another output device without stopping its IO.
    func retarget(outputUID: String) throws
    func setGain(_ value: Float)
    func invalidate()
}

/// One process tap (muted only while OneMix is reading it), a private aggregate device (output device + tap), and an
/// IOProc that replays the tapped audio with gain. Destroying it restores native audio.
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
        // Mute the app's own output only while our IOProc is reading the tap, so there is
        // no silent gap between creating the tap and the aggregate device starting.
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

    /// Swaps the aggregate's output sub-device in place. Stopping and restarting a tap's IO
    /// on an output change makes macOS Bluetooth smart routing "hijack" the output back to
    /// in-ear AirPods on OneMix's behalf; keeping the same running aggregate avoids that.
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

    /// Idempotent teardown. Once the tap is destroyed, the app plays natively again.
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
