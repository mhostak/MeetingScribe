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

    func testStartWithNotesWritesNotesFileAndManifestField() async throws {
        let manager = makeManager()
        let startedAt = Date(timeIntervalSince1970: 1_725_876_600)

        let started = try await manager.startSession(
            title: "Notes meeting",
            notes: "  Agenda and decisions  ",
            now: startedAt
        )

        XCTAssertEqual(try String(contentsOf: started.notesURL, encoding: .utf8), "  Agenda and decisions  ")
        XCTAssertEqual(started.metadata.notes?.fileName, "notes.md")
        XCTAssertEqual(started.metadata.notes?.updatedAt, startedAt)
        XCTAssertEqual(started.metadata.notes?.characterCount, "  Agenda and decisions  ".count)

        let metadata = try decodeMetadata(at: started.manifestURL)
        XCTAssertEqual(metadata.notes, started.metadata.notes)
    }

    func testStartWithEmptyOrNilNotesDoesNotWriteFile() async throws {
        for notes: String? in ["", "  \n ", nil] {
            let manager = makeManager()
            let started = try await manager.startSession(
                title: "No notes",
                notes: notes
            )

            XCTAssertFalse(FileManager.default.fileExists(atPath: started.notesURL.path))
            XCTAssertNil(started.metadata.notes)
            XCTAssertNil(try decodeMetadata(at: started.manifestURL).notes)
            _ = try await manager.stopSession()
        }
    }

    func testUpdateActiveSessionNotesOverwritesFileAndUpdatesMetadata() async throws {
        let manager = makeManager()
        let started = try await manager.startSession(
            title: "Notes update",
            notes: "First note",
            now: Date(timeIntervalSince1970: 1_725_876_600)
        )

        let updated = try await manager.updateActiveSessionNotes("  Second note  ")
        let active = await manager.currentSession()

        XCTAssertEqual(try String(contentsOf: started.notesURL, encoding: .utf8), "  Second note  ")
        XCTAssertEqual(updated.metadata.notes?.characterCount, "  Second note  ".count)
        XCTAssertGreaterThan(
            try XCTUnwrap(updated.metadata.notes).updatedAt,
            try XCTUnwrap(started.metadata.notes).updatedAt
        )
        XCTAssertEqual(active?.metadata.notes, updated.metadata.notes)
        XCTAssertEqual(try decodeMetadata(at: started.manifestURL).notes?.characterCount, updated.metadata.notes?.characterCount)
    }

    func testUpdateActiveSessionNotesWithWhitespaceRemovesFileAndMetadata() async throws {
        let manager = makeManager()
        let started = try await manager.startSession(title: "Notes removal", notes: "Remove me")

        let updated = try await manager.updateActiveSessionNotes("  \n ")

        XCTAssertFalse(FileManager.default.fileExists(atPath: started.notesURL.path))
        XCTAssertNil(updated.metadata.notes)
        XCTAssertNil(try decodeMetadata(at: started.manifestURL).notes)
    }

    func testManifestWithoutNotesKeyStillDecodes() async throws {
        let manager = makeManager()
        let started = try await manager.startSession(title: "Legacy notes")
        let data = try Data(contentsOf: started.manifestURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "notes")

        let metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(metadata.schemaVersion, 16)
        XCTAssertNil(metadata.notes)
    }

    func testOnboardingTestTitleDoesNotCreateNotes() async throws {
        let manager = makeManager()
        let started = try await manager.startSession(title: "MeetingScribe Setup Test")

        XCTAssertFalse(FileManager.default.fileExists(atPath: started.notesURL.path))
        XCTAssertNil(started.metadata.notes)
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

    func testFinishCaptureAndQueuePersistsHandoffBeforeReleasingCapture() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = startedAt.addingTimeInterval(42)
        let started = try await manager.startSession(title: "Queued capture", now: startedAt)
        let configuration = ProcessingJobConfiguration(
            outputDirectoryURL: URL(fileURLWithPath: "/tmp/Meeting Notes"),
            automaticallyDeleteSourceCAF: true
        )
        let diagnostics = makeDiagnostics()

        let handedOff = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: endedAt,
            diagnostics: diagnostics,
            configuration: configuration,
            now: endedAt
        )

        let job = try XCTUnwrap(handedOff.metadata.processing)
        XCTAssertEqual(handedOff.metadata.status, .recorded)
        XCTAssertEqual(handedOff.metadata.endedAt, endedAt)
        XCTAssertEqual(handedOff.metadata.systemAudio, diagnostics.systemAudio.sessionMetadata)
        XCTAssertEqual(handedOff.metadata.microphoneAudio, diagnostics.microphone.sessionMetadata)
        XCTAssertEqual(job.kind, .initial)
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.enqueuedAt, endedAt)
        XCTAssertEqual(job.configuration, configuration)
        let activeSession = await manager.currentSession()
        XCTAssertNil(activeSession)

        let restarted = SessionManager(recordingsRoot: temporaryRoot)
        let pending = try await restarted.loadProcessingSessions()
        XCTAssertEqual(pending.map(\.metadata.id), [started.metadata.id])
        XCTAssertEqual(pending.first?.metadata.processing, job)
    }

    func testFinishCaptureAndQueueRetryDoesNotCreateSecondJob() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Idempotent handoff")
        let configuration = ProcessingJobConfiguration(
            outputDirectoryURL: nil,
            automaticallyDeleteSourceCAF: false
        )
        let first = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date(),
            diagnostics: makeDiagnostics(),
            configuration: configuration
        )
        let retried = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date().addingTimeInterval(20),
            diagnostics: .empty,
            configuration: configuration
        )

        XCTAssertEqual(retried.metadata.processing?.jobID, first.metadata.processing?.jobID)
        XCTAssertEqual(retried.metadata.processing?.attemptID, first.metadata.processing?.attemptID)
        XCTAssertEqual(
            try decodeMetadata(at: started.manifestURL).processing?.jobID,
            first.metadata.processing?.jobID
        )
    }

    func testProcessingUpdateRejectsStaleAttemptAndPreservesLatestManifest() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Stale callback")
        let queued = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date(),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(
                outputDirectoryURL: nil,
                automaticallyDeleteSourceCAF: false
            )
        )
        let job = try XCTUnwrap(queued.metadata.processing)
        let finalization = makeFinalization()
        let updated = try await manager.updateProcessing(
            sessionID: started.metadata.id,
            jobID: job.jobID,
            attemptID: job.attemptID,
            patch: ProcessingJobPatch(
                state: .running,
                stage: .transcribing,
                checkpoint: .preparingAudio,
                updatesStage: true,
                updatesCheckpoint: true
            ),
            artifactMetadata: ProcessingArtifactMetadata(audioFinalization: finalization)
        )

        XCTAssertEqual(updated.metadata.processing?.state, .running)
        XCTAssertEqual(updated.metadata.processing?.stage, .transcribing)
        XCTAssertEqual(updated.metadata.processing?.checkpoint, .preparingAudio)
        XCTAssertEqual(updated.metadata.audioFinalization, finalization)

        do {
            _ = try await manager.updateProcessing(
                sessionID: started.metadata.id,
                jobID: job.jobID,
                attemptID: UUID(),
                patch: ProcessingJobPatch(state: .failed)
            )
            XCTFail("Expected a delayed processing callback to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? ProcessingJobRepositoryError,
                .processingIdentityMismatch(started.metadata.id)
            )
        }

        let persisted = try decodeMetadata(at: started.manifestURL)
        XCTAssertEqual(persisted.processing?.state, .running)
        XCTAssertEqual(persisted.audioFinalization, finalization)
    }

    func testCompleteProcessingPersistsArtifactsAndFailureWithoutActiveMutation() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Per-job completion")
        let queued = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date(),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(
                outputDirectoryURL: nil,
                automaticallyDeleteSourceCAF: false
            )
        )
        let job = try XCTUnwrap(queued.metadata.processing)
        let transcription = SessionTranscriptionMetadata(
            status: .completed,
            model: "test-model",
            systemSegmentCount: 3,
            microphoneSegmentCount: 2,
            warnings: [],
            failureReason: nil
        )
        let completed = try await manager.completeProcessing(
            sessionID: started.metadata.id,
            jobID: job.jobID,
            attemptID: job.attemptID,
            artifactMetadata: ProcessingArtifactMetadata(transcription: transcription),
            failureDescription: "Export destination unavailable",
            failedSteps: [.exporting]
        )

        XCTAssertEqual(completed.metadata.processing?.state, .failed)
        XCTAssertEqual(completed.metadata.processing?.failureDescription, "Export destination unavailable")
        XCTAssertEqual(completed.metadata.transcription, transcription)
        let activeSession = await manager.currentSession()
        XCTAssertNil(activeSession)
    }

    func testTerminalJobRejectsLateCallback() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Terminal job")
        let queued = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date(),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
        )
        let job = try XCTUnwrap(queued.metadata.processing)
        _ = try await manager.completeProcessing(
            sessionID: started.metadata.id,
            jobID: job.jobID,
            attemptID: job.attemptID,
            artifactMetadata: ProcessingArtifactMetadata()
        )

        do {
            _ = try await manager.updateProcessing(
                sessionID: started.metadata.id,
                jobID: job.jobID,
                attemptID: job.attemptID,
                patch: ProcessingJobPatch(state: .pauseRequested)
            )
            XCTFail("Expected a terminal job to reject a delayed callback.")
        } catch {
            XCTAssertEqual(
                error as? ProcessingJobRepositoryError,
                .processingJobAlreadyTerminal(started.metadata.id)
            )
        }
        XCTAssertEqual(try decodeMetadata(at: started.manifestURL).processing?.state, .completed)
    }

    func testCompletionPromotesFrozenAnalysisConfigurationOnlyOnSuccess() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Analysis snapshot")
        let configuration = SessionAnalysisConfiguration(
            tool: .codex,
            executablePath: "/tmp/codex",
            model: "test-model",
            prompt: "Summarize the meeting."
        )
        let queued = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date(),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(
                outputDirectoryURL: nil,
                automaticallyDeleteSourceCAF: false,
                analysisConfiguration: configuration
            )
        )
        let job = try XCTUnwrap(queued.metadata.processing)
        let analysis = SessionAnalysisMetadata(
            status: .completed,
            provider: "codex",
            model: "test-model",
            startedAt: nil,
            completedAt: Date(),
            transcriptChunkCount: 1,
            requestCount: 1,
            failureReason: nil
        )
        let completed = try await manager.completeProcessing(
            sessionID: started.metadata.id,
            jobID: job.jobID,
            attemptID: job.attemptID,
            artifactMetadata: ProcessingArtifactMetadata(analysis: analysis)
        )

        XCTAssertEqual(completed.metadata.analysisConfiguration, configuration)
        XCTAssertEqual(try decodeMetadata(at: started.manifestURL).analysisConfiguration, configuration)
    }

    func testFutureProcessingSchemaIsVisibleAndCannotBeRequeued() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Future schema")
        _ = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date(),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
        )
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: started.manifestURL)) as? [String: Any]
        )
        var processing = try XCTUnwrap(document["processing"] as? [String: Any])
        processing["schemaVersion"] = ProcessingJob.currentSchemaVersion + 1
        document["processing"] = processing
        try JSONSerialization.data(withJSONObject: document).write(to: started.manifestURL, options: .atomic)

        do {
            _ = try await manager.queueProcessing(
                sessionID: started.metadata.id,
                kind: .retranscribe,
                configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
            )
            XCTFail("Expected a future job schema to reject queue mutation.")
        } catch {
            XCTAssertEqual(
                error as? ProcessingJobRepositoryError,
                .unsupportedSchema(
                    sessionID: started.metadata.id,
                    schemaVersion: ProcessingJob.currentSchemaVersion + 1
                )
            )
        }
        let issues = try await manager.scanForRecovery().issues
        XCTAssertTrue(issues.contains { $0.directoryName == started.metadata.id })
    }

    func testQueueProcessingIsIdempotentThenCreatesFreshTerminalAttempt() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let started = try await manager.startSession(title: "Retry queue")
        let queued = try await manager.finishCaptureAndQueue(
            expectedSessionID: started.metadata.id,
            endedAt: Date(),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(
                outputDirectoryURL: nil,
                automaticallyDeleteSourceCAF: false
            )
        )
        let initial = try XCTUnwrap(queued.metadata.processing)
        let duplicate = try await manager.queueProcessing(
            sessionID: started.metadata.id,
            kind: .retranscribe,
            configuration: initial.configuration
        )
        XCTAssertEqual(duplicate.metadata.processing?.jobID, initial.jobID)

        _ = try await manager.completeProcessing(
            sessionID: started.metadata.id,
            jobID: initial.jobID,
            attemptID: initial.attemptID,
            artifactMetadata: ProcessingArtifactMetadata()
        )
        let retry = try await manager.queueProcessing(
            sessionID: started.metadata.id,
            kind: .retranscribe,
            configuration: initial.configuration
        )
        XCTAssertNotEqual(retry.metadata.processing?.jobID, initial.jobID)
        XCTAssertNotEqual(retry.metadata.processing?.attemptID, initial.attemptID)
        XCTAssertEqual(retry.metadata.processing?.kind, .retranscribe)
        XCTAssertEqual(retry.metadata.processing?.state, .queued)
    }

    func testLoadProcessingSessionsIncludesTerminalJobsAndResumeCreatesNewAttempt() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let first = try await manager.startSession(title: "First", now: Date(timeIntervalSince1970: 100))
        let firstQueued = try await manager.finishCaptureAndQueue(
            expectedSessionID: first.metadata.id,
            endedAt: Date(timeIntervalSince1970: 110),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false),
            now: Date(timeIntervalSince1970: 120)
        )
        let firstJob = try XCTUnwrap(firstQueued.metadata.processing)
        let running = try await manager.updateProcessing(
            sessionID: first.metadata.id,
            jobID: firstJob.jobID,
            attemptID: firstJob.attemptID,
            patch: ProcessingJobPatch(state: .running)
        )
        let runningJob = try XCTUnwrap(running.metadata.processing)

        let second = try await manager.startSession(title: "Second", now: Date(timeIntervalSince1970: 200))
        let secondQueued = try await manager.finishCaptureAndQueue(
            expectedSessionID: second.metadata.id,
            endedAt: Date(timeIntervalSince1970: 210),
            diagnostics: makeDiagnostics(),
            configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false),
            now: Date(timeIntervalSince1970: 220)
        )
        let secondJob = try XCTUnwrap(secondQueued.metadata.processing)
        _ = try await manager.completeProcessing(
            sessionID: second.metadata.id,
            jobID: secondJob.jobID,
            attemptID: secondJob.attemptID,
            artifactMetadata: ProcessingArtifactMetadata()
        )

        let loaded = try await manager.loadProcessingSessions()
        XCTAssertEqual(loaded.map(\.metadata.id), [first.metadata.id, second.metadata.id])
        XCTAssertEqual(loaded.last?.metadata.processing?.state, .completed)

        let resumed = try await manager.resumeInterruptedProcessing(
            sessionID: first.metadata.id,
            jobID: runningJob.jobID,
            attemptID: runningJob.attemptID
        )
        XCTAssertEqual(resumed.metadata.processing?.state, .queued)
        XCTAssertEqual(resumed.metadata.processing?.jobID, runningJob.jobID)
        XCTAssertNotEqual(resumed.metadata.processing?.attemptID, runningJob.attemptID)
    }

    func testRecoveryQueuePreservesSuggestedEndAndIsExcludedFromLegacyScan() async throws {
        let captureManager = SessionManager(recordingsRoot: temporaryRoot)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let interrupted = try await captureManager.startSession(
            title: "Interrupted",
            now: startedAt
        )
        try Data([1, 2, 3]).write(to: interrupted.systemAudioURL)

        let repository = SessionManager(recordingsRoot: temporaryRoot)
        let queued = try await repository.queueProcessing(
            sessionID: interrupted.metadata.id,
            kind: .recovery,
            configuration: ProcessingJobConfiguration(
                outputDirectoryURL: nil,
                automaticallyDeleteSourceCAF: false
            ),
            now: startedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(queued.metadata.processing?.kind, .recovery)
        XCTAssertEqual(queued.metadata.status, .recorded)
        XCTAssertEqual(queued.metadata.recovery?.status, .inProgress)
        XCTAssertNotNil(queued.metadata.endedAt)
        let candidates = try await repository.scanForRecovery().candidates
        XCTAssertFalse(candidates.contains { $0.id == interrupted.metadata.id })
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

    private func makeManager() -> SessionManager {
        SessionManager(
            recordingsRoot: temporaryRoot,
            storageGuard: StorageGuard(provider: SufficientStorageCapacityProvider())
        )
    }

    private func makeDiagnostics() -> CaptureSessionDiagnostics {
        CaptureSessionDiagnostics(
            systemAudio: AudioCaptureDiagnostics(
                fileName: "system.caf",
                bufferCount: 4,
                totalFrames: 192_000,
                sampleRate: 48_000,
                channelCount: 2,
                firstPresentationTimestamp: 100,
                lastPresentationTimestamp: 104,
                lastBufferDurationSeconds: 1,
                failureReason: nil
            ),
            microphone: AudioCaptureDiagnostics(
                fileName: "microphone.caf",
                bufferCount: 4,
                totalFrames: 192_000,
                sampleRate: 48_000,
                channelCount: 1,
                firstPresentationTimestamp: 100,
                lastPresentationTimestamp: 104,
                lastBufferDurationSeconds: 1,
                failureReason: nil
            )
        )
    }

    private func makeFinalization() -> AudioFinalizationMetadata {
        AudioFinalizationMetadata(
            completedAt: Date(timeIntervalSince1970: 1_800_000_100),
            timelineOrigin: 100,
            system: nil,
            microphone: nil,
            warnings: []
        )
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

private struct SufficientStorageCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 {
        2_147_483_648
    }
}
