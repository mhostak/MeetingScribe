import Foundation

actor SessionManager {
    nonisolated let recordingsRoot: URL

    private let fileManager: FileManager
    private var storageGuard: StorageGuard
    private let ownership: RecordingOwnership
    private let recoveryScanner: SessionRecoveryScanner
    private var activeSession: RecordingSession?

    init(
        recordingsRoot: URL = SessionManager.defaultRecordingsRoot,
        fileManager: FileManager = .default,
        storageGuard: StorageGuard = StorageGuard(),
        recoveryScanner: SessionRecoveryScanner? = nil,
        ownership: RecordingOwnership = RecordingOwnership()
    ) {
        self.recordingsRoot = recordingsRoot
        self.fileManager = fileManager
        self.storageGuard = storageGuard
        self.ownership = ownership
        self.recoveryScanner = recoveryScanner ?? SessionRecoveryScanner(fileManager: fileManager, ownership: ownership)
    }

    static var defaultRecordingsRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    func prepareStorage() throws {
        try fileManager.createDirectory(
            at: recordingsRoot,
            withIntermediateDirectories: true
        )
    }

    func startSession(
        title: String,
        language: TranscriptionLanguage = .automatic,
        outputLanguage: OutputLanguage = .slovak,
        outputFileNameTemplate: String = MarkdownFileNameTemplate.defaultValue,
        calendarEvent: CalendarEventSnapshot? = nil,
        notes: String? = nil,
        analysisConfiguration: SessionAnalysisConfiguration? = nil,
        now: Date = Date()
    ) throws -> RecordingSession {
        guard activeSession == nil else {
            throw SessionManagerError.sessionAlreadyActive
        }

        try prepareStorage()
        try storageGuard.requireCapacity(at: recordingsRoot)

        let id = SessionIDGenerator.make(date: now)
        let directoryURL = recordingsRoot.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = SessionMetadata(
            id: id,
            title: normalizedTitle.isEmpty ? SessionTitleGenerator.make(date: now) : normalizedTitle,
            status: .recording,
            createdAt: now,
            startedAt: now,
            language: language,
            outputLanguage: outputLanguage,
            outputFileNameTemplate: outputFileNameTemplate,
            calendarEvent: calendarEvent,
            captureMode: .systemAndMicrophone,
            analysisConfiguration: analysisConfiguration
        )
        var session = RecordingSession(metadata: metadata, directoryURL: directoryURL)

        try ownership.claim(in: session.directoryURL)
        do {
            try persist(session)
            if let notes {
                let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedNotes.isEmpty {
                    try Data(notes.utf8).write(to: session.notesURL, options: .atomic)
                    session.metadata.notes = SessionNotesMetadata(
                        updatedAt: now,
                        characterCount: notes.count
                    )
                    try persist(session)
                }
            }
        } catch {
            try? ownership.release(in: session.directoryURL)
            throw error
        }
        activeSession = session
        return session
    }

    func stopSession(
        now: Date = Date(),
        systemAudio: AudioTrackMetadata? = nil,
        microphoneAudio: AudioTrackMetadata? = nil,
        audioFinalization: AudioFinalizationMetadata? = nil,
        transcription: SessionTranscriptionMetadata? = nil,
        analysis: SessionAnalysisMetadata? = nil,
        output: SessionOutputMetadata? = nil
    ) throws -> RecordingSession {
        guard var session = activeSession else {
            throw SessionManagerError.noActiveSession
        }

        session.metadata.status = .recorded
        session.metadata.endedAt = max(now, session.metadata.startedAt ?? now)
        session.metadata.systemAudio = systemAudio
        session.metadata.microphoneAudio = microphoneAudio
        session.metadata.audioFinalization = audioFinalization
        session.metadata.transcription = transcription
        // Older manifests may contain this compatibility field, but the
        // retired diarization runtime never writes it for new processing.
        session.metadata.diarization = nil
        session.metadata.analysis = analysis
        session.metadata.output = output
        if session.metadata.recovery?.status == .inProgress {
            let recoveredSuccessfully = transcription?.status == .completed
                && output?.status == .completed
            session.metadata.recovery?.status = recoveredSuccessfully ? .completed : .failed
            session.metadata.recovery?.completedAt = Date()
            session.metadata.recovery?.failureReason = recoveredSuccessfully
                ? nil
                : transcription?.failureReason
                    ?? output?.failureReason
                    ?? "Recovery processing did not produce a completed Markdown output."
        }
        try persist(session)
        // A leftover advisory claim expires; it must not keep capture active.
        try? ownership.release(in: session.directoryURL)
        activeSession = nil
        return session
    }

    /// Commits the capture handoff and its first queued job in one manifest
    /// write. The active capture ownership is released only after that write
    /// succeeds, so a failed write cannot make a recording disappear from the
    /// recoverable active state.
    func finishCaptureAndQueue(
        expectedSessionID: String,
        endedAt: Date,
        diagnostics: CaptureSessionDiagnostics,
        configuration: ProcessingJobConfiguration,
        now: Date = Date()
    ) throws -> RecordingSession {
        guard var session = activeSession else {
            // A caller may retry after the manifest was safely written but
            // before it observed the return value. Reuse that one job rather
            // than enqueueing another attempt.
            let persisted = try loadSession(id: expectedSessionID)
            guard persisted.metadata.processing != nil else {
                throw SessionManagerError.noActiveSession
            }
            return persisted
        }
        guard session.metadata.id == expectedSessionID else {
            throw ProcessingJobRepositoryError.unexpectedActiveSession(
                expected: expectedSessionID,
                actual: session.metadata.id
            )
        }

        session.metadata.status = .recorded
        session.metadata.endedAt = max(endedAt, session.metadata.startedAt ?? endedAt)
        session.metadata.systemAudio = diagnostics.systemAudio.sessionMetadata
        session.metadata.microphoneAudio = diagnostics.microphone.sessionMetadata
        session.metadata.failureReason = nil
        session.metadata.processing = ProcessingJob(
            kind: .initial,
            enqueuedAt: now,
            configuration: configuration
        )
        try persist(session)
        // A leftover advisory claim expires; it must not keep capture active.
        try? ownership.release(in: session.directoryURL)
        activeSession = nil
        return session
    }

    /// Enqueues historical work or a retry. Repeated requests for the current
    /// nonterminal job are idempotent; a terminal job receives a fresh job and
    /// attempt identity and therefore cannot accept its old callbacks.
    func queueProcessing(
        sessionID: String,
        kind: ProcessingJobKind,
        configuration: ProcessingJobConfiguration,
        now: Date = Date()
    ) throws -> RecordingSession {
        let directory = try sessionDirectoryURL(for: sessionID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ProcessingJobRepositoryError.sessionNotFound(sessionID)
        }
        return try ownership.withExclusiveAccess(to: directory) {
            var session = try loadSession(id: sessionID)
            guard activeSession?.metadata.id != sessionID,
                  ownership.classification(of: session.directoryURL) != .claimedByAnotherLiveProcess else {
                throw ProcessingJobRepositoryError.sessionStillRecording(sessionID)
            }
            guard session.metadata.status != .recording || kind == .recovery else {
                throw ProcessingJobRepositoryError.sessionStillRecording(sessionID)
            }
            if let job = session.metadata.processing {
                guard job.schemaVersion == ProcessingJob.currentSchemaVersion else {
                    throw ProcessingJobRepositoryError.unsupportedSchema(
                        sessionID: sessionID,
                        schemaVersion: job.schemaVersion
                    )
                }
                if !job.state.isTerminal {
                    return session
                }
            }

            if kind == .recovery {
                let recoveredAt = recoveryScanner.candidate(
                    recordingsRoot: recordingsRoot,
                    id: sessionID,
                    now: now
                )?.suggestedEndAt ?? session.metadata.startedAt ?? session.metadata.createdAt
                let originalStatus = session.metadata.recovery?.originalStatus ?? session.metadata.status
                let attempts = session.metadata.recovery?.attemptCount ?? 0
                session.metadata.status = .recorded
                session.metadata.endedAt = session.metadata.endedAt ?? recoveredAt
                session.metadata.recovery = SessionRecoveryMetadata(
                    status: .inProgress,
                    originalStatus: originalStatus,
                    detectedAt: session.metadata.recovery?.detectedAt ?? now,
                    startedAt: now,
                    completedAt: nil,
                    attemptCount: attempts + 1,
                    failureReason: nil
                )
                session.metadata.failureReason = nil
            }
            session.metadata.processing = ProcessingJob(
                kind: kind,
                enqueuedAt: now,
                configuration: configuration
            )
            try persist(session)
            return session
        }
    }

    /// Applies a checkpoint and any artifacts to the latest on-disk manifest.
    /// The job and attempt IDs are compared before any mutation, preventing a
    /// delayed callback from an old worker from overwriting a retry.
    func updateProcessing(
        sessionID: String,
        jobID: UUID,
        attemptID: UUID,
        patch: ProcessingJobPatch,
        artifactMetadata: ProcessingArtifactMetadata? = nil,
        now: Date = Date()
    ) throws -> RecordingSession {
        var session = try loadSession(id: sessionID)
        guard var job = session.metadata.processing else {
            throw ProcessingJobRepositoryError.processingJobNotFound(sessionID)
        }
        guard job.jobID == jobID, job.attemptID == attemptID else {
            throw ProcessingJobRepositoryError.processingIdentityMismatch(sessionID)
        }
        guard !job.state.isTerminal else {
            throw ProcessingJobRepositoryError.processingJobAlreadyTerminal(sessionID)
        }

        if let state = patch.state {
            job.state = state
            if state == .running, job.startedAt == nil {
                job.startedAt = now
            }
        }
        if patch.updatesStage {
            job.stage = patch.stage
        }
        if patch.updatesCheckpoint {
            job.checkpoint = patch.checkpoint
        }
        if patch.updatesFailureDescription {
            job.failureDescription = patch.failureDescription
        }
        job.updatedAt = now
        session.metadata.processing = job
        apply(artifactMetadata, to: &session.metadata)
        try persist(session)
        return session
    }

    /// Atomically records the final artifacts and terminal job state. A
    /// failure is scoped to this job and never changes `activeSession`.
    func completeProcessing(
        sessionID: String,
        jobID: UUID,
        attemptID: UUID,
        artifactMetadata: ProcessingArtifactMetadata,
        failureDescription: String? = nil,
        failedSteps: Set<ProcessingStepID> = [],
        now: Date = Date()
    ) throws -> RecordingSession {
        var session = try loadSession(id: sessionID)
        guard var job = session.metadata.processing else {
            throw ProcessingJobRepositoryError.processingJobNotFound(sessionID)
        }
        guard job.jobID == jobID, job.attemptID == attemptID else {
            throw ProcessingJobRepositoryError.processingIdentityMismatch(sessionID)
        }
        guard !job.state.isTerminal else {
            throw ProcessingJobRepositoryError.processingJobAlreadyTerminal(sessionID)
        }

        let failed = failureDescription != nil || !failedSteps.isEmpty
        job.state = failed ? .failed : .completed
        job.stage = nil
        job.completedAt = now
        job.updatedAt = now
        job.failureDescription = failureDescription
        session.metadata.processing = job
        apply(artifactMetadata, to: &session.metadata)
        if artifactMetadata.analysis?.status == .completed,
           let configuration = job.configuration.analysisConfiguration {
            session.metadata.analysisConfiguration = configuration
        }
        if session.metadata.recovery?.status == .inProgress {
            session.metadata.recovery?.status = failed ? .failed : .completed
            session.metadata.recovery?.completedAt = now
            session.metadata.recovery?.failureReason = failureDescription
        }
        try persist(session)
        return session
    }

    /// Lists every persisted job, including paused and terminal jobs, in the
    /// stable order used by the queue and the recordings UI.
    func loadProcessingSessions() throws -> [RecordingSession] {
        try prepareStorage()
        let directories = try fileManager.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let sessions = directories.compactMap { directory -> RecordingSession? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let metadata = try? SessionJSONCoder.makeDecoder().decode(
                    SessionMetadata.self,
                    from: Data(contentsOf: directory.appendingPathComponent("session.json", isDirectory: false))
                  ),
                  metadata.id == directory.lastPathComponent,
                  metadata.processing != nil else {
                return nil
            }
            return RecordingSession(metadata: metadata, directoryURL: directory)
        }
        return sessions.sorted { lhs, rhs in
            guard let left = lhs.metadata.processing, let right = rhs.metadata.processing else {
                return lhs.metadata.id < rhs.metadata.id
            }
            if left.enqueuedAt != right.enqueuedAt {
                return left.enqueuedAt < right.enqueuedAt
            }
            return left.jobID.uuidString < right.jobID.uuidString
        }
    }

    /// Converts an interrupted in-flight attempt into a new queued generation
    /// after process restart. Manually paused and terminal jobs stay unchanged.
    func resumeInterruptedProcessing(
        sessionID: String,
        jobID: UUID,
        attemptID: UUID,
        now: Date = Date()
    ) throws -> RecordingSession {
        var session = try loadSession(id: sessionID)
        guard var job = session.metadata.processing else {
            throw ProcessingJobRepositoryError.processingJobNotFound(sessionID)
        }
        guard job.jobID == jobID, job.attemptID == attemptID else {
            throw ProcessingJobRepositoryError.processingIdentityMismatch(sessionID)
        }
        guard job.state == .running || job.state == .pauseRequested || job.state == .paused else {
            return session
        }

        job.attemptID = UUID()
        job.state = .queued
        job.stage = nil
        job.startedAt = nil
        job.updatedAt = now
        job.failureDescription = nil
        session.metadata.processing = job
        try persist(session)
        return session
    }

    /// Reads one authoritative manifest by ID. It validates both the safe
    /// child path and the manifest ID, so callers cannot reach another session
    /// via a path-like ID.
    func loadSession(id: String) throws -> RecordingSession {
        let directoryURL = try sessionDirectoryURL(for: id)
        let manifestURL = directoryURL.appendingPathComponent("session.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ProcessingJobRepositoryError.sessionNotFound(id)
        }
        let metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: Data(contentsOf: manifestURL)
        )
        guard metadata.id == id else {
            throw ProcessingJobRepositoryError.sessionNotFound(id)
        }
        return RecordingSession(metadata: metadata, directoryURL: directoryURL)
    }

    func failSession(
        reason: String,
        now: Date = Date(),
        systemAudio: AudioTrackMetadata? = nil,
        microphoneAudio: AudioTrackMetadata? = nil
    ) throws -> RecordingSession {
        guard var session = activeSession else {
            throw SessionManagerError.noActiveSession
        }

        session.metadata.status = .failed
        session.metadata.endedAt = max(now, session.metadata.startedAt ?? now)
        session.metadata.systemAudio = systemAudio
        session.metadata.microphoneAudio = microphoneAudio
        session.metadata.failureReason = reason
        if session.metadata.recovery?.status == .inProgress {
            session.metadata.recovery?.status = .failed
            session.metadata.recovery?.completedAt = now
            session.metadata.recovery?.failureReason = reason
        }
        try persist(session)
        // A leftover advisory claim expires; it must not keep capture active.
        try? ownership.release(in: session.directoryURL)
        activeSession = nil
        return session
    }

    func refreshRecordingOwnership() throws {
        guard let session = activeSession else { return }
        try ownership.refresh(in: session.directoryURL)
    }

    func reclaimRecordingOwnership() throws {
        guard let session = activeSession else { return }
        try ownership.claim(in: session.directoryURL)
    }

    func currentSession() -> RecordingSession? {
        activeSession
    }

    func renameActiveSession(to title: String) throws -> RecordingSession {
        guard var session = activeSession else {
            throw SessionManagerError.noActiveSession
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw SessionManagerError.emptyTitle
        }

        session.metadata.title = normalizedTitle
        try persist(session)
        activeSession = session
        return session
    }

    func updateActiveSessionNotes(_ text: String) throws -> RecordingSession {
        guard var session = activeSession else {
            throw SessionManagerError.noActiveSession
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            if fileManager.fileExists(atPath: session.notesURL.path) {
                try fileManager.removeItem(at: session.notesURL)
            }
            session.metadata.notes = nil
        } else {
            try Data(text.utf8).write(to: session.notesURL, options: .atomic)
            session.metadata.notes = SessionNotesMetadata(
                updatedAt: Date(),
                characterCount: text.count
            )
        }
        try persist(session)
        activeSession = session
        return session
    }

    func updateActiveSessionCalendarEvent(
        _ calendarEvent: CalendarEventSnapshot?,
        title: String? = nil
    ) throws -> RecordingSession {
        guard var session = activeSession else {
            throw SessionManagerError.noActiveSession
        }

        if let title {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTitle.isEmpty else {
                throw SessionManagerError.emptyTitle
            }
            session.metadata.title = normalizedTitle
        }
        session.metadata.calendarEvent = calendarEvent
        try persist(session)
        activeSession = session
        return session
    }

    func recordAudioSourceCleanup(
        _ cleanup: AudioSourceCleanupMetadata,
        for completedSession: RecordingSession
    ) throws -> RecordingSession {
        var session = try loadSession(id: completedSession.metadata.id)
        session.metadata.audioSourceCleanup = cleanup
        try persist(session)
        return session
    }

    func recordAnalysisRevision(
        configuration: SessionAnalysisConfiguration,
        analysis: SessionAnalysisMetadata,
        for completedSession: RecordingSession
    ) throws -> RecordingSession {
        var session = try loadSession(id: completedSession.metadata.id)
        session.metadata.analysisConfiguration = configuration
        session.metadata.analysis = analysis
        try persist(session)
        return session
    }

    func storageStatus() throws -> StorageStatus {
        try prepareStorage()
        return try storageGuard.status(at: recordingsRoot)
    }

    func setMinimumStorageBytes(_ bytes: Int64) {
        storageGuard = storageGuard.withMinimumBytes(bytes)
    }

    func scanForRecovery(now: Date = Date()) throws -> SessionRecoveryScanResult {
        try prepareStorage()
        let result = recoveryScanner.scan(recordingsRoot: recordingsRoot, now: now)
        let processingSessions = try loadProcessingSessions()
        let processingIDs = Set(processingSessions.map(\.metadata.id))
        let excludedIDs = processingIDs.union(activeSession.map { [$0.metadata.id] } ?? [])
        let unsupportedIssues = processingSessions.compactMap { session -> SessionRecoveryIssue? in
            guard !ownership.classification(of: session.directoryURL).isLive,
                  let job = session.metadata.processing,
                  job.schemaVersion != ProcessingJob.currentSchemaVersion else {
                return nil
            }
            return SessionRecoveryIssue(
                directoryName: session.metadata.id,
                reason: "Processing job schema version \(job.schemaVersion) is unsupported. The job was not resumed."
            )
        }
        return SessionRecoveryScanResult(
            candidates: result.candidates.filter {
                !excludedIDs.contains($0.id) && !ownership.classification(of: $0.session.directoryURL).isLive
            },
            issues: (result.issues + unsupportedIssues).filter {
                $0.directoryName != activeSession?.metadata.id
                    && !ownership.classification(of: recordingsRoot.appendingPathComponent($0.directoryName)).isLive
            }.sorted { $0.directoryName < $1.directoryName }
        )
    }

    func beginRecovery(id: String, now: Date = Date()) throws -> RecordingSession {
        guard activeSession == nil else {
            throw SessionManagerError.sessionAlreadyActive
        }
        try prepareStorage()
        guard let candidate = recoveryScanner.candidate(
            recordingsRoot: recordingsRoot,
            id: id,
            now: now
        ) else {
            throw SessionRecoveryError.candidateNotFound
        }
        guard recoveryScanner.isRecoverable(candidate.session.metadata) else {
            throw SessionRecoveryError.sessionNotRecoverable
        }

        var session = candidate.session
        let originalStatus = session.metadata.recovery?.originalStatus ?? session.metadata.status
        let attempts = session.metadata.recovery?.attemptCount ?? 0
        session.metadata.status = .recording
        session.metadata.recovery = SessionRecoveryMetadata(
            status: .inProgress,
            originalStatus: originalStatus,
            detectedAt: session.metadata.recovery?.detectedAt ?? now,
            startedAt: now,
            completedAt: nil,
            attemptCount: attempts + 1,
            failureReason: nil
        )
        session.metadata.failureReason = nil
        try ownership.claim(in: session.directoryURL)
        do {
            try persist(session)
        } catch {
            try? ownership.release(in: session.directoryURL)
            throw error
        }
        activeSession = session
        return session
    }

    /// Reloads one visible recovery candidate after an attempted recovery,
    /// without scanning every historical session directory.
    func recoveryCandidate(id: String, now: Date = Date()) throws -> SessionRecoveryCandidate? {
        guard activeSession?.metadata.id != id else {
            throw SessionManagerError.sessionAlreadyActive
        }
        try prepareStorage()
        if try loadProcessingSessions().contains(where: { $0.metadata.id == id }) {
            return nil
        }
        return recoveryScanner.candidate(recordingsRoot: recordingsRoot, id: id, now: now)
    }

    func closeRecovery(id: String, now: Date = Date()) throws -> RecordingSession {
        guard activeSession?.metadata.id != id else {
            throw SessionManagerError.sessionAlreadyActive
        }
        try prepareStorage()
        guard try !loadProcessingSessions().contains(where: { $0.metadata.id == id }) else {
            throw SessionRecoveryError.candidateNotFound
        }
        guard let candidate = recoveryScanner.candidate(
            recordingsRoot: recordingsRoot,
            id: id,
            now: now
        ) else {
            throw SessionRecoveryError.candidateNotFound
        }

        var session = candidate.session
        let originalStatus = session.metadata.recovery?.originalStatus ?? session.metadata.status
        let reason = "Recovery was closed by the user. Existing artifacts were preserved."
        session.metadata.status = .failed
        session.metadata.endedAt = session.metadata.endedAt ?? candidate.suggestedEndAt
        session.metadata.recovery = SessionRecoveryMetadata(
            status: .closed,
            originalStatus: originalStatus,
            detectedAt: session.metadata.recovery?.detectedAt ?? now,
            startedAt: session.metadata.recovery?.startedAt,
            completedAt: now,
            attemptCount: session.metadata.recovery?.attemptCount ?? 0,
            failureReason: reason
        )
        session.metadata.failureReason = reason
        try persist(session)
        return session
    }

    func closeRecoveryIssue(directoryName: String) throws {
        guard activeSession?.metadata.id != directoryName else {
            throw SessionManagerError.sessionAlreadyActive
        }
        try prepareStorage()
        guard try !loadProcessingSessions().contains(where: { $0.metadata.id == directoryName }) else {
            throw SessionRecoveryError.issueNotFound
        }
        guard recoveryScanner.issue(
            recordingsRoot: recordingsRoot,
            directoryName: directoryName
        ) != nil else {
            throw SessionRecoveryError.issueNotFound
        }
        let standardizedRoot = recordingsRoot.standardizedFileURL
        let directoryURL = standardizedRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        guard directoryURL.deletingLastPathComponent() == standardizedRoot else {
            throw SessionRecoveryError.issueNotFound
        }
        let markerURL = directoryURL.appendingPathComponent(
            SessionRecoveryScanner.closedIssueMarkerFileName,
            isDirectory: false
        )
        try Data("Closed by the user. Existing artifacts were preserved.\n".utf8)
            .write(to: markerURL, options: .atomic)
    }

    private func persist(_ session: RecordingSession) throws {
        let data = try SessionJSONCoder.makeEncoder().encode(session.metadata)
        try data.write(to: session.manifestURL, options: .atomic)
    }

    private func apply(
        _ artifacts: ProcessingArtifactMetadata?,
        to metadata: inout SessionMetadata
    ) {
        guard let artifacts else { return }
        if let audioFinalization = artifacts.audioFinalization {
            metadata.audioFinalization = audioFinalization
        }
        if let transcription = artifacts.transcription {
            metadata.transcription = transcription
        }
        if let analysis = artifacts.analysis {
            metadata.analysis = analysis
        }
        if let output = artifacts.output {
            metadata.output = output
        }
        if let audioSourceCleanup = artifacts.audioSourceCleanup {
            metadata.audioSourceCleanup = audioSourceCleanup
        }
    }

    private func sessionDirectoryURL(for id: String) throws -> URL {
        let root = recordingsRoot.standardizedFileURL
        let directoryURL = root
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL
        guard directoryURL.deletingLastPathComponent() == root,
              directoryURL.lastPathComponent == id else {
            throw ProcessingJobRepositoryError.sessionNotFound(id)
        }
        return directoryURL
    }
}
/// Repository failures scoped to a persisted processing job. This is separate
/// from the legacy capture-only `SessionManagerError` so existing capture UI
/// error handling remains source-compatible.
enum ProcessingJobRepositoryError: Error, Equatable, LocalizedError {
    case unexpectedActiveSession(expected: String, actual: String)
    case sessionNotFound(String)
    case sessionStillRecording(String)
    case processingJobNotFound(String)
    case processingIdentityMismatch(String)
    case processingJobAlreadyTerminal(String)
    case unsupportedSchema(sessionID: String, schemaVersion: Int)

    var errorDescription: String? {
        switch self {
        case let .unexpectedActiveSession(expected, actual):
            return "The active recording is \(actual), not \(expected)."
        case let .sessionNotFound(id):
            return "The recording session \(id) could not be found."
        case let .sessionStillRecording(id):
            return "The recording session \(id) is still recording."
        case let .processingJobNotFound(id):
            return "The recording session \(id) has no processing job."
        case let .processingIdentityMismatch(id):
            return "The processing attempt for recording session \(id) is no longer current."
        case let .processingJobAlreadyTerminal(id):
            return "The processing job for recording session \(id) has already finished."
        case let .unsupportedSchema(sessionID, schemaVersion):
            return "Processing job schema version \(schemaVersion) for recording session \(sessionID) is unsupported."
        }
    }
}

enum SessionManagerError: Error, Equatable, LocalizedError {
    case sessionAlreadyActive
    case noActiveSession
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "A recording session is already active."
        case .noActiveSession:
            return "There is no active recording session to stop."
        case .emptyTitle:
            return "The meeting title cannot be empty."
        }
    }
}

enum SessionIDGenerator {
    static func make(date: Date, uuid: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"

        let suffix = uuid.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(6)
            .uppercased()

        return "\(formatter.string(from: date))_\(suffix)"
    }
}

enum SessionTitleGenerator {
    static func make(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "Meeting \(formatter.string(from: date))"
    }
}
