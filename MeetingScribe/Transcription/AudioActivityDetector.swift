import AVFoundation
import Foundation

/// Lightweight, engine-neutral protection for completely silent or negligible tracks.
///
/// It never compacts audio or changes timestamps. A track with at least three
/// 64 ms windows above -45 dBFS is passed to the speech engine unchanged.
struct AudioActivityDetector: Sendable {
    private let windowFrameCount: AVAudioFrameCount = 1_024
    private let minimumWindowRMS = pow(10.0, -45.0 / 20.0)
    private let minimumActiveWindowCount = 3

    func hasMeaningfulActivity(at url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            abs(format.sampleRate - WorkingAudioConverter.targetSampleRate) < 0.5,
            format.channelCount == WorkingAudioConverter.targetChannelCount
        else {
            throw TranscriptionError.invalidAudioFormat(
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount)
            )
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: windowFrameCount
        ) else {
            throw TranscriptionError.engineInferenceFailed(
                engine: "Audio activity detector",
                detail: "The audio buffer could not be allocated."
            )
        }

        var activeWindowCount = 0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: windowFrameCount)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
                break
            }

            var squaredSum = 0.0
            for index in 0..<Int(buffer.frameLength) {
                let sample = Double(channel[index])
                if sample.isFinite {
                    squaredSum += sample * sample
                }
            }
            let rms = sqrt(squaredSum / Double(buffer.frameLength))
            if rms >= minimumWindowRMS {
                activeWindowCount += 1
                if activeWindowCount >= minimumActiveWindowCount {
                    return true
                }
            }
        }
        return false
    }
}
