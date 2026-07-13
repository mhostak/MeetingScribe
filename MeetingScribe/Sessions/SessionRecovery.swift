import AVFoundation
import Foundation

enum SessionRecoveryReason: String, Codable, Equatable, Sendable {
    case interruptedRecording
    case failedProcessing
    case incompleteProcessing

    var displayName: String {
        switch self {
        case .interruptedRecording:
            return "Recording was interrupted before it could be finalized."
        case .failedProcessing:
            return "The previous processing attempt failed."
        case .incompleteProcessing:
            return "Processing did not produce a completed Markdown output."
        }
    }
}

struct SessionRecoveryArtifacts: Codable, Equatable, Sendable {
    let hasSystemAudio: Bool
    let hasMicrophoneAudio: Bool
    let hasWorkingSystemAudio: Bool
    let hasMergedTranscript: Bool
    let hasAnalysis: Bool

    var hasRecoverableInput: Bool {
        hasSystemAudio || hasWorkingSystemAudio || hasMergedTranscript
    }
}

struct SessionRecoveryCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let session: RecordingSession
    let reason: SessionRecoveryReason
    let artifacts: SessionRecoveryArtifacts
    let suggestedEndAt: Date
}

struct SessionRecoveryIssue: Equatable, Sendable {
    let directoryName: String
    let reason: String
}

struct SessionRecoveryScanResult: Equatable, Sendable {
    let candidates: [SessionRecoveryCandidate]
    let issues: [SessionRecoveryIssue]
}

struct SessionRecoveryScanner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func scan(recordingsRoot: URL, now: Date = Date()) -> SessionRecoveryScanResult {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SessionRecoveryScanResult(candidates: [], issues: [])
        }

        var candidates: [SessionRecoveryCandidate] = []
        var issues: [SessionRecoveryIssue] = []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("session.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                issues.append(
                    SessionRecoveryIssue(
                        directoryName: directory.lastPathComponent,
                        reason: "Session manifest is missing. Existing files were left untouched."
                    )
                )
                continue
            }

            let metadata: SessionMetadata
            do {
                metadata = try SessionJSONCoder.makeDecoder().decode(
                    SessionMetadata.self,
                    from: Data(contentsOf: manifestURL)
                )
            } catch {
                issues.append(
                    SessionRecoveryIssue(
                        directoryName: directory.lastPathComponent,
                        reason: "Session manifest is unreadable. Existing files were left untouched."
                    )
                )
                continue
            }

            let session = RecordingSession(metadata: metadata, directoryURL: directory)
            guard let reason = recoveryReason(for: metadata) else { continue }
            let artifacts = artifacts(for: session)
            guard artifacts.hasRecoverableInput else {
                if metadata.status == .failed {
                    continue
                }
                issues.append(
                    SessionRecoveryIssue(
                        directoryName: directory.lastPathComponent,
                        reason: "No recoverable audio or transcript artifact was found."
                    )
                )
                continue
            }
            candidates.append(
                SessionRecoveryCandidate(
                    id: metadata.id,
                    session: session,
                    reason: reason,
                    artifacts: artifacts,
                    suggestedEndAt: suggestedEndAt(for: session, fallback: now)
                )
            )
        }

        return SessionRecoveryScanResult(
            candidates: candidates.sorted {
                ($0.session.metadata.startedAt ?? $0.session.metadata.createdAt)
                    > ($1.session.metadata.startedAt ?? $1.session.metadata.createdAt)
            },
            issues: issues.sorted { $0.directoryName < $1.directoryName }
        )
    }

    func isRecoverable(_ metadata: SessionMetadata) -> Bool {
        recoveryReason(for: metadata) != nil
    }

    private func recoveryReason(for metadata: SessionMetadata) -> SessionRecoveryReason? {
        if metadata.recovery?.status == .closed || metadata.recovery?.status == .completed {
            return nil
        }
        switch metadata.status {
        case .recording:
            return .interruptedRecording
        case .failed:
            return .failedProcessing
        case .recorded:
            if metadata.transcription?.status == .failed
                || metadata.transcription?.status == .modelMissing {
                return .failedProcessing
            }
            if metadata.output?.status == .failed
                || (metadata.transcription?.status == .completed && metadata.output == nil) {
                return .incompleteProcessing
            }
            return nil
        }
    }

    private func artifacts(for session: RecordingSession) -> SessionRecoveryArtifacts {
        SessionRecoveryArtifacts(
            hasSystemAudio: hasNonemptyFile(session.systemAudioURL),
            hasMicrophoneAudio: hasNonemptyFile(session.microphoneAudioURL),
            hasWorkingSystemAudio: hasNonemptyFile(session.systemWorkingAudioURL),
            hasMergedTranscript: hasNonemptyFile(session.mergedTranscriptURL),
            hasAnalysis: hasNonemptyFile(session.analysisURL)
        )
    }

    private func hasNonemptyFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private func suggestedEndAt(for session: RecordingSession, fallback: Date) -> Date {
        if let endedAt = session.metadata.endedAt { return endedAt }
        let urls = [
            session.systemAudioURL,
            session.microphoneAudioURL,
            session.systemWorkingAudioURL,
            session.mergedTranscriptURL,
        ]
        let modificationDates = urls.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return modificationDates.compactMap { $0 }.max()
            ?? session.metadata.startedAt
            ?? fallback
    }
}

struct RecoveredAudioInspector {
    private let fileManager: FileManager
    private let repairer: PCMRecordingFileRepairer

    init(
        fileManager: FileManager = .default,
        repairer: PCMRecordingFileRepairer = PCMRecordingFileRepairer()
    ) {
        self.fileManager = fileManager
        self.repairer = repairer
    }

    func inspect(session: RecordingSession, now: Date = Date()) throws -> CaptureSessionDiagnostics {
        var system = try inspectTrack(
            url: session.systemAudioURL,
            required: true,
            now: now
        )
        var microphone: AudioCaptureDiagnostics
        if fileManager.fileExists(atPath: session.microphoneAudioURL.path) {
            microphone = (try? inspectTrack(
                url: session.microphoneAudioURL,
                required: false,
                now: now
            )) ?? failedOptionalTrack(
                fileName: session.microphoneAudioURL.lastPathComponent,
                reason: "The recovered microphone file is unreadable."
            )
        } else {
            microphone = failedOptionalTrack(
                fileName: session.microphoneAudioURL.lastPathComponent,
                reason: "No recovered microphone file was found."
            )
        }
        alignRecoveredTimeline(
            system: &system,
            microphone: &microphone,
            persistedSystem: session.metadata.systemAudio,
            persistedMicrophone: session.metadata.microphoneAudio
        )
        return CaptureSessionDiagnostics(systemAudio: system, microphone: microphone)
    }

    private func inspectTrack(
        url: URL,
        required: Bool,
        now: Date
    ) throws -> AudioCaptureDiagnostics {
        guard fileManager.fileExists(atPath: url.path) else {
            if required { throw SessionRecoveryError.requiredSystemAudioMissing }
            return failedOptionalTrack(fileName: url.lastPathComponent, reason: "Audio file is missing.")
        }
        do {
            try repairer.repairIfNeeded(at: url)
        } catch {
            throw SessionRecoveryError.audioUnreadable(
                fileName: url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SessionRecoveryError.audioUnreadable(
                fileName: url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, format.channelCount > 0 else {
            throw SessionRecoveryError.audioEmpty(fileName: url.lastPathComponent)
        }
        let duration = Double(file.length) / format.sampleRate
        let modificationDate = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? now
        return AudioCaptureDiagnostics(
            fileName: url.lastPathComponent,
            startedAt: modificationDate.addingTimeInterval(-duration),
            lastBufferReceivedAt: now,
            bufferCount: 1,
            totalFrames: file.length,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            firstPresentationTimestamp: 0,
            lastPresentationTimestamp: 0,
            lastBufferDurationSeconds: duration,
            failureReason: nil
        )
    }

    private func alignRecoveredTimeline(
        system: inout AudioCaptureDiagnostics,
        microphone: inout AudioCaptureDiagnostics,
        persistedSystem: AudioTrackMetadata?,
        persistedMicrophone: AudioTrackMetadata?
    ) {
        if
            microphone.failureReason == nil,
            let systemStart = persistedSystem?.firstPresentationTimestamp,
            let microphoneStart = persistedMicrophone?.firstPresentationTimestamp
        {
            let origin = min(systemStart, microphoneStart)
            let systemOffset = max(0, systemStart - origin)
            let microphoneOffset = max(0, microphoneStart - origin)
            system.firstPresentationTimestamp = systemOffset
            system.lastPresentationTimestamp = systemOffset
            microphone.firstPresentationTimestamp = microphoneOffset
            microphone.lastPresentationTimestamp = microphoneOffset
            return
        }

        system.firstPresentationTimestamp = 0
        system.lastPresentationTimestamp = 0

        guard
            microphone.failureReason == nil,
            let systemStartedAt = system.startedAt,
            let microphoneStartedAt = microphone.startedAt
        else {
            return
        }

        // When capture stopped safely, the manifest timestamps above are more
        // precise than filesystem modification dates. A hard crash can leave
        // those fields absent, so infer the relative microphone start from each
        // track's final write time and duration. Clamping protects against
        // filesystem timestamp granularity making the microphone appear to
        // start slightly earlier.
        let microphoneOffset = max(
            0,
            microphoneStartedAt.timeIntervalSince(systemStartedAt)
        )
        microphone.firstPresentationTimestamp = microphoneOffset
        microphone.lastPresentationTimestamp = microphoneOffset
    }

    private func failedOptionalTrack(fileName: String, reason: String) -> AudioCaptureDiagnostics {
        var diagnostics = AudioCaptureDiagnostics.empty
        diagnostics.fileName = fileName
        diagnostics.failureReason = reason
        return diagnostics
    }
}

enum SessionRecoveryError: Error, Equatable, LocalizedError {
    case candidateNotFound
    case sessionNotRecoverable
    case requiredSystemAudioMissing
    case audioUnreadable(fileName: String, reason: String)
    case audioEmpty(fileName: String)
    case mergedTranscriptUnreadable
    case pendingRecoveryMustBeResolved

    var errorDescription: String? {
        switch self {
        case .candidateNotFound:
            return "The recovery candidate no longer exists."
        case .sessionNotRecoverable:
            return "This session is no longer eligible for recovery."
        case .requiredSystemAudioMissing:
            return "The interrupted session has no recoverable system-audio file. Existing artifacts were preserved."
        case let .audioUnreadable(fileName, reason):
            return "Recovered audio \(fileName) is unreadable: \(reason). Existing artifacts were preserved."
        case let .audioEmpty(fileName):
            return "Recovered audio \(fileName) is empty. Existing artifacts were preserved."
        case .mergedTranscriptUnreadable:
            return "The recovered merged transcript is unreadable. Existing artifacts were preserved."
        case .pendingRecoveryMustBeResolved:
            return "Recover or close the unfinished recording before starting a new one."
        }
    }
}
