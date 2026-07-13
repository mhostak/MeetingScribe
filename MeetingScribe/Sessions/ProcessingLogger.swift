import Foundation

enum ProcessingLogEvent: String, Codable, Sendable {
    case sessionCreated
    case captureStarted
    case captureStopped
    case captureFailed
    case diskSpaceLow
    case finalizationStarted
    case finalizationCompleted
    case transcriptionStarted
    case transcriptionCompleted
    case transcriptionFailed
    case analysisCompleted
    case analysisFailed
    case exportCompleted
    case exportFailed
    case sourceAudioCleanupCompleted
    case sourceAudioCleanupFailed
    case recoveryDetected
    case recoveryStarted
    case recoveryCompleted
    case recoveryClosed
    case processingFailed
}

enum ProcessingLogAttribute: Sendable {
    case availableBytes(Int64)
    case requiredBytes(Int64)
    case bufferCount(Int)
    case frameCount(Int64)
    case sampleRate(Double)
    case channelCount(Int)
    case durationSeconds(Double)
    case systemAudioDurationSeconds(Double)
    case systemActiveDurationSeconds(Double)
    case systemSkippedDurationSeconds(Double)
    case systemInferenceInputDurationSeconds(Double)
    case systemTranscriptionWallTimeSeconds(Double)
    case systemChunkCount(Int)
    case microphoneAudioDurationSeconds(Double)
    case microphoneActiveDurationSeconds(Double)
    case microphoneSkippedDurationSeconds(Double)
    case microphoneInferenceInputDurationSeconds(Double)
    case microphoneTranscriptionWallTimeSeconds(Double)
    case microphoneChunkCount(Int)
    case model(String)
    case segmentCount(Int)
    case reason(String)

    fileprivate var pair: (String, String) {
        switch self {
        case let .availableBytes(value): return ("availableBytes", String(value))
        case let .requiredBytes(value): return ("requiredBytes", String(value))
        case let .bufferCount(value): return ("bufferCount", String(value))
        case let .frameCount(value): return ("frameCount", String(value))
        case let .sampleRate(value): return ("sampleRate", String(value))
        case let .channelCount(value): return ("channelCount", String(value))
        case let .durationSeconds(value): return ("durationSeconds", String(value))
        case let .systemAudioDurationSeconds(value): return ("systemAudioDurationSeconds", String(value))
        case let .systemActiveDurationSeconds(value): return ("systemActiveDurationSeconds", String(value))
        case let .systemSkippedDurationSeconds(value): return ("systemSkippedDurationSeconds", String(value))
        case let .systemInferenceInputDurationSeconds(value): return ("systemInferenceInputDurationSeconds", String(value))
        case let .systemTranscriptionWallTimeSeconds(value): return ("systemTranscriptionWallTimeSeconds", String(value))
        case let .systemChunkCount(value): return ("systemChunkCount", String(value))
        case let .microphoneAudioDurationSeconds(value): return ("microphoneAudioDurationSeconds", String(value))
        case let .microphoneActiveDurationSeconds(value): return ("microphoneActiveDurationSeconds", String(value))
        case let .microphoneSkippedDurationSeconds(value): return ("microphoneSkippedDurationSeconds", String(value))
        case let .microphoneInferenceInputDurationSeconds(value): return ("microphoneInferenceInputDurationSeconds", String(value))
        case let .microphoneTranscriptionWallTimeSeconds(value): return ("microphoneTranscriptionWallTimeSeconds", String(value))
        case let .microphoneChunkCount(value): return ("microphoneChunkCount", String(value))
        case let .model(value): return ("model", value)
        case let .segmentCount(value): return ("segmentCount", String(value))
        case let .reason(value): return ("reason", value)
        }
    }
}

actor ProcessingLogger {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    func log(
        _ event: ProcessingLogEvent,
        for session: RecordingSession,
        attributes: [ProcessingLogAttribute] = []
    ) throws {
        var details: [String: String] = [:]
        for attribute in attributes {
            let (key, value) = attribute.pair
            details[key] = sanitize(value)
        }
        let entry = ProcessingLogEntry(
            timestamp: now(),
            event: event,
            details: details
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(0x0A)

        let url = session.processingLogURL
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func sanitize(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: "(?i)bearer\\s+[a-z0-9._-]+",
                with: "Bearer [REDACTED]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "sk-[a-zA-Z0-9_-]{8,}",
                with: "[REDACTED]",
                options: .regularExpression
            )
        if result.count > 500 {
            result = String(result.prefix(500)) + "…"
        }
        return result
    }
}

private struct ProcessingLogEntry: Codable {
    let timestamp: Date
    let event: ProcessingLogEvent
    let details: [String: String]
}
