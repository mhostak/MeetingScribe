import Foundation

actor SessionManager {
    nonisolated let recordingsRoot: URL

    private let fileManager: FileManager
    private var storageGuard: StorageGuard
    private let recoveryScanner: SessionRecoveryScanner
    private var activeSession: RecordingSession?

    init(
        recordingsRoot: URL = SessionManager.defaultRecordingsRoot,
        fileManager: FileManager = .default,
        storageGuard: StorageGuard = StorageGuard(),
        recoveryScanner: SessionRecoveryScanner? = nil
    ) {
        self.recordingsRoot = recordingsRoot
        self.fileManager = fileManager
        self.storageGuard = storageGuard
        self.recoveryScanner = recoveryScanner ?? SessionRecoveryScanner(fileManager: fileManager)
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
            analysisConfiguration: analysisConfiguration
        )
        let session = RecordingSession(metadata: metadata, directoryURL: directoryURL)

        try persist(session)
        activeSession = session
        return session
    }

    func stopSession(
        now: Date = Date(),
        systemAudio: AudioTrackMetadata? = nil,
        microphoneAudio: AudioTrackMetadata? = nil,
        audioFinalization: AudioFinalizationMetadata? = nil,
        transcription: SessionTranscriptionMetadata? = nil,
        diarization: SessionDiarizationMetadata? = nil,
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
        session.metadata.diarization = diarization
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
        activeSession = nil
        return session
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
        activeSession = nil
        return session
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
        var session = completedSession
        session.metadata.audioSourceCleanup = cleanup
        try persist(session)
        return session
    }

    func recordAnalysisRevision(
        configuration: SessionAnalysisConfiguration,
        analysis: SessionAnalysisMetadata,
        for completedSession: RecordingSession
    ) throws -> RecordingSession {
        var session = completedSession
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
        guard let activeID = activeSession?.metadata.id else { return result }
        return SessionRecoveryScanResult(
            candidates: result.candidates.filter { $0.id != activeID },
            issues: result.issues
        )
    }

    func beginRecovery(id: String, now: Date = Date()) throws -> RecordingSession {
        guard activeSession == nil else {
            throw SessionManagerError.sessionAlreadyActive
        }
        let result = try scanForRecovery(now: now)
        guard let candidate = result.candidates.first(where: { $0.id == id }) else {
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
        try persist(session)
        activeSession = session
        return session
    }

    func closeRecovery(id: String, now: Date = Date()) throws -> RecordingSession {
        guard activeSession == nil else {
            throw SessionManagerError.sessionAlreadyActive
        }
        let result = try scanForRecovery(now: now)
        guard let candidate = result.candidates.first(where: { $0.id == id }) else {
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
        guard activeSession == nil else {
            throw SessionManagerError.sessionAlreadyActive
        }
        let result = try scanForRecovery()
        guard result.issues.contains(where: { $0.directoryName == directoryName }) else {
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
