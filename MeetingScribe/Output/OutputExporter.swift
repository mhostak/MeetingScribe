import Foundation

struct MarkdownExportResult: Equatable, Sendable {
    let fileURL: URL
    let exportedAt: Date
}

struct OutputExporter: Sendable {
    private let renderer: MarkdownRenderer
    private let filenameSanitizer: FilenameSanitizer
    private let now: @Sendable () -> Date

    init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        filenameSanitizer: FilenameSanitizer = FilenameSanitizer(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.renderer = renderer
        self.filenameSanitizer = filenameSanitizer
        self.now = now
    }

    func export(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript? = nil,
        analysis: AIAnalysisArtifact? = nil,
        notes: String? = nil,
        to directoryURL: URL
    ) throws -> MarkdownExportResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw OutputExportError.destinationIsNotDirectory(path: directoryURL.path)
        }

        let startedAt = session.startedAt ?? session.createdAt
        let preferredName = filenameSanitizer.markdownFileName(
            title: session.title,
            sessionID: session.id,
            startedAt: startedAt,
            template: session.resolvedOutputFileNameTemplate
        )
        let markdown = renderer.render(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            analysis: analysis,
            notes: notes
        )
        guard let data = markdown.data(using: .utf8) else {
            throw OutputExportError.couldNotEncodeMarkdown
        }
        let outputURL = try writeWithoutOverwriting(
            data,
            preferredName: preferredName,
            directoryURL: directoryURL,
            reuseMatchingOutput: session.processing != nil
        )
        return MarkdownExportResult(fileURL: outputURL, exportedAt: now())
    }

    private func writeWithoutOverwriting(
        _ data: Data,
        preferredName: String,
        directoryURL: URL,
        reuseMatchingOutput: Bool
    ) throws -> URL {
        let preferredURL = directoryURL.appendingPathComponent(preferredName)
        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        let pathExtension = preferredURL.pathExtension
        for suffix in 1...9_999 {
            let candidate: URL
            if suffix == 1 {
                candidate = preferredURL
            } else {
                candidate = directoryURL
                    .appendingPathComponent("\(baseName) (\(suffix))")
                    .appendingPathExtension(pathExtension)
            }
            do {
                // This is an exclusive create, not an existence check followed
                // by a write. A concurrent exporter can therefore only claim a
                // different suffix and can never replace an existing note.
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // A process can exit after the exclusive create but before the
                // manifest checkpoint. Reuse only an unchanged, byte-identical
                // output from this session. The rendered frontmatter includes
                // recording_id, so another session cannot match this payload.
                if reuseMatchingOutput,
                   let existing = try? Data(contentsOf: candidate), existing == data {
                    return candidate
                }
                continue
            }
        }
        throw OutputExportError.couldNotCreateUniqueFileName
    }
}

enum OutputExportError: Error, Equatable, LocalizedError {
    case destinationIsNotDirectory(path: String)
    case couldNotEncodeMarkdown
    case couldNotCreateUniqueFileName

    var errorDescription: String? {
        switch self {
        case let .destinationIsNotDirectory(path):
            return "The Markdown output folder is unavailable: \(path)"
        case .couldNotEncodeMarkdown:
            return "The Markdown output could not be encoded as UTF-8."
        case .couldNotCreateUniqueFileName:
            return "A unique Markdown file name could not be created."
        }
    }
}
