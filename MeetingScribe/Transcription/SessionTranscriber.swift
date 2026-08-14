import Foundation

struct SessionTranscriptionResult: Equatable, Sendable {
    let metadata: SessionTranscriptionMetadata
    let systemTranscript: TrackTranscript?
    let microphoneTranscript: TrackTranscript?
    let mergedTranscript: MergedTranscript
    let speakerTurnArtifact: SpeakerTurnArtifact?
    let utteranceTranscript: ContinuousUtteranceTranscript?
    let diarizationMetadata: SessionDiarizationMetadata?
    let speakerDiarizationArtifact: SpeakerDiarizationArtifact?
    let resolvedTranscript: ResolvedTranscript?

    init(
        metadata: SessionTranscriptionMetadata,
        systemTranscript: TrackTranscript?,
        microphoneTranscript: TrackTranscript?,
        mergedTranscript: MergedTranscript,
        speakerTurnArtifact: SpeakerTurnArtifact? = nil,
        utteranceTranscript: ContinuousUtteranceTranscript? = nil,
        diarizationMetadata: SessionDiarizationMetadata? = nil,
        speakerDiarizationArtifact: SpeakerDiarizationArtifact? = nil,
        resolvedTranscript: ResolvedTranscript? = nil
    ) {
        self.metadata = metadata
        self.systemTranscript = systemTranscript
        self.microphoneTranscript = microphoneTranscript
        self.mergedTranscript = mergedTranscript
        self.speakerTurnArtifact = speakerTurnArtifact
        self.utteranceTranscript = utteranceTranscript
        self.diarizationMetadata = diarizationMetadata
        self.speakerDiarizationArtifact = speakerDiarizationArtifact
        self.resolvedTranscript = resolvedTranscript
    }
}

protocol SessionTranscribing: Sendable {
    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult

    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage,
        diarizationModelBundleURL: URL?
    ) async throws -> SessionTranscriptionResult

    func processSpeakers(
        session: RecordingSession,
        transcript: MergedTranscript,
        finalization: AudioFinalizationMetadata,
        diarizationModelBundleURL: URL?
    ) async throws -> SpeakerProcessingResult

}

extension SessionTranscribing {
    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage,
        diarizationModelBundleURL: URL?
    ) async throws -> SessionTranscriptionResult {
        try await transcribe(
            session: session,
            finalization: finalization,
            model: model,
            language: language
        )
    }

    func processSpeakers(
        session: RecordingSession,
        transcript: MergedTranscript,
        finalization: AudioFinalizationMetadata,
        diarizationModelBundleURL: URL?
    ) async throws -> SpeakerProcessingResult {
        SpeakerProcessingResult(
            metadata: SessionDiarizationMetadata(
                status: .unavailable,
                engine: "none",
                model: "none",
                configurationRevision: "none",
                startedAt: nil,
                completedAt: Date(),
                speakerCount: nil,
                segmentCount: nil,
                audioDurationSeconds: nil,
                wallTimeSeconds: nil,
                sourceAudioFingerprint: nil,
                warnings: [],
                failureReason: "Speaker processing is unavailable."
            ),
            artifact: nil,
            resolvedTranscript: nil
        )
    }

}

/// Transcribes system and microphone tracks sequentially with one reusable model context.
///
/// The context is retained between the two tracks to avoid loading the model
/// twice, then released after the complete session on success, failure, or
/// cancellation. Both full audio sample arrays are therefore never eager in
/// memory at the same time.
actor SessionTranscriber: SessionTranscribing {
    private let service: any SpeechTranscribing
    private let merger: TranscriptMerger
    private let utteranceArtifactStore: UtteranceArtifactStore
    private let now: @Sendable () -> Date

    init(
        service: any SpeechTranscribing = FluidAudioTranscriptionService(),
        merger: TranscriptMerger = TranscriptMerger(),
        utteranceArtifactStore: UtteranceArtifactStore = UtteranceArtifactStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.merger = merger
        self.utteranceArtifactStore = utteranceArtifactStore
        self.now = now
    }

    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
        try await transcribe(
            session: session,
            finalization: finalization,
            model: model,
            language: language,
            diarizationModelBundleURL: nil
        )
    }

    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage,
        diarizationModelBundleURL: URL?
    ) async throws -> SessionTranscriptionResult {
        _ = diarizationModelBundleURL // Retained only for protocol/source compatibility.
        do {
            let result = try await transcribeTracks(
                session: session,
                finalization: finalization,
                model: model,
                language: language
            )
            await service.releaseResources()
            return result
        } catch {
            await service.releaseResources()
            throw error
        }
    }

    private func transcribeTracks(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
        try Task.checkCancellation()
        let startedAt = now()
        var warnings: [String] = []
        var systemTranscript: TrackTranscript?
        if let system = finalization.system {
            let transcript = try await service.transcribe(
                SpeechTranscriptionRequest(
                    audioURL: session.directoryURL.appendingPathComponent(
                        system.fileName,
                        isDirectory: false
                    ),
                    model: model,
                    options: TranscriptionOptions(
                        language: language,
                        source: .system,
                        speaker: TranscriptSource.system.conversationParticipantLabel,
                        timelineOffsetSeconds: system.timelineOffsetSeconds
                    )
                )
            )
            try Task.checkCancellation()
            try persist(transcript, to: session.systemTrackTranscriptURL)
            systemTranscript = transcript
            if transcript.segments.isEmpty {
                warnings.append("No speech was detected in system audio.")
            }
            appendAutomaticLanguageFallbackWarning(
                for: transcript,
                requestedLanguage: language,
                warnings: &warnings
            )
        }

        var microphoneTranscript: TrackTranscript?
        if let microphone = finalization.microphone {
            try Task.checkCancellation()
            do {
                let transcript = try await service.transcribe(
                    SpeechTranscriptionRequest(
                        audioURL: session.directoryURL.appendingPathComponent(
                            microphone.fileName,
                            isDirectory: false
                        ),
                        model: model,
                        options: TranscriptionOptions(
                            language: language,
                            source: .microphone,
                            speaker: TranscriptSource.microphone.conversationParticipantLabel,
                            timelineOffsetSeconds: microphone.timelineOffsetSeconds
                        )
                    )
                )
                try Task.checkCancellation()
                try persist(transcript, to: session.microphoneTrackTranscriptURL)
                microphoneTranscript = transcript
                if transcript.segments.isEmpty {
                    warnings.append("No speech was detected in microphone audio.")
                }
                appendAutomaticLanguageFallbackWarning(
                    for: transcript,
                    requestedLanguage: language,
                    warnings: &warnings
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.append("Microphone transcription failed: \(error.localizedDescription)")
            }
        } else {
            warnings.append("Microphone working audio was unavailable for transcription.")
        }

        try Task.checkCancellation()
        let completedAt = now()
        let mergedTranscript = try merger.merge(
            sessionID: session.metadata.id,
            title: session.metadata.title,
            systemTranscript: systemTranscript,
            microphoneTranscript: microphoneTranscript,
            completedAt: completedAt
        )
        try Task.checkCancellation()
        try persist(mergedTranscript, to: session.mergedTranscriptURL)

        // Legacy speaker artifacts remain decodable, but new transcripts are
        // grouped only by their recorded audio source.
        let speakerTurnArtifact: SpeakerTurnArtifact? = nil

        let utteranceTranscript: ContinuousUtteranceTranscript?
        do {
            let artifact = try utteranceArtifactStore.makeArtifact(
                transcript: mergedTranscript,
                turnArtifact: speakerTurnArtifact
            )
            try utteranceArtifactStore.persist(artifact, to: session.utteranceTranscriptURL)
            utteranceTranscript = artifact
        } catch {
            warnings.append(
                "Source-block grouping failed; raw transcript output was preserved: "
                    + error.localizedDescription
            )
            utteranceTranscript = nil
        }

        let metadata = SessionTranscriptionMetadata(
            status: .completed,
            model: model.provenance.model,
            startedAt: startedAt,
            completedAt: completedAt,
            systemSegmentCount: systemTranscript?.segments.count,
            microphoneSegmentCount: microphoneTranscript?.segments.count,
            mergedSegmentCount: mergedTranscript.segments.count,
            utteranceCount: utteranceTranscript?.utterances.count,
            turnBoundaryCount: speakerTurnArtifact?.boundaries.count,
            turnDetectionModel: speakerTurnArtifact?.model,
            utteranceFallbackUsed: false,
            systemPerformance: systemTranscript?.performance,
            microphonePerformance: microphoneTranscript?.performance,
            warnings: warnings,
            failureReason: nil,
            provenance: model.provenance
        )
        return SessionTranscriptionResult(
            metadata: metadata,
            systemTranscript: systemTranscript,
            microphoneTranscript: microphoneTranscript,
            mergedTranscript: mergedTranscript,
            speakerTurnArtifact: speakerTurnArtifact,
            utteranceTranscript: utteranceTranscript,
            diarizationMetadata: nil,
            speakerDiarizationArtifact: nil,
            resolvedTranscript: nil
        )
    }

    private func persist(_ transcript: TrackTranscript, to url: URL) throws {
        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        try data.write(to: url, options: .atomic)
    }

    private func persist(_ transcript: MergedTranscript, to url: URL) throws {
        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        try data.write(to: url, options: .atomic)
    }

    private func appendAutomaticLanguageFallbackWarning(
        for transcript: TrackTranscript,
        requestedLanguage: TranscriptionLanguage,
        warnings: inout [String]
    ) {
        guard requestedLanguage != .automatic,
              transcript.detectedLanguage != requestedLanguage.rawValue else {
            return
        }
        warnings.append(
            "Strongly repetitive output for the selected language was replaced "
                + "using automatic language detection (\(transcript.detectedLanguage))."
        )
    }
}
