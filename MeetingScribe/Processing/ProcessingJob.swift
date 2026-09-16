import Foundation

/// Describes why processing was requested. A session has one current job; a
/// retry replaces its attempt identity so delayed work from the old attempt
/// cannot change the current manifest.
enum ProcessingJobKind: String, Codable, CaseIterable, Sendable {
    case initial
    case recovery
    case retranscribe
    case reanalyze
}

enum ProcessingJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case pauseRequested
    case paused
    case completed
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            true
        case .queued, .running, .pauseRequested, .paused:
            false
        }
    }
}

/// The settings which must stay stable after work enters the queue. Secrets
/// and provider credentials deliberately do not belong in this value.
struct ProcessingJobConfiguration: Codable, Equatable, Sendable {
    var outputDirectoryURL: URL?
    var outputDirectoryBookmark: Data?
    var automaticallyDeleteSourceCAF: Bool
    var analysisConfiguration: SessionAnalysisConfiguration?

    init(
        outputDirectoryURL: URL?,
        outputDirectoryBookmark: Data? = nil,
        automaticallyDeleteSourceCAF: Bool,
        analysisConfiguration: SessionAnalysisConfiguration? = nil
    ) {
        self.outputDirectoryURL = outputDirectoryURL
        self.outputDirectoryBookmark = outputDirectoryBookmark
        self.automaticallyDeleteSourceCAF = automaticallyDeleteSourceCAF
        self.analysisConfiguration = analysisConfiguration
    }
}

/// The durable current processing attempt stored in `session.json`.
struct ProcessingJob: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobID: UUID
    var attemptID: UUID
    var kind: ProcessingJobKind
    var state: ProcessingJobState
    var stage: ProcessingStepID?
    var checkpoint: ProcessingStepID?
    let enqueuedAt: Date
    var startedAt: Date?
    var updatedAt: Date
    var completedAt: Date?
    var failureDescription: String?
    var configuration: ProcessingJobConfiguration

    var id: UUID { jobID }

    init(
        jobID: UUID = UUID(),
        attemptID: UUID = UUID(),
        kind: ProcessingJobKind,
        state: ProcessingJobState = .queued,
        stage: ProcessingStepID? = nil,
        checkpoint: ProcessingStepID? = nil,
        enqueuedAt: Date = Date(),
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        failureDescription: String? = nil,
        configuration: ProcessingJobConfiguration
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.jobID = jobID
        self.attemptID = attemptID
        self.kind = kind
        self.state = state
        self.stage = stage
        self.checkpoint = checkpoint
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? enqueuedAt
        self.completedAt = completedAt
        self.failureDescription = failureDescription
        self.configuration = configuration
    }
}

/// A partial job update. `updatesStage` and `updatesCheckpoint` make clearing
/// an optional persisted value unambiguous.
struct ProcessingJobPatch: Equatable, Sendable {
    var state: ProcessingJobState?
    var stage: ProcessingStepID?
    var checkpoint: ProcessingStepID?
    var failureDescription: String?
    var updatesStage: Bool
    var updatesCheckpoint: Bool
    var updatesFailureDescription: Bool

    init(
        state: ProcessingJobState? = nil,
        stage: ProcessingStepID? = nil,
        checkpoint: ProcessingStepID? = nil,
        failureDescription: String? = nil,
        updatesStage: Bool = false,
        updatesCheckpoint: Bool = false,
        updatesFailureDescription: Bool = false
    ) {
        self.state = state
        self.stage = stage
        self.checkpoint = checkpoint
        self.failureDescription = failureDescription
        self.updatesStage = updatesStage || stage != nil
        self.updatesCheckpoint = updatesCheckpoint || checkpoint != nil
        self.updatesFailureDescription = updatesFailureDescription || failureDescription != nil
    }
}

/// Artifacts that a processing checkpoint has committed. Nil means the
/// repository keeps the value already present in the latest manifest.
struct ProcessingArtifactMetadata: Equatable, Sendable {
    var audioFinalization: AudioFinalizationMetadata?
    var transcription: SessionTranscriptionMetadata?
    var analysis: SessionAnalysisMetadata?
    var output: SessionOutputMetadata?
    var audioSourceCleanup: AudioSourceCleanupMetadata?

    init(
        audioFinalization: AudioFinalizationMetadata? = nil,
        transcription: SessionTranscriptionMetadata? = nil,
        analysis: SessionAnalysisMetadata? = nil,
        output: SessionOutputMetadata? = nil,
        audioSourceCleanup: AudioSourceCleanupMetadata? = nil
    ) {
        self.audioFinalization = audioFinalization
        self.transcription = transcription
        self.analysis = analysis
        self.output = output
        self.audioSourceCleanup = audioSourceCleanup
    }
}
