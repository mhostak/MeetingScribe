import AVFoundation
import Foundation

struct WhisperAudioReader: Sendable {
    func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.fileFormat
        guard
            abs(fileFormat.sampleRate - WorkingAudioConverter.targetSampleRate) < 0.5,
            fileFormat.channelCount == WorkingAudioConverter.targetChannelCount
        else {
            throw TranscriptionError.invalidAudioFormat(
                sampleRate: fileFormat.sampleRate,
                channelCount: Int(fileFormat.channelCount)
            )
        }

        let processingFormat = file.processingFormat
        guard processingFormat.commonFormat == .pcmFormatFloat32 else {
            throw TranscriptionError.invalidAudioFormat(
                sampleRate: processingFormat.sampleRate,
                channelCount: Int(processingFormat.channelCount)
            )
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let chunkSize: AVAudioFrameCount = 65_536

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frameCount = min(chunkSize, AVAudioFrameCount(remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: frameCount
            ) else {
                throw TranscriptionError.emptyAudio
            }

            try file.read(into: buffer, frameCount: frameCount)
            guard let channel = buffer.floatChannelData?[0] else {
                throw TranscriptionError.invalidAudioFormat(
                    sampleRate: processingFormat.sampleRate,
                    channelCount: Int(processingFormat.channelCount)
                )
            }
            samples.append(contentsOf: UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            ))
        }

        guard !samples.isEmpty else {
            throw TranscriptionError.emptyAudio
        }
        return samples
    }
}
