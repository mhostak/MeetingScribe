import AVFoundation
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
/// the WAV files; the offset is added later to transcription segment timestamps.
struct AudioFinalizer: AudioFinalizing {
    static let maximumPlausibleTrackStartDifference: TimeInterval = 60

    private let converter: WorkingAudioConverter
    private let repairer: PCMRecordingFileRepairer
    private let now: @Sendable () -> Date

    init(
        converter: WorkingAudioConverter = WorkingAudioConverter(),
        repairer: PCMRecordingFileRepairer = PCMRecordingFileRepairer(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.converter = converter
        self.repairer = repairer
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
        try repairer.repairIfNeeded(at: inputURL)
        let converted: ConvertedAudioFile
        let finalizedURL: URL
        if let captured = try inspectTranscriptionReadyAudio(at: inputURL) {
            converted = captured
            finalizedURL = inputURL
        } else {
            converted = try converter.convert(inputURL: inputURL, outputURL: outputURL)
            finalizedURL = outputURL
        }
        return FinalizedAudioTrackMetadata(
            fileName: finalizedURL.lastPathComponent,
            sampleRate: converted.sampleRate,
            channelCount: converted.channelCount,
            totalFrames: converted.totalFrames,
            durationSeconds: converted.durationSeconds,
            timelineOffsetSeconds: max(0, startedAt - timelineOrigin)
        )
    }

    private func inspectTranscriptionReadyAudio(at url: URL) throws -> ConvertedAudioFile? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioConversionError.unreadableInput(
                fileName: url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        let format = file.fileFormat
        guard abs(format.sampleRate - WorkingAudioConverter.targetSampleRate) < 0.5,
              format.channelCount == WorkingAudioConverter.targetChannelCount,
              format.commonFormat == .pcmFormatInt16 else {
            return nil
        }
        guard file.length > 0 else {
            throw AudioConversionError.emptyInput(fileName: url.lastPathComponent)
        }
        return ConvertedAudioFile(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            totalFrames: file.length
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

protocol AudioSourceCleaning: Sendable {
    func cleanupSourceCAFIfEligible(
        session: RecordingSession
    ) throws -> AudioSourceCleanupMetadata?
}

/// Deletes legacy full-quality CAF inputs only after every durable downstream
/// artifact required for the session has been verified.
struct AudioSourceCleaner: AudioSourceCleaning, @unchecked Sendable {
    private struct Candidate {
        let sourceURL: URL
        let finalized: FinalizedAudioTrackMetadata
        let transcriptURL: URL
    }

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    func cleanupSourceCAFIfEligible(
        session: RecordingSession
    ) throws -> AudioSourceCleanupMetadata? {
        guard session.metadata.transcription?.status == .completed,
              session.metadata.output?.status == .completed,
              let finalization = session.metadata.audioFinalization else {
            return nil
        }
        try validateExport(session.metadata.output)

        var candidates: [Candidate] = []
        if isExistingCAF(session.systemAudioURL) {
            guard session.metadata.transcription?.systemSegmentCount != nil else {
                throw AudioSourceCleanupError.trackWasNotTranscribed(
                    fileName: session.systemAudioURL.lastPathComponent
                )
            }
            candidates.append(Candidate(
                sourceURL: session.systemAudioURL,
                finalized: finalization.system,
                transcriptURL: session.systemTrackTranscriptURL
            ))
        }
        if isExistingCAF(session.microphoneAudioURL) {
            guard let microphone = finalization.microphone,
                  session.metadata.transcription?.microphoneSegmentCount != nil else {
                throw AudioSourceCleanupError.trackWasNotTranscribed(
                    fileName: session.microphoneAudioURL.lastPathComponent
                )
            }
            candidates.append(Candidate(
                sourceURL: session.microphoneAudioURL,
                finalized: microphone,
                transcriptURL: session.microphoneTrackTranscriptURL
            ))
        }
        guard !candidates.isEmpty else { return nil }

        // Validate the complete set before deleting the first source file.
        for candidate in candidates {
            try validateNonemptyFile(candidate.transcriptURL)
            let finalizedURL = session.directoryURL.appendingPathComponent(
                candidate.finalized.fileName,
                isDirectory: false
            )
            try validateTranscriptionAudio(finalizedURL, expected: candidate.finalized)
        }

        var deletedFiles: [String] = []
        for candidate in candidates {
            try fileManager.removeItem(at: candidate.sourceURL)
            deletedFiles.append(candidate.sourceURL.lastPathComponent)
        }
        return AudioSourceCleanupMetadata(
            status: .completed,
            completedAt: now(),
            deletedFiles: deletedFiles,
            failureReason: nil
        )
    }

    private func isExistingCAF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "caf"
            && fileManager.fileExists(atPath: url.path)
    }

    private func validateExport(_ output: SessionOutputMetadata?) throws {
        guard let path = output?.markdownPath, !path.isEmpty else {
            throw AudioSourceCleanupError.exportMissing
        }
        try validateNonemptyFile(URL(fileURLWithPath: path))
    }

    private func validateNonemptyFile(_ url: URL) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw AudioSourceCleanupError.artifactMissing(fileName: url.lastPathComponent)
        }
    }

    private func validateTranscriptionAudio(
        _ url: URL,
        expected: FinalizedAudioTrackMetadata
    ) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioSourceCleanupError.artifactUnreadable(
                fileName: url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        guard file.length > 0,
              abs(file.fileFormat.sampleRate - 16_000) < 0.5,
              file.fileFormat.channelCount == 1,
              file.length == expected.totalFrames else {
            throw AudioSourceCleanupError.artifactUnreadable(
                fileName: url.lastPathComponent,
                reason: "Audio metadata does not match the finalized track."
            )
        }
    }
}

enum AudioSourceCleanupError: Error, LocalizedError {
    case exportMissing
    case trackWasNotTranscribed(fileName: String)
    case artifactMissing(fileName: String)
    case artifactUnreadable(fileName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .exportMissing:
            return "The completed Markdown export could not be verified."
        case let .trackWasNotTranscribed(fileName):
            return "Source audio \(fileName) was preserved because its transcription is incomplete."
        case let .artifactMissing(fileName):
            return "Source audio was preserved because \(fileName) is missing or empty."
        case let .artifactUnreadable(fileName, reason):
            return "Source audio was preserved because \(fileName) is unreadable: \(reason)"
        }
    }
}
