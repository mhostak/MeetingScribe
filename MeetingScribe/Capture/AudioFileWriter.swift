import AVFoundation
import CoreMedia
import Foundation

final class AudioFileWriter {
    private final class ConversionInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var wasSupplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

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

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)

        return try sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: audioBufferList.unsafePointer,
                deallocator: nil
            ) else {
                throw AudioCaptureServiceError.unableToCreateAudioBuffer
            }

            pcmBuffer.frameLength = min(AVAudioFrameCount(frameCount), pcmBuffer.frameCapacity)
            return try write(pcmBuffer)
        }
    }

    func write(_ pcmBuffer: AVAudioPCMBuffer) throws -> WriteResult {
        let format = pcmBuffer.format
        try prepareAudioFile(for: format)

        guard let audioFile, let audioFormat else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }

        let writtenFrameCount: Int
        if audioFormat == format {
            try audioFile.write(from: pcmBuffer)
            writtenFrameCount = Int(pcmBuffer.frameLength)
        } else {
            let convertedBuffers = try convert(pcmBuffer, to: audioFormat)
            for convertedBuffer in convertedBuffers {
                try audioFile.write(from: convertedBuffer)
            }
            writtenFrameCount = convertedBuffers.reduce(0) {
                $0 + Int($1.frameLength)
            }
        }

        return WriteResult(
            frameCount: writtenFrameCount,
            sampleRate: audioFormat.sampleRate,
            channelCount: Int(audioFormat.channelCount)
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

    private func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        guard
            inputBuffer.format.sampleRate > 0,
            let converter = AVAudioConverter(
                from: inputBuffer.format,
                to: outputFormat
            )
        else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let estimatedFrames = ceil(Double(inputBuffer.frameLength) * ratio)
        let outputCapacity = AVAudioFrameCount(max(1, estimatedFrames + 64))
        let conversionInput = ConversionInput(buffer: inputBuffer)
        var outputs: [AVAudioPCMBuffer] = []

        for _ in 0..<8 {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw AudioCaptureServiceError.unableToCreateAudioBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                guard !conversionInput.wasSupplied else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                conversionInput.wasSupplied = true
                inputStatus.pointee = .haveData
                return conversionInput.buffer
            }

            if let conversionError {
                throw conversionError
            }
            if outputBuffer.frameLength > 0 {
                outputs.append(outputBuffer)
            }

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                guard !outputs.isEmpty else {
                    throw AudioCaptureServiceError.unableToCreateAudioBuffer
                }
                return outputs
            case .error:
                throw AudioCaptureServiceError.invalidAudioFormat
            @unknown default:
                throw AudioCaptureServiceError.invalidAudioFormat
            }
        }

        throw AudioCaptureServiceError.invalidAudioFormat
    }
}
