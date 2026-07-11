import AVFoundation
import CoreMedia
import Foundation

final class AudioFileWriter {
    struct WriteResult: Equatable {
        let frameCount: Int
        let sampleRate: Double
        let channelCount: Int
    }

    private let outputURL: URL
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func write(_ sampleBuffer: CMSampleBuffer) throws -> WriteResult {
        guard
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }

        try prepareAudioFile(for: format)

        guard let audioFile, let audioFormat else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)

        try sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                bufferListNoCopy: audioBufferList.unsafePointer,
                deallocator: nil
            ) else {
                throw AudioCaptureServiceError.unableToCreateAudioBuffer
            }

            pcmBuffer.frameLength = min(AVAudioFrameCount(frameCount), pcmBuffer.frameCapacity)
            try audioFile.write(from: pcmBuffer)
        }

        return WriteResult(
            frameCount: frameCount,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    func write(_ pcmBuffer: AVAudioPCMBuffer) throws -> WriteResult {
        let format = pcmBuffer.format
        try prepareAudioFile(for: format)

        guard let audioFile, let audioFormat, audioFormat == format else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }

        try audioFile.write(from: pcmBuffer)
        return WriteResult(
            frameCount: Int(pcmBuffer.frameLength),
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    func finish() {
        audioFile = nil
        audioFormat = nil
    }

    private func prepareAudioFile(for format: AVAudioFormat) throws {
        guard audioFile == nil else { return }

        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        audioFormat = format
    }
}
