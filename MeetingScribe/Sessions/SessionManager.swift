import Foundation

actor SessionManager {
    nonisolated let recordingsRoot: URL

    private let fileManager: FileManager
    private let storageGuard: StorageGuard
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

    func startSession(title: String, now: Date = Date()) throws -> RecordingSession {
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
            startedAt: now
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

    func storageStatus() throws -> StorageStatus {
        try prepareStorage()
        return try storageGuard.status(at: recordingsRoot)
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

    private func persist(_ session: RecordingSession) throws {
        let data = try SessionJSONCoder.makeEncoder().encode(session.metadata)
        try data.write(to: session.manifestURL, options: .atomic)
    }
}
enum SessionManagerError: Error, Equatable, LocalizedError {
    case sessionAlreadyActive
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "A recording session is already active."
        case .noActiveSession:
            return "There is no active recording session to stop."
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
