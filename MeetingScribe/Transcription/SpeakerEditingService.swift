import Foundation

struct SpeakerEditorSnapshot: Equatable, Sendable {
    let sessionID: String
    let speakers: [SpeakerProfile]
    let diarizedSegmentCount: Int
    let summaries: [SpeakerProfileSummary]
}

struct SpeakerProfileSummary: Equatable, Sendable {
    let speakerID: String
    let turnCount: Int
    let durationSeconds: Double
    let examples: [String]
}

struct SpeakerEditResult: Equatable, Sendable {
    let artifact: SpeakerDiarizationArtifact
    let resolvedTranscript: ResolvedTranscript
    let markdownURL: URL?
}

enum SpeakerEditingError: Error, Equatable, LocalizedError {
    case transcriptMissing
    case finalizedAudioMissing
    case diarizationMissing

    var errorDescription: String? {
        switch self {
        case .transcriptMissing:
            return "The raw transcript required for speaker editing is missing."
        case .finalizedAudioMissing:
            return "The finalized system audio required to validate speakers is missing."
        case .diarizationMissing:
            return "This recording does not have a valid speaker diarization artifact yet."
        }
    }
}

actor SpeakerEditingService {
    private let fileManager: FileManager
    private let artifactStore: SpeakerArtifactStore
    private let resolver: SpeakerTranscriptResolver
    private let resolvedStore: ResolvedTranscriptStore
    private let renderer: MarkdownRenderer
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        artifactStore: SpeakerArtifactStore = SpeakerArtifactStore(),
        resolver: SpeakerTranscriptResolver = SpeakerTranscriptResolver(),
        resolvedStore: ResolvedTranscriptStore = ResolvedTranscriptStore(),
        renderer: MarkdownRenderer = MarkdownRenderer(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.artifactStore = artifactStore
        self.resolver = resolver
        self.resolvedStore = resolvedStore
        self.renderer = renderer
        self.now = now
    }

    func load(session: RecordingSession) throws -> SpeakerEditorSnapshot {
        let values = try loadValidated(session: session)
        let resolved = try resolver.resolve(
            transcript: values.transcript,
            artifact: values.artifact,
            transcriptFingerprint: values.transcriptFingerprint
        )
        return SpeakerEditorSnapshot(
            sessionID: session.metadata.id,
            speakers: values.artifact.speakers,
            diarizedSegmentCount: values.artifact.result.segments.count,
            summaries: makeSummaries(
                transcript: values.transcript,
                artifact: values.artifact,
                resolved: resolved
            )
        )
    }

    func save(
        session: RecordingSession,
        speakers: [SpeakerProfile]
    ) throws -> SpeakerEditResult {
        let values = try loadValidated(session: session)
        try artifactStore.validateProfiles(speakers)
        var artifact = values.artifact
        artifact.speakers = speakers.map { profile in
            var normalized = profile
            normalized.displayName = profile.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
        artifact.modifiedAt = now()
        try artifactStore.persist(artifact, to: session.speakerDiarizationURL)

        let resolved = try resolver.resolve(
            transcript: values.transcript,
            artifact: artifact,
            transcriptFingerprint: values.transcriptFingerprint
        )
        try resolvedStore.persist(resolved, to: session.resolvedTranscriptURL)
        let markdownURL = try regenerateMarkdownIfPresent(
            session: session,
            transcript: values.transcript,
            resolved: resolved
        )
        return SpeakerEditResult(
            artifact: artifact,
            resolvedTranscript: resolved,
            markdownURL: markdownURL
        )
    }

    private func loadValidated(
        session: RecordingSession
    ) throws -> (
        transcript: MergedTranscript,
        artifact: SpeakerDiarizationArtifact,
        transcriptFingerprint: String
    ) {
        guard fileManager.fileExists(atPath: session.mergedTranscriptURL.path),
              let data = try? Data(contentsOf: session.mergedTranscriptURL),
              let transcript = try? TranscriptJSONCoder.makeDecoder().decode(
                MergedTranscript.self,
                from: data
              ) else {
            throw SpeakerEditingError.transcriptMissing
        }
        guard let finalization = session.metadata.audioFinalization else {
            throw SpeakerEditingError.finalizedAudioMissing
        }
        let audioURL = session.directoryURL.appendingPathComponent(
            finalization.system.fileName,
            isDirectory: false
        )
        let transcriptFingerprint = try artifactStore.fingerprint(transcript: transcript)
        guard let artifact = try artifactStore.loadValid(
            from: session.speakerDiarizationURL,
            sessionID: session.metadata.id,
            sourceAudioURL: audioURL,
            transcript: transcript,
            expectedTimelineOffsetSeconds: finalization.system.timelineOffsetSeconds,
            sourceTranscriptFingerprint: transcriptFingerprint
        ) else {
            throw SpeakerEditingError.diarizationMissing
        }
        return (transcript, artifact, transcriptFingerprint)
    }

    private func regenerateMarkdownIfPresent(
        session: RecordingSession,
        transcript: MergedTranscript,
        resolved: ResolvedTranscript
    ) throws -> URL? {
        guard let path = session.metadata.output?.markdownPath,
              !path.isEmpty else {
            return nil
        }
        let markdownURL = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: markdownURL.path) else { return nil }
        let analysis: AIAnalysisArtifact?
        if fileManager.fileExists(atPath: session.analysisURL.path),
           let data = try? Data(contentsOf: session.analysisURL) {
            analysis = try? JSONDecoder().decode(AIAnalysisArtifact.self, from: data)
        } else {
            analysis = nil
        }
        let markdown = renderer.render(
            session: session.metadata,
            transcript: transcript,
            resolvedTranscript: resolved,
            analysis: analysis
        )
        guard let data = markdown.data(using: .utf8) else {
            throw OutputExportError.couldNotEncodeMarkdown
        }
        try data.write(to: markdownURL, options: .atomic)
        return markdownURL
    }

    private func makeSummaries(
        transcript: MergedTranscript,
        artifact: SpeakerDiarizationArtifact,
        resolved: ResolvedTranscript
    ) -> [SpeakerProfileSummary] {
        artifact.speakers.map { profile in
            let effectiveID = artifactStore.effectiveProfile(
                for: profile.id,
                in: artifact
            )?.id ?? profile.id
            let turns: [(start: Double, end: Double)]
            if profile.source == .microphone {
                turns = transcript.segments
                    .filter { $0.source == .microphone }
                    .map { ($0.start, $0.end) }
            } else {
                turns = artifact.result.segments.compactMap { segment in
                    guard artifactStore.effectiveProfile(
                        for: segment.speakerID,
                        in: artifact
                    )?.id == effectiveID else { return nil }
                    return (segment.start, segment.end)
                }
            }
            let examples = resolved.segments
                .filter { $0.speakerID == effectiveID }
                .filter { !$0.text.isEmpty }
                .map { "[\(timestamp($0.start))] \($0.text)" }
                .prefix(2)
            return SpeakerProfileSummary(
                speakerID: profile.id,
                turnCount: turns.count,
                durationSeconds: turns.reduce(0) { result, turn in
                    result + max(0, turn.end - turn.start)
                },
                examples: Array(examples)
            )
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
