import AVFoundation
import Foundation
import XCTest
@testable import MeetingScribe

final class SessionRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testDetectionPersistsOnceAcrossScansAndManagerInstances() async throws {
        let session = try makeSession(id: "detected", status: .recording)
        try Data("audio".utf8).write(to: session.systemAudioURL)
        let manager = SessionManager(recordingsRoot: root)
        let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = try await manager.scanForRecovery()
        XCTAssertEqual(initial.candidates.map(\.id), [session.metadata.id])
        let recorded = try await manager.recordRecoveryDetection(id: session.metadata.id, now: detectedAt)
        XCTAssertTrue(recorded)
        let persistedData = try Data(contentsOf: session.manifestURL)
        let persisted = try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: persistedData)
        XCTAssertNil(persisted.recovery)
        XCTAssertEqual(persisted.recoveryDetectedAt, detectedAt)
        XCTAssertEqual(persisted.status, session.metadata.status)

        let restarted = SessionManager(recordingsRoot: root)
        let rescanned = try await restarted.scanForRecovery()
        XCTAssertEqual(rescanned.candidates.map(\.id), [session.metadata.id])
        XCTAssertEqual(rescanned.candidates.first?.reason, initial.candidates.first?.reason)
        let repeated = try await restarted.recordRecoveryDetection(
            id: session.metadata.id, now: detectedAt.addingTimeInterval(60)
        )
        XCTAssertFalse(repeated)
        XCTAssertEqual(try Data(contentsOf: session.manifestURL), persistedData)
    }

    func testFailedRecoveryStartsAnotherDetectionEpisodeWithoutChangingAttemptHistory() async throws {
        let session = try makeSession(id: "redetected", status: .recording)
        try Data("audio".utf8).write(to: session.systemAudioURL)
        let manager = SessionManager(recordingsRoot: root)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await manager.recordRecoveryDetection(id: session.metadata.id, now: firstDate)
        let active = try await manager.beginRecovery(id: session.metadata.id, now: firstDate.addingTimeInterval(10))
        XCTAssertEqual(active.metadata.recovery?.attemptCount, 1)
        XCTAssertEqual(active.metadata.recovery?.detectedAt, firstDate)
        let failed = try await manager.failSession(reason: "Recovery failed", now: firstDate.addingTimeInterval(20))
        let secondDate = firstDate.addingTimeInterval(60)
        let recorded = try await manager.recordRecoveryDetection(id: session.metadata.id, now: secondDate)
        XCTAssertTrue(recorded)
        let repeated = try await manager.recordRecoveryDetection(id: session.metadata.id)
        XCTAssertFalse(repeated)
        let candidate = try await manager.recoveryCandidate(id: session.metadata.id)
        let recovery = try XCTUnwrap(candidate?.session.metadata.recovery)
        XCTAssertEqual(recovery.status, .failed)
        XCTAssertEqual(recovery.originalStatus, .recording)
        XCTAssertEqual(recovery.attemptCount, 1)
        XCTAssertEqual(recovery, failed.metadata.recovery)
        XCTAssertEqual(candidate?.session.metadata.recoveryDetectedAt, secondDate)
        XCTAssertEqual(recovery.startedAt, failed.metadata.recovery?.startedAt)
        XCTAssertEqual(recovery.completedAt, failed.metadata.recovery?.completedAt)
        XCTAssertEqual(recovery.failureReason, "Recovery failed")
        let retried = try await manager.beginRecovery(id: session.metadata.id)
        XCTAssertEqual(retried.metadata.recovery?.originalStatus, .recording)
        XCTAssertEqual(retried.metadata.recovery?.attemptCount, 2)
        _ = try await manager.failSession(reason: "Cleanup")
        _ = try await manager.recordRecoveryDetection(id: session.metadata.id)
        let closed = try await manager.closeRecovery(id: session.metadata.id)
        XCTAssertEqual(closed.metadata.recovery?.originalStatus, .recording)
        XCTAssertEqual(closed.metadata.recovery?.attemptCount, 2)
    }

    func testOnlyAFailedAttemptAfterDetectionStartsAnotherEpisode() async throws {
        let detectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(String, SessionRecoveryStatus, Date?, Bool)] = [
            ("earlier", .failed, detectedAt.addingTimeInterval(-1), false),
            ("equal", .failed, detectedAt, false),
            ("later", .failed, detectedAt.addingTimeInterval(1), true),
            ("missing", .failed, nil, false),
            ("in-progress", .inProgress, detectedAt.addingTimeInterval(1), false)
        ]
        let manager = SessionManager(recordingsRoot: root)
        for (id, status, completedAt, expected) in cases {
            let session = try makeSession(metadata: SessionMetadata(
                id: id, title: id, status: .failed, createdAt: detectedAt,
                recovery: SessionRecoveryMetadata(
                    status: status, originalStatus: .recording, detectedAt: detectedAt,
                    startedAt: nil, completedAt: completedAt, attemptCount: 1, failureReason: nil
                ),
                recoveryDetectedAt: detectedAt
            ))
            try Data("audio".utf8).write(to: session.systemAudioURL)
            let now = detectedAt.addingTimeInterval(60)
            let recorded = try await manager.recordRecoveryDetection(id: id, now: now)
            XCTAssertEqual(recorded, expected, id)
            let persisted = try SessionJSONCoder.makeDecoder().decode(
                SessionMetadata.self, from: Data(contentsOf: session.manifestURL)
            )
            XCTAssertEqual(persisted.recovery, session.metadata.recovery, id)
            XCTAssertEqual(persisted.recoveryDetectedAt, expected ? now : detectedAt, id)
            let repeated = try await manager.recordRecoveryDetection(id: id, now: now.addingTimeInterval(60))
            XCTAssertFalse(repeated, id)
        }
    }

    func testTerminalRecoveryStatusesSuppressOtherwiseRecoverableSessions() async throws {
        let manager = SessionManager(recordingsRoot: root)
        for status in [SessionRecoveryStatus.closed, .completed] {
            let session = try makeSession(metadata: SessionMetadata(
                id: status.rawValue, title: status.rawValue, status: .recording, createdAt: Date(),
                recovery: SessionRecoveryMetadata(
                    status: status, originalStatus: .recording, detectedAt: Date(),
                    startedAt: nil, completedAt: Date(), attemptCount: 1, failureReason: nil
                )
            ))
            try Data("audio".utf8).write(to: session.systemAudioURL)
            let original = try Data(contentsOf: session.manifestURL)
            let scan = try await manager.scanForRecovery()
            XCTAssertTrue(scan.candidates.isEmpty)
            let recorded = try await manager.recordRecoveryDetection(id: session.metadata.id)
            XCTAssertFalse(recorded)
            XCTAssertEqual(try Data(contentsOf: session.manifestURL), original)
        }
    }

    func testDetectionEncodingRemainsReadableByLegacyRecoveryDecoder() throws {
        var metadata = SessionMetadata(id: "compatibility", title: "Compatibility", status: .recording, createdAt: Date())
        let legacyData = try SessionJSONCoder.makeEncoder().encode(metadata)
        let withoutDetection = try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: legacyData)
        XCTAssertNil(withoutDetection.recovery)
        XCTAssertNil(withoutDetection.recoveryDetectedAt)

        metadata.recoveryDetectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try SessionJSONCoder.makeEncoder().encode(metadata)
        let legacy = try SessionJSONCoder.makeDecoder().decode(LegacyRecoveryManifest.self, from: data)
        XCTAssertEqual(legacy.schemaVersion, 16)
        XCTAssertNil(legacy.recovery)
        let decoded = try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: data)
        XCTAssertNil(decoded.recovery)
        XCTAssertEqual(decoded.recoveryDetectedAt, metadata.recoveryDetectedAt)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["recovery"])
        XCTAssertNotNil(object["recoveryDetectedAt"])

        for status in [SessionRecoveryStatus.inProgress, .failed, .closed, .completed] {
            metadata.recovery = SessionRecoveryMetadata(
                status: status, originalStatus: .recording,
                detectedAt: Date(timeIntervalSince1970: 1_700_000_000),
                startedAt: nil, completedAt: nil, attemptCount: 1, failureReason: nil
            )
            let existing = try SessionJSONCoder.makeEncoder().encode(metadata)
            let roundTrip = try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: existing)
            XCTAssertEqual(roundTrip.recovery, metadata.recovery)
            let legacy = try SessionJSONCoder.makeDecoder().decode(LegacyRecoveryManifest.self, from: existing)
            XCTAssertEqual(legacy.recovery?.status.rawValue, status.rawValue)
        }
    }

    func testScannerFindsInterruptedAndFailedSessionsButNotCompletedSession() throws {
        let interrupted = try makeSession(id: "interrupted", status: .recording)
        try Data("audio".utf8).write(to: interrupted.systemAudioURL)

        var failedMetadata = SessionMetadata(
            id: "failed",
            title: "Failed transcription",
            status: .recorded,
            createdAt: Date(),
            transcription: SessionTranscriptionMetadata(
                status: .modelMissing,
                model: "missing.bin",
                systemSegmentCount: nil,
                microphoneSegmentCount: nil,
                warnings: [],
                failureReason: "Missing model"
            )
        )
        let failed = try makeSession(metadata: failedMetadata)
        try Data("audio".utf8).write(to: failed.systemAudioURL)

        failedMetadata = SessionMetadata(
            id: "completed",
            title: "Completed",
            status: .recorded,
            createdAt: Date(),
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "model.bin",
                systemSegmentCount: 1,
                microphoneSegmentCount: 0,
                mergedSegmentCount: 1,
                warnings: [],
                failureReason: nil
            ),
            output: SessionOutputMetadata(
                status: .completed,
                markdownFileName: "done.md",
                markdownPath: "/tmp/done.md",
                exportedAt: Date(),
                failureReason: nil
            )
        )
        _ = try makeSession(metadata: failedMetadata)

        _ = try makeSession(
            metadata: SessionMetadata(
                id: "permission-denied",
                title: "No artifacts",
                status: .failed,
                createdAt: Date(),
                failureReason: "Permission denied"
            )
        )

        let corrupt = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corrupt.appendingPathComponent("session.json"))

        let result = SessionRecoveryScanner().scan(recordingsRoot: root)

        XCTAssertEqual(Set(result.candidates.map(\.id)), ["interrupted", "failed"])
        XCTAssertEqual(
            result.candidates.first(where: { $0.id == "interrupted" })?.reason,
            .interruptedRecording
        )
        XCTAssertEqual(
            result.candidates.first(where: { $0.id == "failed" })?.reason,
            .failedProcessing
        )
        XCTAssertEqual(result.issues.map(\.directoryName), ["corrupt"])
    }

    func testBeginAndCompleteRecoveryPersistsAuditMetadata() async throws {
        let original = try makeSession(id: "recover-me", status: .recording)
        try Data("audio".utf8).write(to: original.systemAudioURL)
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: RecoveryCapacityProvider(), minimumBytes: 1)
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)

        _ = try await manager.recordRecoveryDetection(id: "recover-me", now: startedAt.addingTimeInterval(-10))
        let active = try await manager.beginRecovery(id: "recover-me", now: startedAt)

        XCTAssertEqual(active.metadata.recovery?.status, .inProgress)
        XCTAssertEqual(active.metadata.recovery?.originalStatus, .recording)
        XCTAssertEqual(active.metadata.recovery?.detectedAt, startedAt.addingTimeInterval(-10))
        XCTAssertEqual(active.metadata.recovery?.attemptCount, 1)
        let completed = try await manager.stopSession(
            now: startedAt.addingTimeInterval(10),
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "model.bin",
                systemSegmentCount: 1,
                microphoneSegmentCount: 0,
                mergedSegmentCount: 1,
                warnings: [],
                failureReason: nil
            ),
            output: SessionOutputMetadata(
                status: .completed,
                markdownFileName: "recovered.md",
                markdownPath: "/tmp/recovered.md",
                exportedAt: startedAt,
                failureReason: nil
            )
        )
        XCTAssertEqual(completed.metadata.status, .recorded)
        XCTAssertEqual(completed.metadata.recovery?.status, .completed)
        let detectedAgain = try await manager.recordRecoveryDetection(id: "recover-me")
        XCTAssertFalse(detectedAgain)
        XCTAssertNotNil(completed.metadata.recovery?.completedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.systemAudioURL.path))
        let remainingCandidates = try await manager.scanForRecovery().candidates
        XCTAssertTrue(remainingCandidates.isEmpty)
    }

    func testCloseRecoveryPreservesArtifactsAndRemovesCandidate() async throws {
        let session = try makeSession(id: "close-me", status: .recording)
        let audio = Data("preserve-me".utf8)
        try audio.write(to: session.systemAudioURL)
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: RecoveryCapacityProvider(), minimumBytes: 1)
        )

        _ = try await manager.recordRecoveryDetection(id: "close-me")
        let closed = try await manager.closeRecovery(id: "close-me")
        XCTAssertEqual(closed.metadata.recovery?.originalStatus, .recording)
        XCTAssertEqual(closed.metadata.recovery?.attemptCount, 0)

        XCTAssertEqual(closed.metadata.status, .failed)
        XCTAssertEqual(closed.metadata.recovery?.status, .closed)
        let detectedAgain = try await manager.recordRecoveryDetection(id: "close-me")
        XCTAssertFalse(detectedAgain)
        XCTAssertEqual(try Data(contentsOf: session.systemAudioURL), audio)
        let remainingCandidates = try await manager.scanForRecovery().candidates
        XCTAssertTrue(remainingCandidates.isEmpty)
    }

    func testCloseRecoveryIssuePreservesFolderAndStopsReportingIt() async throws {
        let corruptDirectory = root.appendingPathComponent("corrupt-issue", isDirectory: true)
        try FileManager.default.createDirectory(
            at: corruptDirectory,
            withIntermediateDirectories: true
        )
        let manifestURL = corruptDirectory.appendingPathComponent("session.json")
        let originalData = Data("not-json".utf8)
        try originalData.write(to: manifestURL)
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: RecoveryCapacityProvider(), minimumBytes: 1)
        )

        let initialIssues = try await manager.scanForRecovery().issues
        XCTAssertEqual(initialIssues.map(\.directoryName), ["corrupt-issue"])
        try await manager.closeRecoveryIssue(directoryName: "corrupt-issue")

        XCTAssertEqual(try Data(contentsOf: manifestURL), originalData)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: corruptDirectory.appendingPathComponent(
                SessionRecoveryScanner.closedIssueMarkerFileName
            ).path
        ))
        let remainingIssues = try await manager.scanForRecovery().issues
        XCTAssertTrue(remainingIssues.isEmpty)
    }

    func testUnsuccessfulRecoveryRemainsAvailableForRetry() async throws {
        let session = try makeSession(id: "retry-me", status: .recording)
        try Data("audio".utf8).write(to: session.systemAudioURL)
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: RecoveryCapacityProvider(), minimumBytes: 1)
        )
        _ = try await manager.beginRecovery(id: "retry-me")

        let stopped = try await manager.stopSession(
            transcription: SessionTranscriptionMetadata(
                status: .modelMissing,
                model: "missing.bin",
                systemSegmentCount: nil,
                microphoneSegmentCount: nil,
                warnings: [],
                failureReason: "Model missing"
            )
        )

        XCTAssertEqual(stopped.metadata.recovery?.status, .failed)
        XCTAssertEqual(stopped.metadata.recovery?.failureReason, "Model missing")
        let candidates = try await manager.scanForRecovery().candidates
        XCTAssertEqual(candidates.map(\.id), ["retry-me"])

        let retried = try await manager.beginRecovery(id: "retry-me")
        XCTAssertEqual(retried.metadata.recovery?.status, .inProgress)
        XCTAssertEqual(retried.metadata.recovery?.originalStatus, .recording)
        XCTAssertEqual(retried.metadata.recovery?.attemptCount, 2)

        let failedAgain = try await manager.failSession(reason: "Second attempt failed")
        XCTAssertEqual(failedAgain.metadata.recovery?.status, .failed)
        XCTAssertEqual(failedAgain.metadata.recovery?.attemptCount, 2)
        XCTAssertEqual(failedAgain.metadata.recovery?.failureReason, "Second attempt failed")
        let candidatesAfterSecondFailure = try await manager.scanForRecovery().candidates
        XCTAssertEqual(candidatesAfterSecondFailure.map(\.id), ["retry-me"])
    }

    func testRecoveryCommandsRejectUnknownCandidateWithoutCreatingActiveSession() async {
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: RecoveryCapacityProvider(), minimumBytes: 1)
        )

        do {
            _ = try await manager.beginRecovery(id: "missing")
            XCTFail("Expected beginRecovery to reject an unknown candidate.")
        } catch {
            XCTAssertEqual(error as? SessionRecoveryError, .candidateNotFound)
        }
        do {
            _ = try await manager.closeRecovery(id: "missing")
            XCTFail("Expected closeRecovery to reject an unknown candidate.")
        } catch {
            XCTAssertEqual(error as? SessionRecoveryError, .candidateNotFound)
        }
        let activeSession = await manager.currentSession()
        XCTAssertNil(activeSession)
    }

    func testRecoveryCandidateCanBeClosedWhileAnotherSessionIsActive() async throws {
        let candidate = try makeSession(id: "waiting-recovery", status: .recording)
        try Data("recoverable audio".utf8).write(to: candidate.systemAudioURL)
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: RecoveryCapacityProvider(), minimumBytes: 1)
        )
        _ = try await manager.startSession(title: "Active recording")

        do {
            _ = try await manager.beginRecovery(id: candidate.metadata.id)
            XCTFail("Expected active recording to block beginRecovery.")
        } catch {
            XCTAssertEqual(error as? SessionManagerError, .sessionAlreadyActive)
        }
        let visible = try await manager.recoveryCandidate(id: candidate.metadata.id)
        XCTAssertNotNil(visible)
        let closed = try await manager.closeRecovery(id: candidate.metadata.id)
        XCTAssertEqual(closed.metadata.recovery?.status, .closed)
        let active = await manager.currentSession()
        XCTAssertEqual(active?.metadata.status, .recording)
        _ = try await manager.failSession(reason: "Test cleanup")
    }

    func testActiveSessionIsNeverReportedAsRecoveryCandidate() async throws {
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: RecoveryCapacityProvider(), minimumBytes: 1)
        )
        let session = try await manager.startSession(title: "Still recording")
        try Data("growing audio".utf8).write(to: session.systemAudioURL)

        let result = try await manager.scanForRecovery()
        let activeID = await manager.currentSession()?.metadata.id

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(activeID, session.metadata.id)
    }

    func testRecoveredAudioInspectorReconstructsReadableCAFDiagnostics() throws {
        let session = try makeSession(id: "audio", status: .recording)
        try writeAudio(to: session.systemAudioURL, frameCount: 4_800)

        let diagnostics = try RecoveredAudioInspector().inspect(session: session)

        XCTAssertEqual(diagnostics.systemAudio.fileName, "system.caf")
        XCTAssertEqual(diagnostics.systemAudio.totalFrames, 4_800)
        XCTAssertEqual(diagnostics.systemAudio.sampleRate, 48_000)
        XCTAssertEqual(diagnostics.systemAudio.channelCount, 1)
        XCTAssertEqual(diagnostics.systemAudio.capturedDurationSeconds ?? -1, 0.1, accuracy: 0.001)
        XCTAssertNotNil(diagnostics.microphone.failureReason)
    }

    func testRecoveredAudioInspectorReadsOneHourSparseFileAsMetadataOnly() throws {
        let session = try makeSession(id: "one-hour-sparse-audio", status: .recording)
        let frameCount: UInt32 = 16_000 * 60 * 60
        try writeSparseWave(
            to: session.systemAudioURL,
            sampleRate: 16_000,
            frameCount: frameCount
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let diagnostics = try RecoveredAudioInspector().inspect(session: session)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(diagnostics.systemAudio.totalFrames, Int64(frameCount))
        XCTAssertEqual(diagnostics.systemAudio.capturedDurationSeconds ?? -1, 3_600, accuracy: 0.001)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testRecoveredAudioInspectorRepairsInterruptedDirectPCMWAV() throws {
        let session = try makeSession(
            metadata: SessionMetadata(
                id: "interrupted-direct-pcm",
                title: "interrupted-direct-pcm",
                status: .recording,
                createdAt: Date(),
                startedAt: Date()
            )
        )
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 48_000
        ))
        buffer.frameLength = 48_000
        buffer.floatChannelData?[0].initialize(repeating: 0.1, count: 48_000)
        let writer = AudioFileWriter(outputURL: session.systemAudioURL)
        _ = try writer.write(buffer)
        try writer.finish()

        let handle = try FileHandle(forUpdating: session.systemAudioURL)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        try handle.close()

        let diagnostics = try RecoveredAudioInspector().inspect(session: session)

        XCTAssertEqual(diagnostics.systemAudio.fileName, "system-16k.wav")
        XCTAssertEqual(diagnostics.systemAudio.totalFrames, 16_000)
        XCTAssertEqual(diagnostics.systemAudio.sampleRate, 16_000)
        XCTAssertEqual(diagnostics.systemAudio.channelCount, 1)
    }

    func testRecoveredAudioInspectorInfersMicrophoneTimelineOffset() throws {
        let session = try makeSession(id: "dual-track-audio", status: .recording)
        try writeAudio(to: session.systemAudioURL, frameCount: 9_600)
        try writeAudio(to: session.microphoneAudioURL, frameCount: 4_800)

        let sharedEndDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: sharedEndDate],
            ofItemAtPath: session.systemAudioURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: sharedEndDate],
            ofItemAtPath: session.microphoneAudioURL.path
        )

        let diagnostics = try RecoveredAudioInspector().inspect(session: session)

        XCTAssertEqual(diagnostics.systemAudio.firstPresentationTimestamp, 0)
        XCTAssertEqual(diagnostics.microphone.firstPresentationTimestamp ?? -1, 0.1, accuracy: 0.001)
        XCTAssertEqual(diagnostics.systemAudio.capturedDurationSeconds ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(diagnostics.microphone.capturedDurationSeconds ?? -1, 0.1, accuracy: 0.001)
    }

    func testRecoveredAudioInspectorAcceptsMicrophoneOnlyWithoutSystemFile() throws {
        let session = try makeSession(
            metadata: SessionMetadata(
                id: "microphone-only-recovery",
                title: "Offline meeting",
                status: .recording,
                createdAt: Date(),
                startedAt: Date(),
                captureMode: .microphoneOnly
            )
        )
        try writeAudio(to: session.microphoneAudioURL, frameCount: 4_800)

        let diagnostics = try RecoveredAudioInspector().inspect(session: session)

        XCTAssertEqual(diagnostics.systemAudio.bufferCount, 0)
        XCTAssertNil(diagnostics.systemAudio.failureReason)
        XCTAssertEqual(diagnostics.microphone.totalFrames, 4_800)
        XCTAssertEqual(diagnostics.microphone.firstPresentationTimestamp, 0)
    }

    func testRecoveredAudioInspectorPrefersPersistedCaptureTimeline() throws {
        let systemStart = 10_000.25
        let microphoneStart = 10_000.327
        let session = try makeSession(
            metadata: SessionMetadata(
                id: "persisted-timeline",
                title: "persisted-timeline",
                status: .failed,
                createdAt: Date(),
                startedAt: Date(),
                systemAudio: AudioTrackMetadata(
                    fileName: "system.caf",
                    sampleRate: 48_000,
                    channelCount: 1,
                    bufferCount: 100,
                    totalFrames: 9_600,
                    firstPresentationTimestamp: systemStart,
                    lastPresentationTimestamp: systemStart + 0.19,
                    capturedDurationSeconds: 0.2,
                    failureReason: "Display became unavailable."
                ),
                microphoneAudio: AudioTrackMetadata(
                    fileName: "microphone.caf",
                    sampleRate: 48_000,
                    channelCount: 1,
                    bufferCount: 50,
                    totalFrames: 4_800,
                    firstPresentationTimestamp: microphoneStart,
                    lastPresentationTimestamp: microphoneStart + 0.09,
                    capturedDurationSeconds: 0.1,
                    failureReason: nil
                )
            )
        )
        try writeAudio(to: session.systemAudioURL, frameCount: 9_600)
        try writeAudio(to: session.microphoneAudioURL, frameCount: 4_800)

        let systemEnd = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let misleadingMicrophoneEnd = systemEnd.addingTimeInterval(0.8)
        try FileManager.default.setAttributes(
            [.modificationDate: systemEnd],
            ofItemAtPath: session.systemAudioURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: misleadingMicrophoneEnd],
            ofItemAtPath: session.microphoneAudioURL.path
        )

        let diagnostics = try RecoveredAudioInspector().inspect(session: session)

        XCTAssertEqual(diagnostics.systemAudio.firstPresentationTimestamp, 0)
        XCTAssertEqual(
            diagnostics.microphone.firstPresentationTimestamp ?? -1,
            microphoneStart - systemStart,
            accuracy: 0.000_001
        )
    }

    private func makeSession(id: String, status: RecordingSessionStatus) throws -> RecordingSession {
        try makeSession(
            metadata: SessionMetadata(
                id: id,
                title: id,
                status: status,
                createdAt: Date(),
                startedAt: Date(),
                audioFiles: SessionAudioFiles(
                    system: "system.caf",
                    microphone: "microphone.caf",
                    systemWorking: "system-16k.wav",
                    microphoneWorking: "microphone-16k.wav"
                )
            )
        )
    }

    private func makeSession(metadata: SessionMetadata) throws -> RecordingSession {
        let directory = root.appendingPathComponent(metadata.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = RecordingSession(metadata: metadata, directoryURL: directory)
        let data = try SessionJSONCoder.makeEncoder().encode(metadata)
        try data.write(to: session.manifestURL, options: .atomic)
        return session
    }

    private func writeAudio(to url: URL, frameCount: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                samples[index] = sin(Float(index) * 0.03) * 0.1
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    private func writeSparseWave(
        to url: URL,
        sampleRate: UInt32,
        frameCount: UInt32
    ) throws {
        let bytesPerFrame: UInt32 = 2
        let payloadSize = frameCount * bytesPerFrame
        var header = Data("RIFF".utf8)
        appendLittleEndian(36 + payloadSize, to: &header)
        header.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(sampleRate, to: &header)
        appendLittleEndian(sampleRate * bytesPerFrame, to: &header)
        appendLittleEndian(UInt16(bytesPerFrame), to: &header)
        appendLittleEndian(UInt16(16), to: &header)
        header.append(Data("data".utf8))
        appendLittleEndian(payloadSize, to: &header)
        try header.write(to: url)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(header.count) + UInt64(payloadSize))
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private struct RecoveryCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 { 2_000_000_000 }
}

// These mirror the synthesized decoder shipped before detection was persisted.
private struct LegacyRecoveryManifest: Decodable {
    let schemaVersion: Int
    let recovery: LegacyRecoveryMetadata?
}

private struct LegacyRecoveryMetadata: Decodable {
    enum Status: String, Decodable {
        case inProgress, completed, failed, closed
    }

    let status: Status
    let originalStatus: RecordingSessionStatus
    let detectedAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let attemptCount: Int
    let failureReason: String?
}
