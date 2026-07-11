import Foundation
import XCTest
@testable import MeetingScribe

final class SessionManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testStartCreatesSessionDirectoryAndManifest() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let startedAt = Date(timeIntervalSince1970: 1_725_876_600)

        let session = try await manager.startSession(title: "SOFA weekly", now: startedAt)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.manifestURL.path))

        let metadata = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(metadata.id, session.metadata.id)
        XCTAssertEqual(metadata.title, "SOFA weekly")
        XCTAssertEqual(metadata.status, .recording)
        XCTAssertEqual(metadata.startedAt, startedAt)
        XCTAssertEqual(metadata.schemaVersion, 6)
        XCTAssertEqual(metadata.audioFiles.system, "system.caf")
        XCTAssertEqual(metadata.audioFiles.microphone, "microphone.caf")
        XCTAssertEqual(metadata.audioFiles.systemWorking, "system-16k.wav")
        XCTAssertEqual(metadata.audioFiles.microphoneWorking, "microphone-16k.wav")
        XCTAssertEqual(metadata.transcriptFiles?.systemTrack, "system-transcript.json")
        XCTAssertEqual(metadata.transcriptFiles?.microphoneTrack, "microphone-transcript.json")
        XCTAssertEqual(metadata.transcriptFiles?.merged, "transcript.json")
        XCTAssertEqual(metadata.transcriptFiles?.analysis, "analysis.json")
    }

    func testStopFinalizesManifestWithoutDeletingSession() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let startedAt = Date(timeIntervalSince1970: 1_725_876_600)
        let endedAt = startedAt.addingTimeInterval(90)
        let systemAudio = AudioTrackMetadata(
            fileName: "system.caf",
            sampleRate: 48_000,
            channelCount: 2,
            bufferCount: 90,
            totalFrames: 4_320_000,
            firstPresentationTimestamp: 100,
            lastPresentationTimestamp: 190,
            capturedDurationSeconds: 90,
            failureReason: nil
        )
        let microphoneAudio = AudioTrackMetadata(
            fileName: "microphone.caf",
            sampleRate: 48_000,
            channelCount: 1,
            bufferCount: 90,
            totalFrames: 4_320_000,
            firstPresentationTimestamp: 100.02,
            lastPresentationTimestamp: 190.02,
            capturedDurationSeconds: 90,
            failureReason: nil
        )
        let audioFinalization = AudioFinalizationMetadata(
            completedAt: endedAt,
            timelineOrigin: 100,
            system: FinalizedAudioTrackMetadata(
                fileName: "system-16k.wav",
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 1_440_000,
                durationSeconds: 90,
                timelineOffsetSeconds: 0
            ),
            microphone: FinalizedAudioTrackMetadata(
                fileName: "microphone-16k.wav",
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 1_440_000,
                durationSeconds: 90,
                timelineOffsetSeconds: 0.02
            ),
            warnings: []
        )
        let transcription = SessionTranscriptionMetadata(
            status: .completed,
            model: "ggml-test.bin",
            startedAt: endedAt,
            completedAt: endedAt,
            systemSegmentCount: 2,
            microphoneSegmentCount: 1,
            mergedSegmentCount: 3,
            warnings: [],
            failureReason: nil
        )
        let output = SessionOutputMetadata(
            status: .completed,
            markdownFileName: "2026-07-11 09-30 - Meeting.md",
            markdownPath: "/tmp/2026-07-11 09-30 - Meeting.md",
            exportedAt: endedAt,
            failureReason: nil
        )
        let analysis = SessionAnalysisMetadata(
            status: .completed,
            provider: "openai",
            model: "gpt-5.6-luna",
            startedAt: endedAt,
            completedAt: endedAt,
            transcriptChunkCount: 1,
            requestCount: 1,
            failureReason: nil
        )

        let started = try await manager.startSession(title: "", now: startedAt)
        let stopped = try await manager.stopSession(
            now: endedAt,
            systemAudio: systemAudio,
            microphoneAudio: microphoneAudio,
            audioFinalization: audioFinalization,
            transcription: transcription,
            analysis: analysis,
            output: output
        )
        let activeSession = await manager.currentSession()

        XCTAssertEqual(stopped.metadata.status, .recorded)
        XCTAssertEqual(stopped.metadata.endedAt, endedAt)
        XCTAssertNil(activeSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.directoryURL.path))

        let metadata = try decodeMetadata(at: stopped.manifestURL)
        XCTAssertEqual(metadata.status, .recorded)
        XCTAssertEqual(metadata.endedAt, endedAt)
        XCTAssertTrue(metadata.title.hasPrefix("Meeting "))
        XCTAssertEqual(metadata.systemAudio, systemAudio)
        XCTAssertEqual(metadata.microphoneAudio, microphoneAudio)
        XCTAssertEqual(metadata.audioFinalization, audioFinalization)
        XCTAssertEqual(metadata.transcription, transcription)
        XCTAssertEqual(metadata.analysis, analysis)
        XCTAssertEqual(metadata.output, output)
    }

    func testCaptureFailureIsPersistedWithoutDeletingSession() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Failed capture")
        let failed = try await manager.failSession(reason: "Permission denied")

        XCTAssertEqual(failed.metadata.status, .failed)
        XCTAssertEqual(failed.metadata.failureReason, "Permission denied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.directoryURL.path))

        let metadata = try decodeMetadata(at: failed.manifestURL)
        XCTAssertEqual(metadata.status, .failed)
        XCTAssertEqual(metadata.failureReason, "Permission denied")
    }

    func testCannotStartSecondSession() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        _ = try await manager.startSession(title: "First")

        do {
            _ = try await manager.startSession(title: "Second")
            XCTFail("Expected a second active session to be rejected.")
        } catch {
            XCTAssertEqual(error as? SessionManagerError, .sessionAlreadyActive)
        }
    }

    func testAudioFileListDecodesLegacyManifestWithoutWorkingTracks() throws {
        let data = Data(#"""
        {
            "system": "system.caf",
            "microphone": "microphone.caf",
            "mixed": "mixed.wav"
        }
        """#.utf8)

        let files = try JSONDecoder().decode(SessionAudioFiles.self, from: data)

        XCTAssertEqual(files.system, "system.caf")
        XCTAssertEqual(files.microphone, "microphone.caf")
        XCTAssertNil(files.systemWorking)
        XCTAssertNil(files.microphoneWorking)
    }

    func testTranscriptionMetadataDecodesWithoutMergedSegmentCount() throws {
        let data = Data(#"""
        {
            "status": "completed",
            "model": "ggml-test.bin",
            "systemSegmentCount": 2,
            "microphoneSegmentCount": 1,
            "warnings": []
        }
        """#.utf8)

        let metadata = try JSONDecoder().decode(SessionTranscriptionMetadata.self, from: data)

        XCTAssertEqual(metadata.status, .completed)
        XCTAssertNil(metadata.mergedSegmentCount)
    }

    private func decodeMetadata(at url: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: url)
        return try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: data)
    }
}
