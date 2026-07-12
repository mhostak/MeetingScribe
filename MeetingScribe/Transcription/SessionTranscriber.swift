import Foundation

struct SessionTranscriptionResult: Equatable, Sendable {
    let metadata: SessionTranscriptionMetadata
    let systemTranscript: TrackTranscript
    let microphoneTranscript: TrackTranscript?
    let mergedTranscript: MergedTranscript
}

protocol SessionTranscribing: Sendable {
    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        modelURL: URL,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult
}

/// Transcribes system and microphone tracks sequentially with one reusable model context.
///
/// The context is retained between the two tracks to avoid loading the model
/// twice, then released after the complete session on success, failure, or
/// cancellation. Both full audio sample arrays are therefore never eager in
/// memory at the same time.
actor SessionTranscriber: SessionTranscribing {
    private let service: any TranscriptionService
    private let merger: TranscriptMerger
    private let now: @Sendable () -> Date

    init(
        service: any TranscriptionService = WhisperCppService(),
        merger: TranscriptMerger = TranscriptMerger(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.merger = merger
        self.now = now
    }

    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        modelURL: URL,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
        do {
            let result = try await transcribeTracks(
                session: session,
                finalization: finalization,
                modelURL: modelURL,
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
        modelURL: URL,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
        try Task.checkCancellation()
        let startedAt = now()
        let systemTranscript = try await service.transcribe(
            audioURL: session.systemWorkingAudioURL,
            modelURL: modelURL,
            options: TranscriptionOptions(
                language: language,
                source: .system,
                speaker: "Other",
                timelineOffsetSeconds: finalization.system.timelineOffsetSeconds
            )
        )
        try Task.checkCancellation()
        try persist(systemTranscript, to: session.systemTrackTranscriptURL)

        var warnings: [String] = []
        var microphoneTranscript: TrackTranscript?
        if let microphone = finalization.microphone {
            try Task.checkCancellation()
            do {
                let transcript = try await service.transcribe(
                    audioURL: session.microphoneWorkingAudioURL,
                    modelURL: modelURL,
                    options: TranscriptionOptions(
                        language: language,
                        source: .microphone,
                        speaker: "Martin",
                        timelineOffsetSeconds: microphone.timelineOffsetSeconds
                    )
                )
                try Task.checkCancellation()
                try persist(transcript, to: session.microphoneTrackTranscriptURL)
                microphoneTranscript = transcript
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

        let metadata = SessionTranscriptionMetadata(
            status: .completed,
            model: modelURL.lastPathComponent,
            startedAt: startedAt,
            completedAt: completedAt,
            systemSegmentCount: systemTranscript.segments.count,
            microphoneSegmentCount: microphoneTranscript?.segments.count,
            mergedSegmentCount: mergedTranscript.segments.count,
            warnings: warnings,
            failureReason: nil
        )
        return SessionTranscriptionResult(
            metadata: metadata,
            systemTranscript: systemTranscript,
            microphoneTranscript: microphoneTranscript,
            mergedTranscript: mergedTranscript
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
}
