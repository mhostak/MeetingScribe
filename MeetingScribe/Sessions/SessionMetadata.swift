import Foundation

enum RecordingSessionStatus: String, Codable, Sendable {
    case recording
    case recorded
    case failed
}
enum TranscriptionLanguage: String, Codable, Sendable {
    case automatic = "auto"
    case slovak = "sk"
    case czech = "cs"
    case english = "en"
}

struct SessionAudioFiles: Codable, Equatable, Sendable {
    var system = "system.caf"
    var microphone = "microphone.caf"
    var systemWorking: String? = "system-16k.wav"
    var microphoneWorking: String? = "microphone-16k.wav"
    var mixed = "mixed.wav"
}

struct AudioTrackMetadata: Codable, Equatable, Sendable {
    var fileName: String
    var sampleRate: Double?
    var channelCount: Int?
    var bufferCount: Int
    var totalFrames: Int64
    var firstPresentationTimestamp: Double?
    var lastPresentationTimestamp: Double?
    var capturedDurationSeconds: Double?
    var failureReason: String?
}

struct FinalizedAudioTrackMetadata: Codable, Equatable, Sendable {
    var fileName: String
    var sampleRate: Double
    var channelCount: Int
    var totalFrames: Int64
    var durationSeconds: Double
    var timelineOffsetSeconds: Double
}

struct AudioFinalizationMetadata: Codable, Equatable, Sendable {
    var completedAt: Date
    var timelineOrigin: Double
    var system: FinalizedAudioTrackMetadata
    var microphone: FinalizedAudioTrackMetadata?
    var warnings: [String]
}

struct SessionMetadata: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: String
    var title: String
    var status: RecordingSessionStatus
    let createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var language: TranscriptionLanguage
    var audioFiles: SessionAudioFiles
    var systemAudio: AudioTrackMetadata?
    var microphoneAudio: AudioTrackMetadata?
    var audioFinalization: AudioFinalizationMetadata?
    var failureReason: String?

    init(
        schemaVersion: Int = 2,
        id: String,
        title: String,
        status: RecordingSessionStatus,
        createdAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        language: TranscriptionLanguage = .automatic,
        audioFiles: SessionAudioFiles = SessionAudioFiles(),
        systemAudio: AudioTrackMetadata? = nil,
        microphoneAudio: AudioTrackMetadata? = nil,
        audioFinalization: AudioFinalizationMetadata? = nil,
        failureReason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.audioFiles = audioFiles
        self.systemAudio = systemAudio
        self.microphoneAudio = microphoneAudio
        self.audioFinalization = audioFinalization
        self.failureReason = failureReason
    }
}

enum SessionJSONCoder {
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
