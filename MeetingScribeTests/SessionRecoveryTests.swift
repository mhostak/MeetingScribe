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

    private func makeSession(id: String, status: RecordingSessionStatus) throws -> RecordingSession {
        try makeSession(
            metadata: SessionMetadata(
                id: id,
                title: id,
                status: status,
                createdAt: Date(),
                startedAt: Date()
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
        let writer = AudioFileWriter(outputURL: url)
        _ = try writer.write(buffer)
        writer.finish()
    }
}

private struct RecoveryCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 { 1_000_000 }
}
