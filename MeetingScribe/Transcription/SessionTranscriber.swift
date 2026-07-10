import Foundation

struct SessionTranscriptionResult: Equatable, Sendable {
    let metadata: SessionTranscriptionMetadata
    let systemTranscript: TrackTranscript
    let microphoneTranscript: TrackTranscript?
}

protocol SessionTranscribing: Sendable {
    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        modelURL: URL,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult
}

actor SessionTranscriber: SessionTranscribing {
    private let service: any TranscriptionService
    private let now: @Sendable () -> Date

    init(
        service: any TranscriptionService = WhisperCppService(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.now = now
    }

    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        modelURL: URL,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
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
        try persist(systemTranscript, to: session.systemTrackTranscriptURL)

        var warnings: [String] = []
        var microphoneTranscript: TrackTranscript?
        if let microphone = finalization.microphone {
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
                try persist(transcript, to: session.microphoneTrackTranscriptURL)
                microphoneTranscript = transcript
            } catch {
                warnings.append("Microphone transcription failed: \(error.localizedDescription)")
            }
        } else {
            warnings.append("Microphone working audio was unavailable for transcription.")
        }

        let metadata = SessionTranscriptionMetadata(
            status: .completed,
            model: modelURL.lastPathComponent,
            startedAt: startedAt,
            completedAt: now(),
            systemSegmentCount: systemTranscript.segments.count,
            microphoneSegmentCount: microphoneTranscript?.segments.count,
            warnings: warnings,
            failureReason: nil
        )
        return SessionTranscriptionResult(
            metadata: metadata,
            systemTranscript: systemTranscript,
            microphoneTranscript: microphoneTranscript
        )
    }

    private func persist(_ transcript: TrackTranscript, to url: URL) throws {
        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        try data.write(to: url, options: .atomic)
    }
}
