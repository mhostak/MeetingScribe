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

        let session = try await manager.startSession(
            title: "Project Alpha weekly",
            language: .czech,
            outputLanguage: .english,
            outputFileNameTemplate: "{date} - {title} - {id}",
            now: startedAt
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.manifestURL.path))

        let metadata = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(metadata.id, session.metadata.id)
        XCTAssertEqual(metadata.title, "Project Alpha weekly")
        XCTAssertEqual(metadata.status, .recording)
        XCTAssertEqual(metadata.startedAt, startedAt)
        XCTAssertEqual(metadata.language, .czech)
        XCTAssertEqual(metadata.schemaVersion, 16)
        XCTAssertEqual(metadata.captureMode, .systemAndMicrophone)
        XCTAssertEqual(metadata.resolvedCaptureMode, .systemAndMicrophone)
        XCTAssertEqual(metadata.audioFiles.system, "system-16k.wav")
        XCTAssertEqual(metadata.audioFiles.microphone, "microphone-16k.wav")
        XCTAssertNil(metadata.audioFiles.systemWorking)
        XCTAssertNil(metadata.audioFiles.microphoneWorking)
        XCTAssertEqual(metadata.transcriptFiles?.systemTrack, "system-transcript.json")
        XCTAssertEqual(metadata.transcriptFiles?.microphoneTrack, "microphone-transcript.json")
        XCTAssertEqual(metadata.transcriptFiles?.merged, "transcript.json")
        XCTAssertEqual(metadata.transcriptFiles?.speakerTurns, "speaker-turns.json")
        XCTAssertEqual(metadata.transcriptFiles?.utterances, "utterance-transcript.json")
        XCTAssertEqual(metadata.transcriptFiles?.analysis, "analysis.json")
        XCTAssertEqual(metadata.resolvedOutputLanguage, .english)
        XCTAssertEqual(metadata.resolvedOutputFileNameTemplate, "{date} - {title} - {id}")
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
            provider: "codex",
            model: "default",
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

    func testRenameActiveSessionUpdatesMemoryAndManifest() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Original title")

        let renamed = try await manager.renameActiveSession(to: "  Updated title  ")
        let active = await manager.currentSession()

        XCTAssertEqual(renamed.metadata.title, "Updated title")
        XCTAssertEqual(active?.metadata.title, "Updated title")
        XCTAssertEqual(
            try decodeMetadata(at: started.manifestURL).title,
            "Updated title"
        )
    }

    func testRenameActiveSessionRejectsEmptyTitle() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Original title")

        do {
            _ = try await manager.renameActiveSession(to: "  \n ")
            XCTFail("Expected an empty title to be rejected.")
        } catch {
            XCTAssertEqual(error as? SessionManagerError, .emptyTitle)
        }

        XCTAssertEqual(
            try decodeMetadata(at: started.manifestURL).title,
            "Original title"
        )
    }

    func testCalendarSnapshotIsPersistedAndUpdatedAtomicallyWithTitle() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let initialSnapshot = makeCalendarSnapshot(title: "Initial event")
        let started = try await manager.startSession(
            title: "Manual title",
            calendarEvent: initialSnapshot
        )

        XCTAssertEqual(started.metadata.calendarEvent, initialSnapshot)

        let updatedSnapshot = makeCalendarSnapshot(title: "Updated event")
        let updated = try await manager.updateActiveSessionCalendarEvent(
            updatedSnapshot,
            title: "  Updated event  "
        )
        let persisted = try decodeMetadata(at: started.manifestURL)

        XCTAssertEqual(updated.metadata.title, "Updated event")
        XCTAssertEqual(updated.metadata.calendarEvent, updatedSnapshot)
        XCTAssertEqual(persisted.title, "Updated event")
        XCTAssertEqual(persisted.calendarEvent, updatedSnapshot)
    }

    func testRecordsSourceCleanupAuditAfterSessionCompletion() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        _ = try await manager.startSession(title: "Cleanup")
        let stopped = try await manager.stopSession()
        let cleanup = AudioSourceCleanupMetadata(
            status: .completed,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000),
            deletedFiles: ["system.caf", "microphone.caf"],
            failureReason: nil
        )

        let updated = try await manager.recordAudioSourceCleanup(cleanup, for: stopped)

        XCTAssertEqual(updated.metadata.audioSourceCleanup, cleanup)
        XCTAssertEqual(try decodeMetadata(at: stopped.manifestURL).audioSourceCleanup, cleanup)
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
        XCTAssertNil(metadata.provenance)
    }

    func testSessionMetadataDecodesSchemaElevenWithoutTranscriptionProvenance() throws {
        let legacy = SessionMetadata(
            schemaVersion: 11,
            id: "schema-11-session",
            title: "Legacy grouping session",
            status: .recorded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "ggml-large-v3-turbo.bin",
                systemSegmentCount: 1,
                microphoneSegmentCount: 0,
                warnings: [],
                failureReason: nil
            )
        )

        let data = try SessionJSONCoder.makeEncoder().encode(legacy)
        let decoded = try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 11)
        XCTAssertEqual(decoded.transcription?.model, "ggml-large-v3-turbo.bin")
        XCTAssertNil(decoded.transcription?.provenance)
    }

    func testSessionMetadataDecodesSchemaEightWithoutOutputSettings() throws {
        let legacy = SessionMetadata(
            schemaVersion: 8,
            id: "legacy-session",
            title: "Legacy",
            status: .recorded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            outputLanguage: nil,
            outputFileNameTemplate: nil
        )
        let encoded = try SessionJSONCoder.makeEncoder().encode(legacy)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "outputLanguage")
        object.removeValue(forKey: "outputFileNameTemplate")

        let decoded = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.schemaVersion, 8)
        XCTAssertEqual(decoded.resolvedOutputLanguage, .slovak)
        XCTAssertEqual(
            decoded.resolvedOutputFileNameTemplate,
            MarkdownFileNameTemplate.defaultValue
        )
    }

    private func decodeMetadata(at url: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: url)
        return try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: data)
    }

    private func makeCalendarSnapshot(title: String) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            source: .appleCalendar,
            title: title,
            startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: Date(timeIntervalSince1970: 1_800_003_600),
            selectedAt: Date(timeIntervalSince1970: 1_799_999_000),
            participants: [
                ConfirmedParticipant(displayName: "Participant One"),
            ],
            shareParticipantNamesWithAnalysis: false
        )
    }
}
