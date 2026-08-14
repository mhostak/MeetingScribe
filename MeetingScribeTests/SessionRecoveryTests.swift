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

        let active = try await manager.beginRecovery(id: "recover-me", now: startedAt)

        XCTAssertEqual(active.metadata.recovery?.status, .inProgress)
        XCTAssertEqual(active.metadata.recovery?.originalStatus, .recording)
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

        let closed = try await manager.closeRecovery(id: "close-me")

        XCTAssertEqual(closed.metadata.status, .failed)
        XCTAssertEqual(closed.metadata.recovery?.status, .closed)
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

    func testRecoveryCommandsAreRejectedWhileAnotherSessionIsActive() async throws {
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
        do {
            _ = try await manager.closeRecovery(id: candidate.metadata.id)
            XCTFail("Expected active recording to block closeRecovery.")
        } catch {
            XCTAssertEqual(error as? SessionManagerError, .sessionAlreadyActive)
        }
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
    func availableCapacity(at url: URL) throws -> Int64 { 1_000_000 }
}
