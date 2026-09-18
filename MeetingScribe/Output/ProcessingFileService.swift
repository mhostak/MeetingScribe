import Foundation

struct RecoveredProcessingArtifacts: Equatable, Sendable {
    let transcript: MergedTranscript
    let utteranceTranscript: ContinuousUtteranceTranscript?
    let analysis: AIAnalysisArtifact?
}

protocol ProcessingFileServicing: Sendable {
    func loadRecoveredArtifacts(from session: RecordingSession) async -> RecoveredProcessingArtifacts?

    func loadUserNotes(from session: RecordingSession) async -> String?

    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        analysis: AIAnalysisArtifact?,
        notes: String?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult
}

extension ProcessingFileServicing {
    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        analysis: AIAnalysisArtifact?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        try await exportMarkdown(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            analysis: analysis,
            notes: nil,
            to: directoryURL
        )
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        analysis: AIAnalysisArtifact?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        try await exportMarkdown(
            session: session,
            transcript: transcript,
            utteranceTranscript: nil,
            analysis: analysis,
            notes: nil,
            to: directoryURL
        )
    }
}

actor ProcessingFileService: ProcessingFileServicing {
    private let outputExporter: OutputExporter
    private let fileManager: FileManager
    private let utteranceArtifactStore: UtteranceArtifactStore

    init(
        outputExporter: OutputExporter = OutputExporter(),
        fileManager: FileManager = .default,
        utteranceArtifactStore: UtteranceArtifactStore = UtteranceArtifactStore()
    ) {
        self.outputExporter = outputExporter
        self.fileManager = fileManager
        self.utteranceArtifactStore = utteranceArtifactStore
    }

    func loadRecoveredArtifacts(
        from session: RecordingSession
    ) async -> RecoveredProcessingArtifacts? {
        guard fileManager.fileExists(atPath: session.mergedTranscriptURL.path),
              let transcriptData = try? Data(contentsOf: session.mergedTranscriptURL),
              let transcript = try? TranscriptJSONCoder.makeDecoder().decode(
                  MergedTranscript.self,
                  from: transcriptData
              ),
              transcript.sessionID == session.metadata.id else {
            return nil
        }

        let utteranceTranscript: ContinuousUtteranceTranscript?
        if let loaded = try? utteranceArtifactStore.loadValidArtifact(
            from: session.utteranceTranscriptURL,
            transcript: transcript,
            turnArtifact: nil
        ) {
            utteranceTranscript = loaded
        } else if let fallback = try? utteranceArtifactStore.makeArtifact(
            transcript: transcript,
            turnArtifact: nil
        ) {
            try? utteranceArtifactStore.persist(fallback, to: session.utteranceTranscriptURL)
            utteranceTranscript = fallback
        } else {
            utteranceTranscript = nil
        }

        let analysis: AIAnalysisArtifact?
        if fileManager.fileExists(atPath: session.analysisURL.path),
           let analysisData = try? Data(contentsOf: session.analysisURL) {
            analysis = try? JSONDecoder().decode(AIAnalysisArtifact.self, from: analysisData)
        } else {
            analysis = nil
        }

        return RecoveredProcessingArtifacts(
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            analysis: analysis
        )
    }

    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws {
        let data = try JSONEncoder().encode(analysis)
        try data.write(to: url, options: .atomic)
    }

    func loadUserNotes(from session: RecordingSession) async -> String? {
        let notesURL = session.notesURL
        guard fileManager.fileExists(atPath: notesURL.path),
              let notesData = try? Data(contentsOf: notesURL),
              let notes = String(data: notesData, encoding: .utf8),
              !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return notes
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        analysis: AIAnalysisArtifact?,
        notes: String?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        return try outputExporter.export(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            analysis: analysis,
            notes: notes,
            to: directoryURL
        )
    }
}
