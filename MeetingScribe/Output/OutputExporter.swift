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
        resolvedTranscript: ResolvedTranscript? = nil,
        analysis: AIAnalysisArtifact? = nil,
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
        let outputURL = try availableURL(
            preferredName: preferredName,
            directoryURL: directoryURL
        )
        let markdown = renderer.render(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            resolvedTranscript: resolvedTranscript,
            analysis: analysis
        )
        guard let data = markdown.data(using: .utf8) else {
            throw OutputExportError.couldNotEncodeMarkdown
        }
        try data.write(to: outputURL, options: .atomic)
        return MarkdownExportResult(fileURL: outputURL, exportedAt: now())
    }

    private func availableURL(preferredName: String, directoryURL: URL) throws -> URL {
        let preferredURL = directoryURL.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        let pathExtension = preferredURL.pathExtension
        for suffix in 2...9_999 {
            let candidate = directoryURL
                .appendingPathComponent("\(baseName) (\(suffix))")
                .appendingPathExtension(pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
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
