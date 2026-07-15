import Foundation

enum TranscriptSource: String, Codable, CaseIterable, Sendable {
    case system
    case microphone
}

struct TranscriptWord: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let confidence: Double?
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
    let words: [TranscriptWord]?

    init(
        id: String,
        source: TranscriptSource,
        speaker: String,
        start: Double,
        end: Double,
        language: String,
        text: String,
        confidence: Double?,
        words: [TranscriptWord]? = nil
    ) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.start = start
        self.end = end
        self.language = language
        self.text = text
        self.confidence = confidence
        self.words = words
    }
}

struct TrackTranscriptionPerformance: Codable, Equatable, Sendable {
    let audioDurationSeconds: Double
    let activeDurationSeconds: Double
    let skippedDurationSeconds: Double
    let inferenceInputDurationSeconds: Double
    let chunkCount: Int
    let wallTimeSeconds: Double

    var realTimeFactor: Double? {
        guard wallTimeSeconds > 0, wallTimeSeconds.isFinite,
              audioDurationSeconds >= 0, audioDurationSeconds.isFinite else {
            return nil
        }
        return audioDurationSeconds / wallTimeSeconds
    }
}

struct TrackTranscript: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let source: TranscriptSource
    let model: String
    let requestedLanguage: TranscriptionLanguage
    let detectedLanguage: String
    let completedAt: Date
    let segments: [TranscriptSegment]
    let performance: TrackTranscriptionPerformance?
    let provenance: TranscriptionProvenance?

    init(
        schemaVersion: Int = 2,
        source: TranscriptSource,
        model: String,
        requestedLanguage: TranscriptionLanguage,
        detectedLanguage: String,
        completedAt: Date,
        segments: [TranscriptSegment],
        performance: TrackTranscriptionPerformance? = nil,
        provenance: TranscriptionProvenance? = nil
    ) {
        self.schemaVersion = provenance == nil ? schemaVersion : max(schemaVersion, 3)
        self.source = source
        self.model = model
        self.requestedLanguage = requestedLanguage
        self.detectedLanguage = detectedLanguage
        self.completedAt = completedAt
        self.segments = segments
        self.performance = performance
        self.provenance = provenance
    }

    func recording(provenance: TranscriptionProvenance) -> TrackTranscript {
        TrackTranscript(
            schemaVersion: max(schemaVersion, 3),
            source: source,
            model: model,
            requestedLanguage: requestedLanguage,
            detectedLanguage: detectedLanguage,
            completedAt: completedAt,
            segments: segments,
            performance: performance,
            provenance: provenance
        )
    }
}

struct MergedTranscriptTrack: Codable, Equatable, Sendable {
    let source: TranscriptSource
    let model: String
    let requestedLanguage: TranscriptionLanguage
    let detectedLanguage: String
    let segmentCount: Int
    let provenance: TranscriptionProvenance?

    init(
        source: TranscriptSource,
        model: String,
        requestedLanguage: TranscriptionLanguage,
        detectedLanguage: String,
        segmentCount: Int,
        provenance: TranscriptionProvenance? = nil
    ) {
        self.source = source
        self.model = model
        self.requestedLanguage = requestedLanguage
        self.detectedLanguage = detectedLanguage
        self.segmentCount = segmentCount
        self.provenance = provenance
    }
}

struct MergedTranscript: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let title: String
    let completedAt: Date
    let tracks: [MergedTranscriptTrack]
    let segments: [TranscriptSegment]

    init(
        schemaVersion: Int = 1,
        sessionID: String,
        title: String,
        completedAt: Date,
        tracks: [MergedTranscriptTrack],
        segments: [TranscriptSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.title = title
        self.completedAt = completedAt
        self.tracks = tracks
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
