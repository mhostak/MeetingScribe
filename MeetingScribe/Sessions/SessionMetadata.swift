import Foundation

enum RecordingSessionStatus: String, Codable, Sendable {
    case recording
    case recorded
    case failed
}
enum TranscriptionLanguage: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic = "auto"
    case czech = "cs"
    case slovak = "sk"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto"
        case .czech:
            return "Čeština"
        case .slovak:
            return "Slovenčina"
        case .english:
            return "English"
        }
    }

    var selectionHint: String {
        switch self {
        case .automatic:
            return "Best for mixed-language meetings. Whisper selects one dominant language per audio track."
        case .czech:
            return "Force Czech transcription for meetings spoken primarily in Czech."
        case .slovak:
            return "Force Slovak transcription for meetings spoken primarily in Slovak."
        case .english:
            return "Force English transcription for meetings spoken primarily in English."
        }
    }
}

struct SessionAudioFiles: Codable, Equatable, Sendable {
    var system = "system-16k.wav"
    var microphone = "microphone-16k.wav"
    var systemWorking: String? = nil
    var microphoneWorking: String? = nil
    var mixed = "mixed.wav"
}

struct SessionTranscriptFiles: Codable, Equatable, Sendable {
    var systemTrack = "system-transcript.json"
    var microphoneTrack = "microphone-transcript.json"
    var merged = "transcript.json"
    var analysis: String? = "analysis.json"
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

enum AudioSourceCleanupStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
}

struct AudioSourceCleanupMetadata: Codable, Equatable, Sendable {
    var status: AudioSourceCleanupStatus
    var completedAt: Date
    var deletedFiles: [String]
    var failureReason: String?
}

enum SessionTranscriptionStatus: String, Codable, Sendable {
    case completed
    case failed
    case modelMissing
}

struct SessionTranscriptionMetadata: Codable, Equatable, Sendable {
    var status: SessionTranscriptionStatus
    var model: String
    var startedAt: Date?
    var completedAt: Date?
    var systemSegmentCount: Int?
    var microphoneSegmentCount: Int?
    var mergedSegmentCount: Int? = nil
    var systemPerformance: TrackTranscriptionPerformance? = nil
    var microphonePerformance: TrackTranscriptionPerformance? = nil
    var warnings: [String]
    var failureReason: String?
}

enum SessionAnalysisStatus: String, Codable, Sendable {
    case completed
    case failed
    case missingAPIKey
}

struct SessionAnalysisMetadata: Codable, Equatable, Sendable {
    var status: SessionAnalysisStatus
    var provider: String
    var model: String
    var startedAt: Date?
    var completedAt: Date?
    var transcriptChunkCount: Int?
    var requestCount: Int?
    var failureReason: String?
}

enum SessionOutputStatus: String, Codable, Sendable {
    case completed
    case failed
}

enum SessionRecoveryStatus: String, Codable, Sendable {
    case inProgress
    case completed
    case failed
    case closed
}

struct SessionRecoveryMetadata: Codable, Equatable, Sendable {
    var status: SessionRecoveryStatus
    var originalStatus: RecordingSessionStatus
    var detectedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var attemptCount: Int
    var failureReason: String?
}

struct SessionOutputMetadata: Codable, Equatable, Sendable {
    var status: SessionOutputStatus
    var markdownFileName: String?
    var markdownPath: String?
    var exportedAt: Date?
    var failureReason: String?
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
    var outputLanguage: OutputLanguage?
    var outputFileNameTemplate: String?
    var calendarEvent: CalendarEventSnapshot?
    var audioFiles: SessionAudioFiles
    var transcriptFiles: SessionTranscriptFiles?
    var systemAudio: AudioTrackMetadata?
    var microphoneAudio: AudioTrackMetadata?
    var audioFinalization: AudioFinalizationMetadata?
    var audioSourceCleanup: AudioSourceCleanupMetadata?
    var transcription: SessionTranscriptionMetadata?
    var analysis: SessionAnalysisMetadata?
    var output: SessionOutputMetadata?
    var recovery: SessionRecoveryMetadata?
    var failureReason: String?

    init(
        schemaVersion: Int = 10,
        id: String,
        title: String,
        status: RecordingSessionStatus,
        createdAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        language: TranscriptionLanguage = .automatic,
        outputLanguage: OutputLanguage? = .slovak,
        outputFileNameTemplate: String? = MarkdownFileNameTemplate.defaultValue,
        calendarEvent: CalendarEventSnapshot? = nil,
        audioFiles: SessionAudioFiles = SessionAudioFiles(),
        transcriptFiles: SessionTranscriptFiles? = SessionTranscriptFiles(),
        systemAudio: AudioTrackMetadata? = nil,
        microphoneAudio: AudioTrackMetadata? = nil,
        audioFinalization: AudioFinalizationMetadata? = nil,
        audioSourceCleanup: AudioSourceCleanupMetadata? = nil,
        transcription: SessionTranscriptionMetadata? = nil,
        analysis: SessionAnalysisMetadata? = nil,
        output: SessionOutputMetadata? = nil,
        recovery: SessionRecoveryMetadata? = nil,
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
        self.outputLanguage = outputLanguage
        self.outputFileNameTemplate = outputFileNameTemplate
        self.calendarEvent = calendarEvent
        self.audioFiles = audioFiles
        self.transcriptFiles = transcriptFiles
        self.systemAudio = systemAudio
        self.microphoneAudio = microphoneAudio
        self.audioFinalization = audioFinalization
        self.audioSourceCleanup = audioSourceCleanup
        self.transcription = transcription
        self.analysis = analysis
        self.output = output
        self.recovery = recovery
        self.failureReason = failureReason
    }

    var resolvedOutputLanguage: OutputLanguage {
        outputLanguage ?? .slovak
    }

    var resolvedOutputFileNameTemplate: String {
        MarkdownFileNameTemplate.normalized(
            outputFileNameTemplate ?? MarkdownFileNameTemplate.defaultValue
        )
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
