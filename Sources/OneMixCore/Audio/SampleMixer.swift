import CoreAudio

/// Copies tapped audio to the output with gain. Runs on the realtime audio
/// thread, so it must not allocate, lock, or call into Swift runtime-heavy APIs.
public enum SampleMixer {
    @inline(__always)
    static func approach(_ from: Float, _ to: Float, maxDelta: Float) -> Float {
        let delta = to - from
        if abs(delta) <= maxDelta { return to }
        return from + (delta > 0 ? maxDelta : -maxDelta)
    }

    /// Returns the gain reached at the end of the buffer.
    ///
    /// - Parameter firstInputBuffer: Input buffers at indices below this are ignored
    ///   entirely — not counted toward the channel count and never used as a source.
    ///   Used to skip the aggregate's own input streams (e.g. a headset mic) that
    ///   precede the tap's buffer(s) in the IOProc's input list.
    public static func process(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        currentGain: Float,
        targetGain: Float,
        maxStepPerFrame: Float,
        firstInputBuffer: Int = 0
    ) -> Float {
        let sampleSize = MemoryLayout<Float>.size
        let inputCount = input.count
        let start = min(max(firstInputBuffer, 0), inputCount)
        var inputChannelCount = 0
        for i in start..<inputCount { inputChannelCount += Int(input[i].mNumberChannels) }

        var maxOutputFrames = 0
        var outputChannelBase = 0
        for outBuffer in output {
            let outChannels = Int(outBuffer.mNumberChannels)
            defer { outputChannelBase += outChannels }
            guard outChannels > 0, let outData = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outFrames = Int(outBuffer.mDataByteSize) / (sampleSize * outChannels)
            maxOutputFrames = max(maxOutputFrames, outFrames)

            for channel in 0..<outChannels {
                // Locate the source channel (output channel c reads input channel c % inputChannelCount).
                var source: UnsafeMutablePointer<Float>?
                var sourceStride = 1
                var sourceFrames = 0
                if inputChannelCount > 0 {
                    var wanted = (outputChannelBase + channel) % inputChannelCount
                    for i in start..<inputCount {
                        let inBuffer = input[i]
                        let inChannels = Int(inBuffer.mNumberChannels)
                        if wanted < inChannels {
                            if let inData = inBuffer.mData?.assumingMemoryBound(to: Float.self) {
                                source = inData + wanted
                                sourceStride = inChannels
                                sourceFrames = Int(inBuffer.mDataByteSize) / (sampleSize * inChannels)
                            }
                            break
                        }
                        wanted -= inChannels
                    }
                }

                let copiedFrames = min(outFrames, sourceFrames)
                for frame in 0..<outFrames {
                    let destination = outData + frame * outChannels + channel
                    if frame < copiedFrames, let source {
                        let gain = approach(currentGain, targetGain, maxDelta: maxStepPerFrame * Float(frame + 1))
                        destination.pointee = source[frame * sourceStride] * gain
                    } else {
                        destination.pointee = 0
                    }
                }
            }
        }
        return approach(currentGain, targetGain, maxDelta: maxStepPerFrame * Float(maxOutputFrames))
    }
}
