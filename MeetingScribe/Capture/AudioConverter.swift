import AVFoundation
import Foundation

private final class AudioConversionInputState: @unchecked Sendable {
    let inputFile: AVAudioFile
    var reachedEnd = false
    var readFailure: Error?

    init(inputFile: AVAudioFile) {
        self.inputFile = inputFile
    }
}

struct ConvertedAudioFile: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let totalFrames: Int64

    var durationSeconds: Double {
        sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }
}

enum AudioConverterLoopAction: Equatable, Sendable {
    case continueConversion
    case finish
    case fail
}

struct AudioConverterDrainPolicy: Sendable {
    private(set) var consecutiveEmptyDrains = 0

    mutating func action(
        for status: AVAudioConverterOutputStatus,
        producedFrameCount: AVAudioFrameCount,
        reachedInputEnd: Bool
    ) -> AudioConverterLoopAction {
        if producedFrameCount > 0 {
            consecutiveEmptyDrains = 0
        } else if reachedInputEnd {
            consecutiveEmptyDrains += 1
        }

        switch status {
        case .haveData:
            return .continueConversion
        case .inputRanDry:
            return reachedInputEnd
                && consecutiveEmptyDrains >= WorkingAudioConverter.maximumConsecutiveEmptyDrainCycles
                ? .finish
                : .continueConversion
        case .endOfStream:
            return .finish
        case .error:
            return .fail
        @unknown default:
            return .fail
        }
    }
}

/// Converts one captured CAF into the engine-neutral 16 kHz mono PCM working format.
struct WorkingAudioConverter: Sendable {
    static let targetSampleRate = 16_000.0
    static let targetChannelCount: AVAudioChannelCount = 1
    /// Bounds the fallback drain loop when AVAudioConverter reaches input EOF
    /// but never emits an explicit `.endOfStream` status.
    static let maximumConsecutiveEmptyDrainCycles = 2

    func convert(inputURL: URL, outputURL: URL) throws -> ConvertedAudioFile {
        try Task.checkCancellation()
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            throw AudioConversionError.unreadableInput(
                fileName: inputURL.lastPathComponent,
                reason: error.localizedDescription
            )
        }

        guard inputFile.length > 0 else {
            throw AudioConversionError.emptyInput(fileName: inputURL.lastPathComponent)
        }

        let inputFormat = inputFile.processingFormat
        guard
            inputFormat.sampleRate > 0,
            inputFormat.channelCount > 0,
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.targetSampleRate,
                channels: Self.targetChannelCount,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw AudioConversionError.unsupportedFormat(fileName: inputURL.lastPathComponent)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        var shouldRemoveIncompleteOutput = true
        defer {
            if shouldRemoveIncompleteOutput {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        var outputFile: AVAudioFile? = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )

        let outputCapacity: AVAudioFrameCount = 4_096
        let inputState = AudioConversionInputState(inputFile: inputFile)
        // AVAudioConverter may report `.inputRanDry` after the input callback
        // has reached EOF while still holding delayed output internally. Keep
        // calling it with `.endOfStream`; two consecutive empty drain cycles
        // are the bounded termination heuristic when no explicit
        // `.endOfStream` status arrives. Any produced frame resets the count.
        var drainPolicy = AudioConverterDrainPolicy()

        conversionLoop: while true {
            try Task.checkCancellation()
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw AudioConversionError.unableToAllocateBuffer
            }

            var conversionFailure: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionFailure
            ) { requestedPackets, inputStatus in
                guard !inputState.reachedEnd else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                let remainingFrames = inputState.inputFile.length
                    - inputState.inputFile.framePosition
                guard remainingFrames > 0 else {
                    inputState.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let frameCount = min(
                    requestedPackets,
                    AVAudioFrameCount(remainingFrames)
                )

                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: frameCount
                ) else {
                    inputState.readFailure = AudioConversionError.unableToAllocateBuffer
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try inputState.inputFile.read(
                        into: inputBuffer,
                        frameCount: frameCount
                    )
                } catch {
                    inputState.readFailure = error
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                guard inputBuffer.frameLength > 0 else {
                    inputState.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let readFailure = inputState.readFailure {
                throw AudioConversionError.readFailed(reason: readFailure.localizedDescription)
            }
            if let conversionFailure {
                throw AudioConversionError.conversionFailed(reason: conversionFailure.localizedDescription)
            }

            if outputBuffer.frameLength > 0 {
                try outputFile?.write(from: outputBuffer)
            }

            switch drainPolicy.action(
                for: status,
                producedFrameCount: outputBuffer.frameLength,
                reachedInputEnd: inputState.reachedEnd
            ) {
            case .continueConversion:
                continue
            case .finish:
                break conversionLoop
            case .fail:
                throw AudioConversionError.conversionFailed(
                    reason: conversionFailure?.localizedDescription ?? "Unknown converter error."
                )
            }
        }

        outputFile = nil

        let finalizedFile = try AVAudioFile(forReading: outputURL)
        let finalizedFormat = finalizedFile.fileFormat
        guard finalizedFile.length > 0 else {
            throw AudioConversionError.emptyOutput(fileName: outputURL.lastPathComponent)
        }

        let result = ConvertedAudioFile(
            sampleRate: finalizedFormat.sampleRate,
            channelCount: Int(finalizedFormat.channelCount),
            totalFrames: finalizedFile.length
        )
        shouldRemoveIncompleteOutput = false
        return result
    }
}

enum AudioConversionError: Error, LocalizedError {
    case unreadableInput(fileName: String, reason: String)
    case emptyInput(fileName: String)
    case unsupportedFormat(fileName: String)
    case unableToAllocateBuffer
    case readFailed(reason: String)
    case conversionFailed(reason: String)
    case emptyOutput(fileName: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableInput(fileName, reason):
            return "Unable to read \(fileName): \(reason)"
        case let .emptyInput(fileName):
            return "Audio track \(fileName) is empty."
        case let .unsupportedFormat(fileName):
            return "Audio track \(fileName) has an unsupported format."
        case .unableToAllocateBuffer:
            return "Unable to allocate an audio conversion buffer."
        case let .readFailed(reason):
            return "Audio conversion could not read input data: \(reason)"
        case let .conversionFailed(reason):
            return "Audio conversion failed: \(reason)"
        case let .emptyOutput(fileName):
            return "Converted audio track \(fileName) is empty."
        }
    }
}
