import Foundation

enum RecordingSessionStatus: String, Codable, Sendable {
    case recording
    case recorded
    case failed
}

enum CaptureMode: String, Codable, Hashable, Sendable {
    case systemAndMicrophone
    // Retained so recordings created by older versions can still be decoded
    // and recovered. New recordings always use systemAndMicrophone.
    case microphoneOnly
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
            return "Best for mixed-language meetings. No language hint is forced on the transcription engine."
        case .czech:
            return "Prefer Czech transcription for meetings spoken primarily in Czech."
        case .slovak:
            return "Prefer Slovak transcription for meetings spoken primarily in Slovak."
        case .english:
            return "Prefer English transcription for meetings spoken primarily in English."
        }
    }
}

struct SessionAudioFiles: Codable, Equatable, Sendable {
    var system = "system-16k.wav"
    var microphone = "microphone-16k.wav"
    var systemWorking: String? = nil
    var microphoneWorking: String? = nil
    // Legacy sessions may contain this pre-direct-PCM mix. It is retained so
    // storage cleanup can discover it without deleting an unrecognized file.
    var mixed = "mixed.wav"
}

struct SessionTranscriptFiles: Codable, Equatable, Sendable {
    var systemTrack = "system-transcript.json"
    var microphoneTrack = "microphone-transcript.json"
    var merged = "transcript.json"
    var speakerTurns: String? = "speaker-turns.json"
    var utterances: String? = "utterance-transcript.json"
    var speakerDiarization: String? = "speaker-diarization.json"
    var resolved: String? = "resolved-transcript.json"
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
    var system: FinalizedAudioTrackMetadata?
    var microphone: FinalizedAudioTrackMetadata?
    var warnings: [String]
}

/// Decodes a manifest value written by a build that may not be this one.
///
/// A manifest is read by whatever version of MeetingScribe is installed,
/// which is not always the version that wrote it. Removing an enum case used
/// to make every older manifest carrying it undecodable *in its entirety*:
/// the recording could no longer be opened, recovered, reprocessed or
/// reanalysed, although its audio, transcript and analysis were all intact
/// on disk. It happened once already — `SessionAnalysisStatus` carried a
/// `missingAPIKey` case between 2026-07-11 and 2026-08-12.
///
/// A value this build does not know now decodes to `unrecognized`. Every
/// such enum is only ever compared for equality, never switched over
/// exhaustively, so an unknown value reads as "not completed" — the
/// conservative answer, and the one that keeps the rest of the manifest
/// readable.
///
/// The original spelling is not preserved: the next manifest write replaces
/// it with `unrecognized`. That is a deliberate trade. This build cannot act
/// on a state it does not know, and the alternative on offer was losing the
/// whole recording.
extension RawRepresentable where Self: Decodable, RawValue == String {
    static func decodedFromManifest(
        _ decoder: any Decoder,
        fallback: Self
    ) throws -> Self {
        let raw = try decoder.singleValueContainer().decode(String.self)
        return Self(rawValue: raw) ?? fallback
    }
}

enum AudioSourceCleanupStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

struct AudioSourceCleanupMetadata: Codable, Equatable, Sendable {
    var status: AudioSourceCleanupStatus
    var completedAt: Date
    var deletedFiles: [String]
    var failureReason: String?
}

enum RecordingAudioCleanupStatus: String, Codable, Equatable, Sendable {
    case inProgress
    case purged
    case failed
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

enum RecordingAudioCleanupTrigger: String, Codable, Equatable, Sendable {
    case manual
    case automatic
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

struct RecordingAudioRetentionMetadata: Codable, Equatable, Sendable {
    var keepAudio: Bool
    var cleanupStatus: RecordingAudioCleanupStatus?
    var cleanupTrigger: RecordingAudioCleanupTrigger?
    var cleanupStartedAt: Date?
    var cleanupCompletedAt: Date?
    var candidateFiles: [String]
    var deletedFiles: [String]
    var reclaimedBytes: Int64?
    var failureReason: String?

    init(
        keepAudio: Bool = false,
        cleanupStatus: RecordingAudioCleanupStatus? = nil,
        cleanupTrigger: RecordingAudioCleanupTrigger? = nil,
        cleanupStartedAt: Date? = nil,
        cleanupCompletedAt: Date? = nil,
        candidateFiles: [String] = [],
        deletedFiles: [String] = [],
        reclaimedBytes: Int64? = nil,
        failureReason: String? = nil
    ) {
        self.keepAudio = keepAudio
        self.cleanupStatus = cleanupStatus
        self.cleanupTrigger = cleanupTrigger
        self.cleanupStartedAt = cleanupStartedAt
        self.cleanupCompletedAt = cleanupCompletedAt
        self.candidateFiles = candidateFiles
        self.deletedFiles = deletedFiles
        self.reclaimedBytes = reclaimedBytes
        self.failureReason = failureReason
    }
}

enum SessionTranscriptionStatus: String, Codable, Sendable {
    case completed
    case failed
    case modelMissing
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

struct SessionTranscriptionMetadata: Codable, Equatable, Sendable {
    var status: SessionTranscriptionStatus
    var model: String
    var startedAt: Date?
    var completedAt: Date?
    var systemSegmentCount: Int?
    var microphoneSegmentCount: Int?
    var mergedSegmentCount: Int? = nil
    var utteranceCount: Int? = nil
    var turnBoundaryCount: Int? = nil
    var turnDetectionModel: String? = nil
    var utteranceFallbackUsed: Bool? = nil
    var systemPerformance: TrackTranscriptionPerformance? = nil
    var microphonePerformance: TrackTranscriptionPerformance? = nil
    var warnings: [String]
    var failureReason: String?
    var provenance: TranscriptionProvenance? = nil
}

enum SessionDiarizationStatus: String, Codable, Sendable {
    case completed
    case failed
    case modelMissing
    case unavailable
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

struct SessionDiarizationMetadata: Codable, Equatable, Sendable {
    var status: SessionDiarizationStatus
    var engine: String
    var model: String
    var configurationRevision: String
    var startedAt: Date?
    var completedAt: Date?
    var speakerCount: Int?
    var segmentCount: Int?
    var audioDurationSeconds: Double?
    var wallTimeSeconds: Double?
    var sourceAudioFingerprint: String?
    var warnings: [String]
    var failureReason: String?
}

enum SessionAnalysisStatus: String, Codable, Sendable {
    case completed
    case failed
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

struct SessionAnalysisConfiguration: Codable, Equatable, Sendable {
    var tool: AnalysisTool
    var executablePath: String
    var model: String?
    var prompt: String
    var promptHash: String

    init(
        tool: AnalysisTool,
        executablePath: String,
        model: String?,
        prompt: String
    ) {
        self.tool = tool
        self.executablePath = executablePath
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = normalizedModel?.isEmpty == false ? normalizedModel : nil
        self.prompt = prompt
        self.promptHash = AnalysisPrompt.hash(prompt)
    }
}

struct SessionAnalysisMetadata: Codable, Equatable, Sendable {
    var status: SessionAnalysisStatus
    var provider: String
    var model: String
    var startedAt: Date?
    var completedAt: Date?
    var transcriptChunkCount: Int?
    var requestCount: Int?
    var promptHash: String?
    var toolVersion: String?
    var failureReason: String?

    init(
        status: SessionAnalysisStatus,
        provider: String,
        model: String,
        startedAt: Date?,
        completedAt: Date?,
        transcriptChunkCount: Int?,
        requestCount: Int?,
        promptHash: String? = nil,
        toolVersion: String? = nil,
        failureReason: String?
    ) {
        self.status = status
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.transcriptChunkCount = transcriptChunkCount
        self.requestCount = requestCount
        self.promptHash = promptHash
        self.toolVersion = toolVersion
        self.failureReason = failureReason
    }
}

enum SessionOutputStatus: String, Codable, Sendable {
    case completed
    case failed
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
}

enum SessionRecoveryStatus: String, Codable, Sendable {
    case inProgress
    case completed
    case failed
    case closed
    /// A value written by a build that knew a case this one does not.
    case unrecognized

    init(from decoder: any Decoder) throws {
        self = try Self.decodedFromManifest(decoder, fallback: .unrecognized)
    }
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

struct SessionNotesMetadata: Codable, Equatable, Sendable {
    var fileName: String = "notes.md"
    var updatedAt: Date
    var characterCount: Int
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
    var notes: SessionNotesMetadata?
    var captureMode: CaptureMode?
    var audioFiles: SessionAudioFiles
    var transcriptFiles: SessionTranscriptFiles?
    var systemAudio: AudioTrackMetadata?
    var microphoneAudio: AudioTrackMetadata?
    var audioFinalization: AudioFinalizationMetadata?
    var audioSourceCleanup: AudioSourceCleanupMetadata?
    var recordingAudioRetention: RecordingAudioRetentionMetadata?
    var transcription: SessionTranscriptionMetadata?
    var diarization: SessionDiarizationMetadata?
    var analysisConfiguration: SessionAnalysisConfiguration?
    var analysis: SessionAnalysisMetadata?
    var output: SessionOutputMetadata?
    var recovery: SessionRecoveryMetadata?
    var recoveryDetectedAt: Date?
    /// The current durable processing attempt. Omitted from legacy manifests.
    var processing: ProcessingJob?
    var failureReason: String?

    init(
        schemaVersion: Int = 16,
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
        notes: SessionNotesMetadata? = nil,
        captureMode: CaptureMode? = .systemAndMicrophone,
        audioFiles: SessionAudioFiles = SessionAudioFiles(),
        transcriptFiles: SessionTranscriptFiles? = SessionTranscriptFiles(),
        systemAudio: AudioTrackMetadata? = nil,
        microphoneAudio: AudioTrackMetadata? = nil,
        audioFinalization: AudioFinalizationMetadata? = nil,
        audioSourceCleanup: AudioSourceCleanupMetadata? = nil,
        recordingAudioRetention: RecordingAudioRetentionMetadata? = nil,
        transcription: SessionTranscriptionMetadata? = nil,
        diarization: SessionDiarizationMetadata? = nil,
        analysisConfiguration: SessionAnalysisConfiguration? = nil,
        analysis: SessionAnalysisMetadata? = nil,
        output: SessionOutputMetadata? = nil,
        recovery: SessionRecoveryMetadata? = nil,
        recoveryDetectedAt: Date? = nil,
        processing: ProcessingJob? = nil,
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
        self.notes = notes
        self.captureMode = captureMode
        self.audioFiles = audioFiles
        self.transcriptFiles = transcriptFiles
        self.systemAudio = systemAudio
        self.microphoneAudio = microphoneAudio
        self.audioFinalization = audioFinalization
        self.audioSourceCleanup = audioSourceCleanup
        self.recordingAudioRetention = recordingAudioRetention
        self.transcription = transcription
        self.diarization = diarization
        self.analysisConfiguration = analysisConfiguration
        self.analysis = analysis
        self.output = output
        self.recovery = recovery
        self.recoveryDetectedAt = recoveryDetectedAt
        self.processing = processing
        self.failureReason = failureReason
    }

    var resolvedOutputLanguage: OutputLanguage {
        outputLanguage ?? .slovak
    }

    var resolvedCaptureMode: CaptureMode {
        captureMode ?? .systemAndMicrophone
    }

    var keepsRecordingAudio: Bool {
        recordingAudioRetention?.keepAudio == true
    }

    var isRecordingAudioPurged: Bool {
        recordingAudioRetention?.cleanupStatus == .purged
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
