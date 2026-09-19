import Foundation

enum SessionArtifactState: Equatable, Sendable {
    case available(URL)
    case missing(URL)
    case removed
    case notProduced

    var url: URL? {
        switch self {
        case let .available(url), let .missing(url):
            return url
        case .removed, .notProduced:
            return nil
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var isRemoved: Bool {
        if case .removed = self { return true }
        return false
    }
}

enum SessionOverviewStatus: Equatable, Sendable {
    case completed
    case transcriptReady
    case needsModel
    case failed
    case interrupted
    case incomplete
}

struct SessionCatalogEntry: Identifiable, Equatable, Sendable {
    let session: RecordingSession
    let occurredAt: Date
    let duration: TimeInterval?
    let status: SessionOverviewStatus
    let message: String?
    let audio: SessionArtifactState
    let transcript: SessionArtifactState
    let markdown: SessionArtifactState
    let hasAnalysis: Bool
    let hasNotes: Bool
    let hasSpeakerArtifact: Bool

    var id: String { session.metadata.id }
}

struct SessionCatalogIssue: Identifiable, Equatable, Sendable {
    let directoryName: String
    let message: String

    var id: String { directoryName }
}

struct SessionCatalogSnapshot: Equatable, Sendable {
    let entries: [SessionCatalogEntry]
    let issues: [SessionCatalogIssue]

    static let empty = SessionCatalogSnapshot(entries: [], issues: [])
}

enum SessionCatalogError: Error, LocalizedError, Equatable {
    case recordingsRootIsNotDirectory(path: String)

    var errorDescription: String? {
        switch self {
        case let .recordingsRootIsNotDirectory(path):
            return "The recordings folder is not available: \(path)"
        }
    }
}

/// Reads historical sessions without changing their manifests or artifacts.
actor SessionCatalog {
    private let recordingsRoot: URL
    private let fileManager: FileManager

    init(
        recordingsRoot: URL = SessionManager.defaultRecordingsRoot,
        fileManager: FileManager = .default
    ) {
        self.recordingsRoot = recordingsRoot
        self.fileManager = fileManager
    }

    func load() throws -> SessionCatalogSnapshot {
        guard fileManager.fileExists(atPath: recordingsRoot.path) else {
            return .empty
        }

        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: recordingsRoot.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            throw SessionCatalogError.recordingsRootIsNotDirectory(path: recordingsRoot.path)
        }

        let directories = try fileManager.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [SessionCatalogEntry] = []
        var issues: [SessionCatalogIssue] = []
        for directory in directories where isDirectory(directory) {
            let recoveryIssueWasClosed = fileManager.fileExists(
                atPath: directory.appendingPathComponent(
                    SessionRecoveryScanner.closedIssueMarkerFileName,
                    isDirectory: false
                ).path
            )
            let manifestURL = directory.appendingPathComponent("session.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                if !recoveryIssueWasClosed {
                    issues.append(
                        SessionCatalogIssue(
                            directoryName: directory.lastPathComponent,
                            message: "Session manifest is missing."
                        )
                    )
                }
                continue
            }

            do {
                let metadata = try SessionJSONCoder.makeDecoder().decode(
                    SessionMetadata.self,
                    from: Data(contentsOf: manifestURL)
                )
                entries.append(makeEntry(metadata: metadata, directoryURL: directory))
            } catch {
                if !recoveryIssueWasClosed {
                    issues.append(
                        SessionCatalogIssue(
                            directoryName: directory.lastPathComponent,
                            message: "Session manifest is unreadable."
                        )
                    )
                }
            }
        }

        return SessionCatalogSnapshot(
            entries: entries.sorted { $0.occurredAt < $1.occurredAt },
            issues: issues.sorted { $0.directoryName.localizedStandardCompare($1.directoryName) == .orderedAscending }
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func makeEntry(metadata: SessionMetadata, directoryURL: URL) -> SessionCatalogEntry {
        let session = RecordingSession(metadata: metadata, directoryURL: directoryURL)
        let audio = audioArtifact(for: session)
        let transcript = transcriptArtifact(for: session)
        let markdown = markdownArtifact(for: session)
        let state = overviewStatus(for: metadata, markdown: markdown)

        return SessionCatalogEntry(
            session: session,
            occurredAt: metadata.startedAt ?? metadata.createdAt,
            duration: duration(for: metadata),
            status: state.status,
            message: state.message,
            audio: audio,
            transcript: transcript,
            markdown: markdown,
            hasAnalysis: hasNonemptyFile(session.analysisURL),
            hasNotes: hasNonemptyFile(session.notesURL),
            hasSpeakerArtifact: hasNonemptyFile(session.speakerDiarizationURL)
        )
    }

    private func duration(for metadata: SessionMetadata) -> TimeInterval? {
        if let startedAt = metadata.startedAt, let endedAt = metadata.endedAt {
            return max(0, endedAt.timeIntervalSince(startedAt))
        }
        return metadata.audioFinalization.flatMap {
            $0.system?.durationSeconds ?? $0.microphone?.durationSeconds
        }
    }

    private func overviewStatus(
        for metadata: SessionMetadata,
        markdown: SessionArtifactState
    ) -> (status: SessionOverviewStatus, message: String?) {
        if metadata.status == .failed {
            return (.failed, metadata.failureReason ?? "Recording failed.")
        }
        if let transcription = metadata.transcription {
            switch transcription.status {
            case .failed:
                return (.failed, transcription.failureReason ?? "Transcription failed.")
            case .modelMissing:
                return (.needsModel, transcription.failureReason ?? "A transcription model is required.")
            case .completed:
                break
            case .unrecognized:
                // Written by a build that knew a state this one does not.
                // Treated as unfinished rather than complete, so the
                // recording stays offered for processing.
                return (.incomplete, transcription.failureReason)
            }
        }
        if let output = metadata.output, output.status == .failed {
            return (.failed, output.failureReason ?? "Markdown export failed.")
        }
        if metadata.output?.status == .completed {
            guard markdown.isAvailable else {
                return (.incomplete, "The exported Markdown file is missing or its location is unavailable.")
            }
            return (.completed, nil)
        }
        if metadata.transcription?.status == .completed {
            return (.transcriptReady, "Transcript is available, but Markdown was not exported.")
        }
        if metadata.status == .recording {
            return (.interrupted, "Recording was interrupted before processing completed.")
        }
        return (.incomplete, "Processing did not produce a completed Markdown output.")
    }

    private func audioArtifact(for session: RecordingSession) -> SessionArtifactState {
        let metadata = session.metadata
        if metadata.isRecordingAudioPurged {
            return .removed
        }
        var names = [metadata.audioFiles.system, metadata.audioFiles.microphone]
        names.append(contentsOf: [
            metadata.audioFiles.systemWorking,
            metadata.audioFiles.microphoneWorking,
        ].compactMap { $0 })
        if let finalization = metadata.audioFinalization {
            if let system = finalization.system {
                names.append(system.fileName)
            }
            if let microphone = finalization.microphone {
                names.append(microphone.fileName)
            }
        }
        let urls = uniqueURLs(names, in: session.directoryURL)
        if let available = urls.first(where: hasNonemptyFile) {
            return .available(available)
        }
        let shouldExist = metadata.status == .recorded
            || metadata.systemAudio != nil
            || metadata.microphoneAudio != nil
            || metadata.audioFinalization != nil
        let fallbackURL = metadata.resolvedCaptureMode == .microphoneOnly
            ? session.microphoneAudioURL
            : session.systemAudioURL
        return shouldExist ? .missing(urls.first ?? fallbackURL) : .notProduced
    }

    private func transcriptArtifact(for session: RecordingSession) -> SessionArtifactState {
        let url = session.mergedTranscriptURL
        if hasNonemptyFile(url) { return .available(url) }
        return session.metadata.transcription?.status == .completed ? .missing(url) : .notProduced
    }

    private func markdownArtifact(for session: RecordingSession) -> SessionArtifactState {
        guard let path = session.metadata.output?.markdownPath, !path.isEmpty else {
            return .notProduced
        }
        let url = URL(fileURLWithPath: path)
        if hasNonemptyFile(url) { return .available(url) }
        return .missing(url)
    }

    private func uniqueURLs(_ names: [String], in directoryURL: URL) -> [URL] {
        var seen = Set<String>()
        return names.compactMap { name in
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return directoryURL.appendingPathComponent(name, isDirectory: false)
        }
    }

    private func hasNonemptyFile(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return size > 0
    }
}
