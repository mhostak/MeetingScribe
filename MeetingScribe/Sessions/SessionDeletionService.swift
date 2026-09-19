import Foundation

/// What a single delete would remove, resolved from disk rather than from the
/// overview snapshot the user is looking at.
struct SessionDeletionPlan: Identifiable, Equatable, Sendable {
    var id: String { sessionID }

    let sessionID: String
    let title: String
    let directoryURL: URL
    let directoryBytes: Int64
    /// The exported note, only when it lives outside the session folder. A note
    /// inside the folder goes with the folder and is never a separate item.
    let exportedMarkdownURL: URL?
    let exportedMarkdownBytes: Int64

    var hasExternalMarkdown: Bool { exportedMarkdownURL != nil }
}

struct SessionDeletionReport: Equatable, Sendable {
    let sessionID: String
    let trashedMarkdown: Bool
    let reclaimedBytes: Int64
    /// Non-fatal problems. The session folder is gone in every report; only the
    /// exported note can fail on its own.
    let warnings: [String]
}

enum SessionDeletionError: Error, LocalizedError, Equatable {
    case sessionNotFound(String)
    case sessionDirectoryIsNotEligible(path: String)
    case sessionIsInUse(String)

    var errorDescription: String? {
        switch self {
        case let .sessionNotFound(id):
            return "Recording \(id) is no longer in the recordings folder."
        case let .sessionDirectoryIsNotEligible(path):
            return "The recording folder cannot be deleted: \(path)"
        case let .sessionIsInUse(id):
            return "Recording \(id) is still being written by a running MeetingScribe."
        }
    }
}

/// Moves one recording to the Trash: its whole session folder, and optionally
/// the Markdown note that was exported outside of it.
///
/// Every path is re-resolved from the recordings root immediately before the
/// move, so a stale overview row cannot direct a recursive delete anywhere
/// else. The note is only ever touched when it is a plain `.md` file whose name
/// still matches the manifest, because its path comes from editable JSON.
actor SessionDeletionService {
    private let recordingsRoot: URL
    private let fileManager: FileManager
    private let ownership: RecordingOwnership
    private let moveToTrash: @Sendable (URL) throws -> Void

    init(
        recordingsRoot: URL = SessionManager.defaultRecordingsRoot,
        fileManager: FileManager = .default,
        ownership: RecordingOwnership = RecordingOwnership(),
        moveToTrash: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.recordingsRoot = recordingsRoot
        self.fileManager = fileManager
        self.ownership = ownership
        self.moveToTrash = moveToTrash ?? { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func plan(for sessionID: String) throws -> SessionDeletionPlan {
        let directoryURL = try validatedSessionDirectory(for: sessionID)
        let metadata = try loadMetadata(in: directoryURL)
        let markdown = externalMarkdown(for: metadata, sessionDirectory: directoryURL)

        return SessionDeletionPlan(
            sessionID: sessionID,
            title: metadata.title,
            directoryURL: directoryURL,
            directoryBytes: allocatedBytes(ofTreeAt: directoryURL),
            exportedMarkdownURL: markdown?.url,
            exportedMarkdownBytes: markdown?.bytes ?? 0
        )
    }

    /// Trashes the session folder, then the exported note. The folder is the
    /// primary object: if it cannot be trashed nothing else is touched, while a
    /// note that survives is only reported so the user can remove it by hand.
    func delete(
        _ plan: SessionDeletionPlan,
        includingExportedMarkdown: Bool
    ) throws -> SessionDeletionReport {
        let directoryURL = try validatedSessionDirectory(for: plan.sessionID)
        let metadata = try loadMetadata(in: directoryURL)
        let markdown = includingExportedMarkdown
            ? externalMarkdown(for: metadata, sessionDirectory: directoryURL)
            : nil
        let directoryBytes = allocatedBytes(ofTreeAt: directoryURL)

        try moveToTrash(directoryURL)

        var warnings: [String] = []
        var trashedMarkdown = false
        var reclaimedBytes = directoryBytes
        if let markdown {
            do {
                try moveToTrash(markdown.url)
                trashedMarkdown = true
                reclaimedBytes += markdown.bytes
            } catch {
                warnings.append(
                    "The exported note could not be moved to the Trash: "
                        + "\(markdown.url.path) (\(error.localizedDescription))"
                )
            }
        }

        return SessionDeletionReport(
            sessionID: plan.sessionID,
            trashedMarkdown: trashedMarkdown,
            reclaimedBytes: reclaimedBytes,
            warnings: warnings
        )
    }

    // MARK: - Resolution

    private func validatedSessionDirectory(for sessionID: String) throws -> URL {
        guard !sessionID.isEmpty,
              URL(fileURLWithPath: sessionID).lastPathComponent == sessionID,
              !sessionID.hasPrefix(".") else {
            throw SessionDeletionError.sessionNotFound(sessionID)
        }
        let root = recordingsRoot.standardizedFileURL
        let directoryURL = root
            .appendingPathComponent(sessionID, isDirectory: true)
            .standardizedFileURL
        guard directoryURL.deletingLastPathComponent() == root,
              directoryURL.lastPathComponent == sessionID else {
            throw SessionDeletionError.sessionNotFound(sessionID)
        }
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw SessionDeletionError.sessionNotFound(sessionID)
        }
        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SessionDeletionError.sessionDirectoryIsNotEligible(path: directoryURL.path)
        }
        // A folder a live process still owns is being recorded into, possibly by
        // a second copy of the app this one knows nothing about.
        guard !ownership.classification(of: directoryURL).isLive else {
            throw SessionDeletionError.sessionIsInUse(sessionID)
        }
        return directoryURL
    }

    private func loadMetadata(in directoryURL: URL) throws -> SessionMetadata {
        let manifestURL = directoryURL.appendingPathComponent("session.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let metadata = try? SessionJSONCoder.makeDecoder().decode(
                  SessionMetadata.self,
                  from: data
              ) else {
            throw SessionDeletionError.sessionNotFound(directoryURL.lastPathComponent)
        }
        return metadata
    }

    /// The exported note when it is a plain Markdown file outside the session
    /// folder. Anything else — a directory, a symlink, a renamed file, a path
    /// under the folder that the recursive delete already covers — is nil.
    private func externalMarkdown(
        for metadata: SessionMetadata,
        sessionDirectory: URL
    ) -> (url: URL, bytes: Int64)? {
        guard let path = metadata.output?.markdownPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "md" else { return nil }
        if let expectedName = metadata.output?.markdownFileName, !expectedName.isEmpty,
           url.lastPathComponent != expectedName {
            return nil
        }
        let resolvedDirectory = sessionDirectory.resolvingSymlinksInPath().path
        let prefix = resolvedDirectory.hasSuffix("/") ? resolvedDirectory : resolvedDirectory + "/"
        guard !url.resolvingSymlinksInPath().path.hasPrefix(prefix) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        let bytes = Int64(
            values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        )
        return (url, bytes)
    }

    private func allocatedBytes(ofTreeAt directoryURL: URL) -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(
                values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            )
        }
        return total
    }
}
