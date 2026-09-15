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
/// Online/hybrid sessions require system audio and accept an optional microphone
/// track. Offline sessions require only the microphone. No silence is inserted
/// into the WAV files; relative offsets are applied to transcript timestamps.
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
        if session.metadata.resolvedCaptureMode == .microphoneOnly {
            return try finalizeMicrophoneOnly(
                session: session,
                diagnostics: diagnostics.microphone
            )
        }

        let systemDiagnostics = diagnostics.systemAudio
        let requiredTrackWarning = try validateRequiredTrack(
            systemDiagnostics,
            name: "System audio"
        )

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

        var warnings = requiredTrackWarning.map { [$0] } ?? []
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
        } else if microphoneDiagnostics.bufferCount > 0 {
            warnings.append(
                "Microphone track was preserved but skipped because its capture start timestamp was unavailable."
            )
        } else if let failureReason = microphoneDiagnostics.failureReason {
            warnings.append("Microphone capture was unavailable: \(failureReason)")
        } else {
            warnings.append("Microphone track contained no audio buffers.")
        }
        if microphoneDiagnostics.droppedBufferCount > 0 {
            warnings.append(
                "Microphone capture dropped \(microphoneDiagnostics.droppedBufferCount) audio buffers because its writer queue was saturated."
            )
        }

        return AudioFinalizationMetadata(
            completedAt: now(),
            timelineOrigin: timelineOrigin,
            system: system,
            microphone: microphone,
            warnings: warnings
        )
    }

    private func finalizeMicrophoneOnly(
        session: RecordingSession,
        diagnostics: AudioCaptureDiagnostics
    ) throws -> AudioFinalizationMetadata {
        let requiredTrackWarning = try validateRequiredTrack(
            diagnostics,
            name: "Microphone"
        )
        guard let microphoneStart = diagnostics.firstPresentationTimestamp else {
            throw AudioFinalizerError.missingTimeline(trackName: "Microphone")
        }

        let microphone = try finalizeTrack(
            inputURL: session.microphoneAudioURL,
            outputURL: session.microphoneWorkingAudioURL,
            startedAt: microphoneStart,
            timelineOrigin: microphoneStart
        )
        var warnings = requiredTrackWarning.map { [$0] } ?? []
        if diagnostics.droppedBufferCount > 0 {
            warnings.append(
                "Microphone capture dropped \(diagnostics.droppedBufferCount) audio buffers because its writer queue was saturated."
            )
        }
        return AudioFinalizationMetadata(
            completedAt: now(),
            timelineOrigin: microphoneStart,
            system: nil,
            microphone: microphone,
            warnings: warnings
        )
    }

    private func validateRequiredTrack(
        _ diagnostics: AudioCaptureDiagnostics,
        name: String
    ) throws -> String? {
        guard diagnostics.bufferCount > 0, diagnostics.totalFrames > 0 else {
            if let failureReason = diagnostics.failureReason {
                throw AudioFinalizerError.requiredTrackFailed(
                    trackName: name,
                    reason: failureReason
                )
            }
            throw AudioFinalizerError.emptyRequiredTrack(trackName: name)
        }
        return diagnostics.failureReason.map {
            "\(name) capture ended early: \($0)"
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
            guard let system = finalization.system,
                  session.metadata.transcription?.systemSegmentCount != nil else {
                throw AudioSourceCleanupError.trackWasNotTranscribed(
                    fileName: session.systemAudioURL.lastPathComponent
                )
            }
            candidates.append(Candidate(
                sourceURL: session.systemAudioURL,
                finalized: system,
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

struct RecordingAudioCleanupFile: Equatable, Sendable {
    let relativePath: String
    let allocatedBytes: Int64
}

struct RecordingAudioCleanupCandidate: Equatable, Identifiable, Sendable {
    let session: RecordingSession
    let files: [RecordingAudioCleanupFile]

    var id: String { session.metadata.id }
    var allocatedBytes: Int64 { files.reduce(0) { $0 + $1.allocatedBytes } }
}

struct RecordingAudioCleanupPlan: Equatable, Sendable {
    let generatedAt: Date
    let totalAudioBytes: Int64
    let reclaimableBytes: Int64
    let candidates: [RecordingAudioCleanupCandidate]
    let keptSessionCount: Int
    let ineligibleSessionCount: Int

    static let empty = RecordingAudioCleanupPlan(
        generatedAt: .distantPast,
        totalAudioBytes: 0,
        reclaimableBytes: 0,
        candidates: [],
        keptSessionCount: 0,
        ineligibleSessionCount: 0
    )
}

struct RecordingAudioCleanupReport: Equatable, Sendable {
    let cleanedSessionIDs: [String]
    let deletedFileCount: Int
    let reclaimedBytes: Int64
    let failures: [String]
}

enum RecordingAudioCleanupError: Error, LocalizedError {
    case invalidAudioPath(String)
    case sessionNotEligible(String)
    case audioAlreadyPurged(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAudioPath(path):
            return "The audio path is outside its recording folder: \(path)"
        case let .sessionNotEligible(id):
            return "Recording \(id) is no longer eligible for audio cleanup."
        case let .audioAlreadyPurged(id):
            return "Recording \(id) no longer has audio that can be retained."
        }
    }
}

/// Scans and permanently removes recording audio only after durable transcript
/// and Markdown artifacts have been verified. The actor serializes manual and
/// automatic cleanup so the same session cannot be purged concurrently.
actor RecordingAudioCleanupService {
    private let recordingsRoot: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        recordingsRoot: URL = SessionManager.defaultRecordingsRoot,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recordingsRoot = recordingsRoot
        self.fileManager = fileManager
        self.now = now
    }

    func scan(olderThan cutoff: Date? = nil) throws -> RecordingAudioCleanupPlan {
        let generatedAt = now()
        var totalAudioBytes: Int64 = 0
        var candidates: [RecordingAudioCleanupCandidate] = []
        var keptSessionCount = 0
        var ineligibleSessionCount = 0

        for var session in try loadSessions() {
            session = try reconcileInterruptedCleanup(session)
            let files: [RecordingAudioCleanupFile]
            do {
                files = try existingAudioFiles(in: session)
            } catch {
                ineligibleSessionCount += 1
                continue
            }
            totalAudioBytes += files.reduce(0) { $0 + $1.allocatedBytes }
            guard !files.isEmpty, !session.metadata.isRecordingAudioPurged else { continue }
            if session.metadata.keepsRecordingAudio {
                keptSessionCount += 1
                continue
            }
            guard isEligible(session, olderThan: cutoff) else {
                ineligibleSessionCount += 1
                continue
            }
            candidates.append(RecordingAudioCleanupCandidate(session: session, files: files))
        }

        return RecordingAudioCleanupPlan(
            generatedAt: generatedAt,
            totalAudioBytes: totalAudioBytes,
            reclaimableBytes: candidates.reduce(0) { $0 + $1.allocatedBytes },
            candidates: candidates.sorted {
                ($0.session.metadata.endedAt ?? $0.session.metadata.createdAt)
                    < ($1.session.metadata.endedAt ?? $1.session.metadata.createdAt)
            },
            keptSessionCount: keptSessionCount,
            ineligibleSessionCount: ineligibleSessionCount
        )
    }

    func execute(
        _ plan: RecordingAudioCleanupPlan,
        trigger: RecordingAudioCleanupTrigger
    ) throws -> RecordingAudioCleanupReport {
        var cleanedSessionIDs: [String] = []
        var deletedFileCount = 0
        var reclaimedBytes: Int64 = 0
        var failures: [String] = []

        for planned in plan.candidates {
            do {
                var session = try loadSession(at: planned.session.directoryURL)
                guard !session.metadata.keepsRecordingAudio,
                      !session.metadata.isRecordingAudioPurged,
                      isEligible(session, olderThan: nil) else {
                    throw RecordingAudioCleanupError.sessionNotEligible(session.metadata.id)
                }
                let files = try existingAudioFiles(in: session)
                guard !files.isEmpty else {
                    throw RecordingAudioCleanupError.sessionNotEligible(session.metadata.id)
                }

                let startedAt = now()
                session.metadata.recordingAudioRetention = RecordingAudioRetentionMetadata(
                    keepAudio: false,
                    cleanupStatus: .inProgress,
                    cleanupTrigger: trigger,
                    cleanupStartedAt: startedAt,
                    candidateFiles: files.map(\.relativePath),
                    reclaimedBytes: files.reduce(0) { $0 + $1.allocatedBytes }
                )
                try persist(session)

                var deleted: [String] = []
                var deletedBytes: Int64 = 0
                do {
                    for file in files {
                        let url = try validatedAudioURL(
                            relativePath: file.relativePath,
                            sessionDirectory: session.directoryURL
                        )
                        guard fileManager.fileExists(atPath: url.path) else { continue }
                        try fileManager.removeItem(at: url)
                        deleted.append(file.relativePath)
                        deletedBytes += file.allocatedBytes
                    }
                    session.metadata.recordingAudioRetention = RecordingAudioRetentionMetadata(
                        keepAudio: false,
                        cleanupStatus: .purged,
                        cleanupTrigger: trigger,
                        cleanupStartedAt: startedAt,
                        cleanupCompletedAt: now(),
                        candidateFiles: files.map(\.relativePath),
                        deletedFiles: deleted,
                        reclaimedBytes: deletedBytes
                    )
                    try persist(session)
                    cleanedSessionIDs.append(session.metadata.id)
                    deletedFileCount += deleted.count
                    reclaimedBytes += deletedBytes
                } catch {
                    session.metadata.recordingAudioRetention = RecordingAudioRetentionMetadata(
                        keepAudio: false,
                        cleanupStatus: .failed,
                        cleanupTrigger: trigger,
                        cleanupStartedAt: startedAt,
                        cleanupCompletedAt: now(),
                        candidateFiles: files.map(\.relativePath),
                        deletedFiles: deleted,
                        reclaimedBytes: deletedBytes,
                        failureReason: error.localizedDescription
                    )
                    try? persist(session)
                    throw error
                }
            } catch {
                failures.append("\(planned.session.metadata.title): \(error.localizedDescription)")
            }
        }

        return RecordingAudioCleanupReport(
            cleanedSessionIDs: cleanedSessionIDs,
            deletedFileCount: deletedFileCount,
            reclaimedBytes: reclaimedBytes,
            failures: failures
        )
    }

    func setKeepAudio(_ keepAudio: Bool, sessionID: String) throws -> RecordingSession {
        guard let directory = try sessionDirectories().first(where: {
            $0.lastPathComponent == sessionID
        }) else {
            throw RecordingAudioCleanupError.sessionNotEligible(sessionID)
        }
        var session = try loadSession(at: directory)
        guard !session.metadata.isRecordingAudioPurged else {
            throw RecordingAudioCleanupError.audioAlreadyPurged(sessionID)
        }
        var retention = session.metadata.recordingAudioRetention
            ?? RecordingAudioRetentionMetadata()
        retention.keepAudio = keepAudio
        retention.failureReason = nil
        session.metadata.recordingAudioRetention = retention
        try persist(session)
        return session
    }

    private func loadSessions() throws -> [RecordingSession] {
        try sessionDirectories().compactMap { try? loadSession(at: $0) }
    }

    private func sessionDirectories() throws -> [URL] {
        guard fileManager.fileExists(atPath: recordingsRoot.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func loadSession(at directory: URL) throws -> RecordingSession {
        let manifestURL = directory.appendingPathComponent("session.json", isDirectory: false)
        let metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: Data(contentsOf: manifestURL)
        )
        return RecordingSession(metadata: metadata, directoryURL: directory)
    }

    private func persist(_ session: RecordingSession) throws {
        let data = try SessionJSONCoder.makeEncoder().encode(session.metadata)
        try data.write(to: session.manifestURL, options: .atomic)
    }

    private func reconcileInterruptedCleanup(
        _ original: RecordingSession
    ) throws -> RecordingSession {
        guard original.metadata.recordingAudioRetention?.cleanupStatus == .inProgress,
              let retention = original.metadata.recordingAudioRetention else {
            return original
        }
        let hasRemainingFile = try retention.candidateFiles.contains { path in
            let url = try validatedAudioURL(
                relativePath: path,
                sessionDirectory: original.directoryURL
            )
            return fileManager.fileExists(atPath: url.path)
        }
        guard !hasRemainingFile else { return original }

        var session = original
        session.metadata.recordingAudioRetention = RecordingAudioRetentionMetadata(
            keepAudio: false,
            cleanupStatus: .purged,
            cleanupTrigger: retention.cleanupTrigger,
            cleanupStartedAt: retention.cleanupStartedAt,
            cleanupCompletedAt: now(),
            candidateFiles: retention.candidateFiles,
            deletedFiles: retention.candidateFiles,
            reclaimedBytes: retention.reclaimedBytes
        )
        try persist(session)
        return session
    }

    private func isEligible(_ session: RecordingSession, olderThan cutoff: Date?) -> Bool {
        guard session.metadata.status == .recorded,
              session.metadata.transcription?.status == .completed,
              session.metadata.output?.status == .completed,
              session.metadata.recovery?.status != .inProgress,
              validateMergedTranscript(session),
              validateMarkdown(session.metadata.output) else {
            return false
        }
        guard let cutoff else { return true }
        let completedAt = session.metadata.output?.exportedAt
            ?? session.metadata.endedAt
            ?? session.metadata.createdAt
        return completedAt <= cutoff
    }

    private func validateMergedTranscript(_ session: RecordingSession) -> Bool {
        guard let data = try? Data(contentsOf: session.mergedTranscriptURL), !data.isEmpty else {
            return false
        }
        return (try? TranscriptJSONCoder.makeDecoder().decode(
            MergedTranscript.self,
            from: data
        )) != nil
    }

    private func validateMarkdown(_ output: SessionOutputMetadata?) -> Bool {
        guard let path = output?.markdownPath, !path.isEmpty,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private func existingAudioFiles(
        in session: RecordingSession
    ) throws -> [RecordingAudioCleanupFile] {
        var names = [
            session.metadata.audioFiles.system,
            session.metadata.audioFiles.microphone,
            session.metadata.audioFiles.mixed,
            session.metadata.audioFiles.systemWorking,
            session.metadata.audioFiles.microphoneWorking,
            session.metadata.systemAudio?.fileName,
            session.metadata.microphoneAudio?.fileName,
            session.metadata.audioFinalization?.system?.fileName,
            session.metadata.audioFinalization?.microphone?.fileName,
        ].compactMap { $0 }
        names = Array(Set(names)).sorted()

        return try names.compactMap { name in
            let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard fileExtension == "wav" || fileExtension == "caf" else { return nil }
            let url = try validatedAudioURL(
                relativePath: name,
                sessionDirectory: session.directoryURL
            )
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RecordingAudioCleanupError.invalidAudioPath(name)
            }
            let bytes = Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
            return RecordingAudioCleanupFile(relativePath: name, allocatedBytes: bytes)
        }
    }

    private func validatedAudioURL(
        relativePath: String,
        sessionDirectory: URL
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              URL(fileURLWithPath: relativePath).lastPathComponent == relativePath else {
            throw RecordingAudioCleanupError.invalidAudioPath(relativePath)
        }
        let root = sessionDirectory.standardizedFileURL
        let url = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        if fileManager.fileExists(atPath: url.path),
           (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RecordingAudioCleanupError.invalidAudioPath(relativePath)
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedURL = url.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolvedURL.path.hasPrefix(prefix) else {
            throw RecordingAudioCleanupError.invalidAudioPath(relativePath)
        }
        return resolvedURL
    }
}
