import Foundation

struct RecoveredProcessingArtifacts: Equatable, Sendable {
    let transcript: MergedTranscript
    let utteranceTranscript: ContinuousUtteranceTranscript?
    let speakerDiarizationArtifact: SpeakerDiarizationArtifact?
    let resolvedTranscript: ResolvedTranscript?
    let analysis: MeetingAnalysis?
}

protocol ProcessingFileServicing: Sendable {
    func loadRecoveredArtifacts(from session: RecordingSession) async -> RecoveredProcessingArtifacts?

    func persistAnalysis(_ analysis: MeetingAnalysis, to url: URL) async throws

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        resolvedTranscript: ResolvedTranscript?,
        analysis: MeetingAnalysis?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult
}

extension ProcessingFileServicing {
    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        analysis: MeetingAnalysis?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        try await exportMarkdown(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            resolvedTranscript: nil,
            analysis: analysis,
            to: directoryURL
        )
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        analysis: MeetingAnalysis?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        try await exportMarkdown(
            session: session,
            transcript: transcript,
            utteranceTranscript: nil,
            resolvedTranscript: nil,
            analysis: analysis,
            to: directoryURL
        )
    }
}

actor ProcessingFileService: ProcessingFileServicing {
    private let outputExporter: OutputExporter
    private let fileManager: FileManager
    private let utteranceArtifactStore: UtteranceArtifactStore
    private let speakerArtifactStore: SpeakerArtifactStore
    private let speakerResolver: SpeakerTranscriptResolver
    private let resolvedTranscriptStore: ResolvedTranscriptStore

    init(
        outputExporter: OutputExporter = OutputExporter(),
        fileManager: FileManager = .default,
        utteranceArtifactStore: UtteranceArtifactStore = UtteranceArtifactStore(),
        speakerArtifactStore: SpeakerArtifactStore = SpeakerArtifactStore(),
        speakerResolver: SpeakerTranscriptResolver = SpeakerTranscriptResolver(),
        resolvedTranscriptStore: ResolvedTranscriptStore = ResolvedTranscriptStore()
    ) {
        self.outputExporter = outputExporter
        self.fileManager = fileManager
        self.utteranceArtifactStore = utteranceArtifactStore
        self.speakerArtifactStore = speakerArtifactStore
        self.speakerResolver = speakerResolver
        self.resolvedTranscriptStore = resolvedTranscriptStore
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

        let turnArtifact = validTurnArtifact(for: session)
        let utteranceTranscript: ContinuousUtteranceTranscript?
        if let loaded = try? utteranceArtifactStore.loadValidArtifact(
            from: session.utteranceTranscriptURL,
            transcript: transcript,
            turnArtifact: turnArtifact
        ) {
            utteranceTranscript = loaded
        } else if let fallback = try? utteranceArtifactStore.makeArtifact(
            transcript: transcript,
            turnArtifact: turnArtifact
        ) {
            try? utteranceArtifactStore.persist(fallback, to: session.utteranceTranscriptURL)
            utteranceTranscript = fallback
        } else {
            utteranceTranscript = nil
        }

        let analysis: MeetingAnalysis?
        if fileManager.fileExists(atPath: session.analysisURL.path),
           let analysisData = try? Data(contentsOf: session.analysisURL) {
            analysis = try? JSONDecoder().decode(MeetingAnalysis.self, from: analysisData)
        } else {
            analysis = nil
        }

        let speakerArtifacts = loadSpeakerArtifacts(
            session: session,
            transcript: transcript
        )
        return RecoveredProcessingArtifacts(
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            speakerDiarizationArtifact: speakerArtifacts.artifact,
            resolvedTranscript: speakerArtifacts.resolved,
            analysis: analysis
        )
    }

    func persistAnalysis(_ analysis: MeetingAnalysis, to url: URL) async throws {
        let data = try JSONEncoder().encode(analysis)
        try data.write(to: url, options: .atomic)
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        resolvedTranscript: ResolvedTranscript?,
        analysis: MeetingAnalysis?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        return try outputExporter.export(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            resolvedTranscript: resolvedTranscript,
            analysis: analysis,
            to: directoryURL
        )
    }

    private func loadSpeakerArtifacts(
        session: RecordingSession,
        transcript: MergedTranscript
    ) -> (artifact: SpeakerDiarizationArtifact?, resolved: ResolvedTranscript?) {
        guard let finalization = session.metadata.audioFinalization else {
            return (nil, nil)
        }
        let audioURL = session.directoryURL.appendingPathComponent(
            finalization.system.fileName,
            isDirectory: false
        )
        guard let artifact = try? speakerArtifactStore.loadValid(
            from: session.speakerDiarizationURL,
            sessionID: session.metadata.id,
            sourceAudioURL: audioURL,
            transcript: transcript,
            expectedTimelineOffsetSeconds: finalization.system.timelineOffsetSeconds
        ) else {
            return (nil, nil)
        }
        if let resolved = try? resolvedTranscriptStore.loadValid(
            from: session.resolvedTranscriptURL,
            transcript: transcript,
            artifact: artifact
        ) {
            return (artifact, resolved)
        }
        guard let resolved = try? speakerResolver.resolve(
            transcript: transcript,
            artifact: artifact
        ) else {
            return (artifact, nil)
        }
        try? resolvedTranscriptStore.persist(resolved, to: session.resolvedTranscriptURL)
        return (artifact, resolved)
    }

    private func validTurnArtifact(for session: RecordingSession) -> SpeakerTurnArtifact? {
        guard let artifact = try? utteranceArtifactStore.loadTurnArtifact(
            from: session.speakerTurnsURL,
            sessionID: session.metadata.id
        ) else {
            return nil
        }
        let audioFileName = session.metadata.audioFinalization?.system.fileName
            ?? session.metadata.audioFiles.systemWorking
            ?? "system-16k.wav"
        let audioURL = session.directoryURL.appendingPathComponent(audioFileName)
        guard fileManager.fileExists(atPath: audioURL.path),
              let fingerprint = try? utteranceArtifactStore.audioFingerprint(at: audioURL),
              fingerprint == artifact.sourceFingerprint else {
            return nil
        }
        return artifact
    }
}
