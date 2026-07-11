import Foundation

actor SessionManager {
    nonisolated let recordingsRoot: URL

    private let fileManager: FileManager
    private var activeSession: RecordingSession?

    init(
        recordingsRoot: URL = SessionManager.defaultRecordingsRoot,
        fileManager: FileManager = .default
    ) {
        self.recordingsRoot = recordingsRoot
        self.fileManager = fileManager
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
        try persist(session)
        activeSession = nil
        return session
    }

    func currentSession() -> RecordingSession? {
        activeSession
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
