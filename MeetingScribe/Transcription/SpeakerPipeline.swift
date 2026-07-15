import Foundation

struct SpeakerProcessingResult: Equatable, Sendable {
    let metadata: SessionDiarizationMetadata
    let artifact: SpeakerDiarizationArtifact?
    let resolvedTranscript: ResolvedTranscript?
}

actor SpeakerPipeline {
    private let diarizer: any SpeakerDiarizing
    private let artifactStore: SpeakerArtifactStore
    private let resolver: SpeakerTranscriptResolver
    private let resolvedStore: ResolvedTranscriptStore
    private let configuration: FluidAudioDiarizationConfiguration
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval

    init(
        diarizer: any SpeakerDiarizing = FluidAudioDiarizationService(),
        artifactStore: SpeakerArtifactStore = SpeakerArtifactStore(),
        resolver: SpeakerTranscriptResolver = SpeakerTranscriptResolver(),
        resolvedStore: ResolvedTranscriptStore = ResolvedTranscriptStore(),
        configuration: FluidAudioDiarizationConfiguration = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.diarizer = diarizer
        self.artifactStore = artifactStore
        self.resolver = resolver
        self.resolvedStore = resolvedStore
        self.configuration = configuration
        self.now = now
        self.uptime = uptime
    }

    func process(
        session: RecordingSession,
        transcript: MergedTranscript,
        systemAudioURL: URL,
        modelBundleURL: URL?
    ) async throws -> SpeakerProcessingResult {
        try Task.checkCancellation()
        if let artifact = try? artifactStore.loadValid(
            from: session.speakerDiarizationURL,
            sessionID: session.metadata.id,
            sourceAudioURL: systemAudioURL,
            transcript: transcript
        ) {
            let resolved = try loadOrResolve(
                session: session,
                transcript: transcript,
                artifact: artifact
            )
            return SpeakerProcessingResult(
                metadata: completedMetadata(
                    artifact: artifact,
                    startedAt: nil,
                    completedAt: now(),
                    wallTime: nil,
                    warnings: ["Reused a valid persisted speaker diarization artifact."]
                ),
                artifact: artifact,
                resolvedTranscript: resolved
            )
        }

        guard let modelBundleURL else {
            return SpeakerProcessingResult(
                metadata: SessionDiarizationMetadata(
                    status: .modelMissing,
                    engine: "FluidAudio",
                    model: FluidAudioModelDescriptor.speakerDiarization.repository,
                    configurationRevision: configuration.revision,
                    startedAt: nil,
                    completedAt: now(),
                    speakerCount: nil,
                    segmentCount: nil,
                    audioDurationSeconds: nil,
                    wallTimeSeconds: nil,
                    sourceAudioFingerprint: nil,
                    warnings: ["Speaker-aware output was skipped; deterministic source grouping remains available."],
                    failureReason: "The verified FluidAudio diarization model is not installed."
                ),
                artifact: nil,
                resolvedTranscript: nil
            )
        }

        let startedAt = now()
        let startedUptime = uptime()
        do {
            let result = try await diarizer.diarize(SpeakerDiarizationRequest(
                audioURL: systemAudioURL,
                modelBundleURL: modelBundleURL,
                options: SpeakerDiarizationOptions()
            ))
            try Task.checkCancellation()
            let artifact = try artifactStore.makeArtifact(
                sessionID: session.metadata.id,
                result: result,
                sourceAudioURL: systemAudioURL,
                transcript: transcript,
                configurationRevision: configuration.revision
            )
            try artifactStore.persist(artifact, to: session.speakerDiarizationURL)
            let resolved = try resolver.resolve(transcript: transcript, artifact: artifact)
            try resolvedStore.persist(resolved, to: session.resolvedTranscriptURL)
            await diarizer.releaseResources()
            return SpeakerProcessingResult(
                metadata: completedMetadata(
                    artifact: artifact,
                    startedAt: startedAt,
                    completedAt: now(),
                    wallTime: max(0, uptime() - startedUptime),
                    warnings: result.segments.isEmpty
                        ? ["No system-audio speaker turns were detected; microphone identity remains available."]
                        : []
                ),
                artifact: artifact,
                resolvedTranscript: resolved
            )
        } catch is CancellationError {
            await diarizer.releaseResources()
            throw CancellationError()
        } catch {
            await diarizer.releaseResources()
            return SpeakerProcessingResult(
                metadata: SessionDiarizationMetadata(
                    status: .failed,
                    engine: "FluidAudio",
                    model: FluidAudioModelDescriptor.speakerDiarization.repository,
                    configurationRevision: configuration.revision,
                    startedAt: startedAt,
                    completedAt: now(),
                    speakerCount: nil,
                    segmentCount: nil,
                    audioDurationSeconds: nil,
                    wallTimeSeconds: max(0, uptime() - startedUptime),
                    sourceAudioFingerprint: nil,
                    warnings: ["Raw transcript and deterministic source grouping were preserved."],
                    failureReason: error.localizedDescription
                ),
                artifact: nil,
                resolvedTranscript: nil
            )
        }
    }

    func resolvePersisted(
        session: RecordingSession,
        transcript: MergedTranscript,
        artifact: SpeakerDiarizationArtifact
    ) throws -> ResolvedTranscript {
        let resolved = try resolver.resolve(transcript: transcript, artifact: artifact)
        try resolvedStore.persist(resolved, to: session.resolvedTranscriptURL)
        return resolved
    }

    private func loadOrResolve(
        session: RecordingSession,
        transcript: MergedTranscript,
        artifact: SpeakerDiarizationArtifact
    ) throws -> ResolvedTranscript {
        if let resolved = try resolvedStore.loadValid(
            from: session.resolvedTranscriptURL,
            transcript: transcript,
            artifact: artifact
        ) {
            return resolved
        }
        return try resolvePersisted(
            session: session,
            transcript: transcript,
            artifact: artifact
        )
    }

    private func completedMetadata(
        artifact: SpeakerDiarizationArtifact,
        startedAt: Date?,
        completedAt: Date,
        wallTime: Double?,
        warnings: [String]
    ) -> SessionDiarizationMetadata {
        SessionDiarizationMetadata(
            status: .completed,
            engine: artifact.result.engine,
            model: artifact.result.model,
            configurationRevision: artifact.configurationRevision,
            startedAt: startedAt,
            completedAt: completedAt,
            speakerCount: artifact.result.speakerIDs.count,
            segmentCount: artifact.result.segments.count,
            audioDurationSeconds: artifact.result.audioDurationSeconds,
            wallTimeSeconds: wallTime,
            sourceAudioFingerprint: artifact.sourceAudioFingerprint,
            warnings: warnings,
            failureReason: nil
        )
    }
}
