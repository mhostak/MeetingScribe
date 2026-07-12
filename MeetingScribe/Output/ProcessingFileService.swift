import Foundation

struct RecoveredProcessingArtifacts: Equatable, Sendable {
    let transcript: MergedTranscript
    let analysis: MeetingAnalysis?
}

protocol ProcessingFileServicing: Sendable {
    func loadRecoveredArtifacts(from session: RecordingSession) async -> RecoveredProcessingArtifacts?

    func persistAnalysis(_ analysis: MeetingAnalysis, to url: URL) async throws

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        analysis: MeetingAnalysis?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult
}

actor ProcessingFileService: ProcessingFileServicing {
    private let outputExporter: OutputExporter
    private let fileManager: FileManager

    init(
        outputExporter: OutputExporter = OutputExporter(),
        fileManager: FileManager = .default
    ) {
        self.outputExporter = outputExporter
        self.fileManager = fileManager
    }

    func loadRecoveredArtifacts(
        from session: RecordingSession
    ) async -> RecoveredProcessingArtifacts? {
        guard fileManager.fileExists(atPath: session.mergedTranscriptURL.path),
              let transcriptData = try? Data(contentsOf: session.mergedTranscriptURL),
              let transcript = try? TranscriptJSONCoder.makeDecoder().decode(
                  MergedTranscript.self,
                  from: transcriptData
              ) else {
            return nil
        }

        let analysis: MeetingAnalysis?
        if fileManager.fileExists(atPath: session.analysisURL.path),
           let analysisData = try? Data(contentsOf: session.analysisURL) {
            analysis = try? JSONDecoder().decode(MeetingAnalysis.self, from: analysisData)
        } else {
            analysis = nil
        }
        return RecoveredProcessingArtifacts(transcript: transcript, analysis: analysis)
    }

    func persistAnalysis(_ analysis: MeetingAnalysis, to url: URL) async throws {
        let data = try JSONEncoder().encode(analysis)
        try data.write(to: url, options: .atomic)
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        analysis: MeetingAnalysis?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        return try outputExporter.export(
            session: session,
            transcript: transcript,
            analysis: analysis,
            to: directoryURL
        )
    }
}
