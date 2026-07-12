import Foundation

protocol AudioFinalizing: Sendable {
    func finalize(
        session: RecordingSession,
        diagnostics: CaptureSessionDiagnostics
    ) async throws -> AudioFinalizationMetadata
}

/// Converts captured tracks and maps them onto one relative session timeline.
///
/// System audio is required. A microphone track is optional and participates
/// only when it has buffers and its host-time start is within the plausibility
/// guard of the system start. The origin is `min(valid track starts)` and each
/// output offset is `max(0, trackStart - origin)`. No silence is inserted into
/// the WAV files; the offset is added later to Whisper segment timestamps.
struct AudioFinalizer: AudioFinalizing {
    static let maximumPlausibleTrackStartDifference: TimeInterval = 60

    private let converter: WorkingAudioConverter
    private let now: @Sendable () -> Date

    init(
        converter: WorkingAudioConverter = WorkingAudioConverter(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.converter = converter
        self.now = now
    }

    /// Finalizes available tracks while preserving every original CAF on failure.
    func finalize(
        session: RecordingSession,
        diagnostics: CaptureSessionDiagnostics
    ) async throws -> AudioFinalizationMetadata {
        let systemDiagnostics = diagnostics.systemAudio
        try validateRequiredTrack(systemDiagnostics, name: "System audio")

        guard let systemStart = systemDiagnostics.firstPresentationTimestamp else {
            throw AudioFinalizerError.missingTimeline(trackName: "System audio")
        }

        let microphoneDiagnostics = diagnostics.microphone
        let microphoneStart = microphoneDiagnostics.firstPresentationTimestamp
        let hasCompatibleMicrophoneTimeline = microphoneStart.map {
            abs($0 - systemStart) <= Self.maximumPlausibleTrackStartDifference
        } ?? false
        let canFinalizeMicrophone = microphoneDiagnostics.bufferCount > 0
            && hasCompatibleMicrophoneTimeline
        let timelineOrigin = min(
            systemStart,
            canFinalizeMicrophone
                ? microphoneDiagnostics.firstPresentationTimestamp ?? systemStart
                : systemStart
        )

        let system = try finalizeTrack(
            inputURL: session.systemAudioURL,
            outputURL: session.systemWorkingAudioURL,
            startedAt: systemStart,
            timelineOrigin: timelineOrigin
        )

        var warnings: [String] = []
        var microphone: FinalizedAudioTrackMetadata?

        if canFinalizeMicrophone, let microphoneStart {
            do {
                microphone = try finalizeTrack(
                    inputURL: session.microphoneAudioURL,
                    outputURL: session.microphoneWorkingAudioURL,
                    startedAt: microphoneStart,
                    timelineOrigin: timelineOrigin
                )
                if let failureReason = microphoneDiagnostics.failureReason {
                    warnings.append("Microphone capture ended early: \(failureReason)")
                }
            } catch {
                warnings.append("Microphone working audio was not created: \(error.localizedDescription)")
            }
        } else if microphoneDiagnostics.bufferCount > 0,
                  microphoneStart != nil,
                  !hasCompatibleMicrophoneTimeline {
            warnings.append(
                "Microphone track was preserved but skipped because its timestamp did not share a plausible host-time origin with system audio."
            )
        } else if let failureReason = microphoneDiagnostics.failureReason {
            warnings.append("Microphone capture was unavailable: \(failureReason)")
        } else {
            warnings.append("Microphone track contained no audio buffers.")
        }

        return AudioFinalizationMetadata(
            completedAt: now(),
            timelineOrigin: timelineOrigin,
            system: system,
            microphone: microphone,
            warnings: warnings
        )
    }

    private func validateRequiredTrack(
        _ diagnostics: AudioCaptureDiagnostics,
        name: String
    ) throws {
        if let failureReason = diagnostics.failureReason {
            throw AudioFinalizerError.requiredTrackFailed(
                trackName: name,
                reason: failureReason
            )
        }
        guard diagnostics.bufferCount > 0, diagnostics.totalFrames > 0 else {
            throw AudioFinalizerError.emptyRequiredTrack(trackName: name)
        }
    }

    private func finalizeTrack(
        inputURL: URL,
        outputURL: URL,
        startedAt: Double,
        timelineOrigin: Double
    ) throws -> FinalizedAudioTrackMetadata {
        let converted = try converter.convert(inputURL: inputURL, outputURL: outputURL)
        return FinalizedAudioTrackMetadata(
            fileName: outputURL.lastPathComponent,
            sampleRate: converted.sampleRate,
            channelCount: converted.channelCount,
            totalFrames: converted.totalFrames,
            durationSeconds: converted.durationSeconds,
            timelineOffsetSeconds: max(0, startedAt - timelineOrigin)
        )
    }
}

enum AudioFinalizerError: Error, LocalizedError {
    case requiredTrackFailed(trackName: String, reason: String)
    case emptyRequiredTrack(trackName: String)
    case missingTimeline(trackName: String)

    var errorDescription: String? {
        switch self {
        case let .requiredTrackFailed(trackName, reason):
            return "\(trackName) capture failed: \(reason)"
        case let .emptyRequiredTrack(trackName):
            return "\(trackName) track is empty. The original recording files were preserved."
        case let .missingTimeline(trackName):
            return "\(trackName) has no presentation timestamp. The original recording files were preserved."
        }
    }
}
