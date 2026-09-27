import CoreAudio
import XCTest
@testable import OneMixCore

final class SampleMixerTests: XCTestCase {
    private var allocated: [UnsafeMutableAudioBufferListPointer] = []

    override func tearDown() {
        for list in allocated {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        allocated = []
    }

    /// Builds a buffer list; each entry is (channels in that buffer, interleaved samples).
    private func makeList(_ buffers: [(channels: Int, samples: [Float])]) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
        list.count = buffers.count
        for (index, buffer) in buffers.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(buffer.samples.count, 1))
            data.initialize(from: buffer.samples, count: buffer.samples.count)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(buffer.channels),
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
        allocated.append(list)
        return list
    }

    private func samples(_ list: UnsafeMutableAudioBufferListPointer, buffer: Int) -> [Float] {
        let audioBuffer = list[buffer]
        let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: audioBuffer.mData!.assumingMemoryBound(to: Float.self), count: count))
    }

    func testInterleavedStereoCopiesWithGain() {
        let input = makeList([(2, [1, -1, 0.5, -0.5])])
        let output = makeList([(2, [9, 9, 9, 9])])
        let gain = SampleMixer.process(input: input, output: output, currentGain: 0.5, targetGain: 0.5, maxStepPerFrame: 0.01)
        XCTAssertEqual(samples(output, buffer: 0), [0.5, -0.5, 0.25, -0.25])
        XCTAssertEqual(gain, 0.5)
    }

    func testInterleavedInputToNonInterleavedOutput() {
        let input = makeList([(2, [1, 2, 3, 4])])
        let output = makeList([(1, [0, 0]), (1, [0, 0])])
        _ = SampleMixer.process(input: input, output: output, currentGain: 1, targetGain: 1, maxStepPerFrame: 0.01)
        XCTAssertEqual(samples(output, buffer: 0), [1, 3])
        XCTAssertEqual(samples(output, buffer: 1), [2, 4])
    }

    func testMonoInputFillsBothOutputChannels() {
        let input = makeList([(1, [1, 2])])
        let output = makeList([(2, [0, 0, 0, 0])])
        _ = SampleMixer.process(input: input, output: output, currentGain: 1, targetGain: 1, maxStepPerFrame: 0.01)
        XCTAssertEqual(samples(output, buffer: 0), [1, 1, 2, 2])
    }

    func testGainRampsTowardTargetPerFrame() {
        let input = makeList([(1, [1, 1, 1, 1])])
        let output = makeList([(1, [0, 0, 0, 0])])
        let gain = SampleMixer.process(input: input, output: output, currentGain: 0, targetGain: 1, maxStepPerFrame: 0.25)
        XCTAssertEqual(samples(output, buffer: 0), [0.25, 0.5, 0.75, 1])
        XCTAssertEqual(gain, 1)
    }

    func testRampReturnsPartialGainWhenTargetNotReached() {
        let input = makeList([(1, [1, 1, 1, 1])])
        let output = makeList([(1, [0, 0, 0, 0])])
        let gain = SampleMixer.process(input: input, output: output, currentGain: 1, targetGain: 0, maxStepPerFrame: 0.1)
        XCTAssertEqual(gain, 0.6, accuracy: 0.0001)
    }

    func testOutputLongerThanInputIsZeroPadded() {
        let input = makeList([(1, [1, 1])])
        let output = makeList([(1, [9, 9, 9, 9])])
        _ = SampleMixer.process(input: input, output: output, currentGain: 1, targetGain: 1, maxStepPerFrame: 0.01)
        XCTAssertEqual(samples(output, buffer: 0), [1, 1, 0, 0])
    }

    func testFirstInputBufferSkipsPrecedingMicBuffer() {
        let input = makeList([(1, [9, 9]), (2, [1, 2, 3, 4])])
        let output = makeList([(2, [0, 0, 0, 0])])
        _ = SampleMixer.process(
            input: input,
            output: output,
            currentGain: 1,
            targetGain: 1,
            maxStepPerFrame: 0.01,
            firstInputBuffer: 1
        )
        XCTAssertEqual(samples(output, buffer: 0), [1, 2, 3, 4])
    }

    func testEmptyInputProducesSilence() {
        let input = makeList([])
        let output = makeList([(2, [9, 9])])
        _ = SampleMixer.process(input: input, output: output, currentGain: 1, targetGain: 1, maxStepPerFrame: 0.01)
        XCTAssertEqual(samples(output, buffer: 0), [0, 0])
    }
}
