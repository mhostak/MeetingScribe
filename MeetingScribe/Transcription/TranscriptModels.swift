import Foundation

enum TranscriptSource: String, Codable, CaseIterable, Sendable {
    case system
    case microphone
}

struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let source: TranscriptSource
    let speaker: String
    let start: Double
    let end: Double
    let language: String
    let text: String
    let confidence: Double?
}

struct TrackTranscript: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let source: TranscriptSource
    let model: String
    let requestedLanguage: TranscriptionLanguage
    let detectedLanguage: String
    let completedAt: Date
    let segments: [TranscriptSegment]

    init(
        schemaVersion: Int = 1,
        source: TranscriptSource,
        model: String,
        requestedLanguage: TranscriptionLanguage,
        detectedLanguage: String,
        completedAt: Date,
        segments: [TranscriptSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.model = model
        self.requestedLanguage = requestedLanguage
        self.detectedLanguage = detectedLanguage
        self.completedAt = completedAt
        self.segments = segments
    }
}

struct TranscriptionOptions: Equatable, Sendable {
    var language: TranscriptionLanguage
    var source: TranscriptSource
    var speaker: String
    var timelineOffsetSeconds: Double
    var initialPrompt: String?

    init(
        language: TranscriptionLanguage = .automatic,
        source: TranscriptSource,
        speaker: String,
        timelineOffsetSeconds: Double = 0,
        initialPrompt: String? = nil
    ) {
        self.language = language
        self.source = source
        self.speaker = speaker
        self.timelineOffsetSeconds = timelineOffsetSeconds
        self.initialPrompt = initialPrompt
    }
}

enum TranscriptJSONCoder {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
