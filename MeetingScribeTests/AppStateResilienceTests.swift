import Combine
import Foundation
import XCTest
@testable import MeetingScribe

@MainActor
final class AppStateResilienceTests: XCTestCase {
    func testUserFacingErrorsAreLocalizedForExplicitApplicationLanguage() {
        XCTAssertEqual(
            AppLocalization.error(
                AnalysisError.executableNotFound(path: "/missing/codex"),
                language: .slovak
            ),
            "Spustiteľný súbor AI nástroja sa nenašiel na /missing/codex."
        )
        XCTAssertEqual(
            AppLocalization.error(
                SessionRecoveryError.pendingRecoveryMustBeResolved,
                language: .czech
            ),
            "Před spuštěním nové nahrávky obnovte nebo zavřete nedokončenou nahrávku."
        )
        XCTAssertEqual(
            AppLocalization.message(
                .recordingSavedTranscription("detail-42"),
                language: .slovak
            ),
            "Nahrávka bola uložená. Prepis zlyhal: detail-42"
        )
        XCTAssertEqual(
            AppLocalization.message(.captureStalledSafeStop, language: .czech),
            "Nahrávání bylo bezpečně zastaveno, protože zachytávání systémového zvuku přestalo přijímat data. Existující audio zůstalo zachované."
        )
        XCTAssertEqual(
            AppLocalization.message(
                .fluidAudioModelDownload("Parakeet", "detail-42"),
                language: .slovak
            ),
            "Model FluidAudio Parakeet sa nepodarilo nainštalovať: detail-42"
        )
        XCTAssertEqual(
            AppLocalization.error(
                FluidAudioModelManagerError.manifestMismatch,
                language: .czech
            ),
            "Nainstalovaný model neodpovídá připnuté revizi."
        )
        XCTAssertEqual(
            AppLocalization.error(
                AnalysisRevisionError.transcriptMissing,
                language: .slovak
            ),
            "Záznam nemá prepis, ktorý by bolo možné analyzovať."
        )
        XCTAssertEqual(
            AppLocalization.error(
                MarkdownAnalysisUpdateError.invalidStructure,
                language: .czech
            ),
            "Soubor Markdown neobsahuje platný blok AI analýzy MeetingScribe."
        )
    }

    func testProcessingNotificationsOptInIsPersistedAndRequestsAuthorization() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let notifier = ResilienceProcessingNotifier()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: fixture.root),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            defaults: fixture.defaults,
            processingNotifier: notifier
        )

        XCTAssertFalse(appState.notificationsEnabled)
        await appState.setNotificationsEnabled(true)

        XCTAssertTrue(appState.notificationsEnabled)
        XCTAssertEqual(notifier.authorizationRequests, 1)
        XCTAssertTrue(fixture.defaults.bool(forKey: "processingNotificationsEnabled"))
    }

    func testProcessingNotificationsIdentifyFailuresAndRespectOptOut() async throws {
        let cases: [(String, [ProcessingStepID])] = [
            ("model", [.transcribing]), ("transcriber", [.transcribing]),
            ("audio", [.preparingAudio]), ("analysis", [.analyzing]),
            ("export", [.exporting]), ("analysisAndExport", [.analyzing, .exporting]),
            ("disabled", []), ("successWithoutAnalysis", [])
        ]
        for (scenario, expectedSteps) in cases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let settings = AnalysisSettingsStore(defaults: fixture.defaults)
            settings.setEnabled(scenario == "analysis" || scenario == "analysisAndExport")
            settings.setExecutablePath("/bin/echo", for: .codex)
            let notifier = ResilienceProcessingNotifier()
            let appState = makeAppState(
                sessionManager: makeSessionManager(root: fixture.root.appendingPathComponent("Recordings")),
                captureCoordinator: CaptureCoordinator(
                    systemAudioCapture: ResilienceCaptureService(), microphoneCapture: ResilienceCaptureService()
                ),
                audioFinalizer: scenario == "audio" ? NotificationFailingFinalizer() : ResilienceAudioFinalizer(),
                fluidAudioModelManager: ResilienceFluidAudioModelManager(
                    modelsRoot: fixture.root.appendingPathComponent("Models"),
                    isTranscriptionReady: scenario != "model"
                ),
                sessionTranscriber: scenario == "transcriber" ? NotificationFailingTranscriber() : ResilienceSessionTranscriber(),
                processingFileService: scenario == "export" || scenario == "analysisAndExport" ? NotificationFailingExporter() : nil,
                monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
                defaults: fixture.defaults, processingNotifier: notifier
            )
            await appState.prepareStorage()
            await appState.setNotificationsEnabled(scenario != "disabled")
            appState.selectedAppLanguage = .slovak
            appState.meetingTitle = scenario
            await appState.startRecording()
            let session = try XCTUnwrap(appState.currentSession)
            await appState.stopRecording()
        await appState.waitForProcessing()
            await appState.stopRecording() // Repeated stop must not emit another result.
            if scenario == "disabled" {
                XCTAssertTrue(notifier.notifications.isEmpty)
                continue
            }
            XCTAssertEqual(notifier.notifications.count, 1, scenario)
            let notification = try XCTUnwrap(notifier.notifications.first)
            XCTAssertEqual(notification.failedSteps, expectedSteps, scenario)
            XCTAssertEqual(notification.succeeded, expectedSteps.isEmpty, scenario)
            XCTAssertEqual(notification.sessionID, session.metadata.id, scenario)
            XCTAssertEqual(notification.occurredAt.timeIntervalSince1970,
                           (session.metadata.startedAt ?? session.metadata.createdAt).timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(notification.language, .slovak)
            if scenario == "analysis" {
                XCTAssertNotNil(notification.markdownURL)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemAudioURL.path), scenario)
        }
    }

    func testAllApplicationLanguagesResolveToAConcreteLocalization() {
        XCTAssertEqual(AppLanguage.slovak.resolved, .slovak)
        XCTAssertEqual(AppLanguage.czech.resolved, .czech)
        XCTAssertEqual(AppLanguage.english.resolved, .english)
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
    }

    func testAudioRetentionSettingsPersistLegacyCleanupAndRetentionPolicy() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = AudioRetentionSettingsStore(defaults: fixture.defaults)
        XCTAssertFalse(store.automaticallyDeleteSourceCAF)
        XCTAssertEqual(store.policy, .keepForever)
        store.setAutomaticallyDeleteSourceCAF(true)
        store.setPolicy(.sevenDays)

        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            defaults: fixture.defaults
        )
        await appState.prepareStorage()

        XCTAssertTrue(appState.automaticallyDeleteSourceCAF)
        XCTAssertEqual(appState.audioRetentionPolicy, .sevenDays)
        appState.automaticallyDeleteSourceCAF = false
        appState.persistAudioRetentionSettings()
        await appState.setAudioRetentionPolicy(.thirtyDays)
        XCTAssertFalse(store.automaticallyDeleteSourceCAF)
        XCTAssertEqual(store.policy, .thirtyDays)
    }

    func testImmediateRetentionPurgesEligibleAudioDuringStoragePreparation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let manager = makeSessionManager(root: recordingsRoot)
        let session = try await manager.startSession(
            title: "Cleanup",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try Data(repeating: 1, count: 128).write(to: session.systemAudioURL)
        try Data(repeating: 2, count: 96).write(to: session.microphoneAudioURL)
        let transcript = makeTranscript(
            sessionID: session.metadata.id,
            title: session.metadata.title
        )
        try TranscriptJSONCoder.makeEncoder().encode(transcript)
            .write(to: session.mergedTranscriptURL)
        let markdownURL = session.directoryURL.appendingPathComponent("meeting.md")
        try Data("# Meeting".utf8).write(to: markdownURL)
        let completed = try await manager.stopSession(
            now: Date(timeIntervalSince1970: 1_700_000_060),
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "test",
                systemSegmentCount: 1,
                microphoneSegmentCount: 1,
                mergedSegmentCount: 1,
                warnings: [],
                failureReason: nil
            ),
            output: SessionOutputMetadata(
                status: .completed,
                markdownFileName: markdownURL.lastPathComponent,
                markdownPath: markdownURL.path,
                exportedAt: Date(timeIntervalSince1970: 1_700_000_060),
                failureReason: nil
            )
        )
        AudioRetentionSettingsStore(defaults: fixture.defaults).setPolicy(.immediately)
        let appState = makeAppState(
            sessionManager: manager,
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()

        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.systemAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.microphoneAudioURL.path))
        let metadata = try decodeMetadata(at: completed.manifestURL)
        XCTAssertEqual(metadata.recordingAudioRetention?.cleanupStatus, .purged)
        XCTAssertEqual(metadata.recordingAudioRetention?.cleanupTrigger, .automatic)
    }

    func testSelectedLanguageIsRestoredAndStoredInNewSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        TranscriptionSettingsStore(defaults: fixture.defaults).setSelectedLanguage(.czech)
        let applicationSettings = ApplicationSettingsStore(defaults: fixture.defaults)
        applicationSettings.setOutputLanguage(.english)
        applicationSettings.setMarkdownFileNameTemplate("{date} - {title} - {id}")

        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(modelsRoot: modelsRoot),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        XCTAssertEqual(appState.selectedTranscriptionLanguage, .czech)
        XCTAssertEqual(appState.selectedOutputLanguage, .english)
        XCTAssertEqual(appState.markdownFileNameTemplate, "{date} - {title} - {id}")
        XCTAssertTrue(appState.canEditSessionConfiguration)

        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        XCTAssertFalse(appState.canEditSessionConfiguration)
        XCTAssertEqual(session.metadata.language, .czech)
        XCTAssertEqual(session.metadata.resolvedOutputLanguage, .english)
        XCTAssertEqual(
            session.metadata.resolvedOutputFileNameTemplate,
            "{date} - {title} - {id}"
        )
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.language, .czech)
        XCTAssertEqual(persisted.resolvedOutputLanguage, .english)

        await appState.stopRecording()
        await appState.waitForProcessing()
        XCTAssertNotEqual(appState.status, .recording)
        XCTAssertTrue(appState.canEditSessionConfiguration)
    }

    func testPreRecordingNotesDraftStartsSessionAndClearsAfterStop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        appState.meetingNotesDraft = "Pre-recording agenda"
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)

        XCTAssertEqual(try String(contentsOf: session.notesURL, encoding: .utf8), "Pre-recording agenda")
        XCTAssertEqual(appState.currentMeetingNotes, "Pre-recording agenda")

        await appState.stopRecording()
        await appState.waitForProcessing()

        XCTAssertEqual(appState.meetingNotesDraft, "")
        XCTAssertEqual(try String(contentsOf: session.notesURL, encoding: .utf8), "Pre-recording agenda")
    }

    func testCaptureStartIsRecordedAfterSuccessfulStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let captureStartedAt = Date().addingTimeInterval(4)
        let capture = ResilienceCaptureService(startedAt: captureStartedAt)
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: capture,
                microphoneCapture: capture
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        let recordedCaptureStart = try XCTUnwrap(appState.captureStartedAt)

        XCTAssertEqual(appState.captureStartedAt, captureStartedAt)
        XCTAssertGreaterThanOrEqual(recordedCaptureStart, session.metadata.startedAt ?? .distantPast)

        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testMeetingNotesTimestampIsMeasuredFromCaptureStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let captureStartedAt = Date().addingTimeInterval(4)
        let capture = ResilienceCaptureService(startedAt: captureStartedAt)
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: capture,
                microphoneCapture: capture
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        try XCTUnwrap(appState.currentSession)

        XCTAssertEqual(
            appState.meetingNotesTimestampLinePrefix(at: captureStartedAt.addingTimeInterval(30)),
            "- [00:00:30] "
        )

        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testMeetingNotesTimestampFallsBackToSessionStartBeforeCaptureStartCompletes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let systemCapture = SuspendedResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )
        await appState.prepareStorage()

        XCTAssertNil(appState.meetingNotesTimestampLinePrefix())
        let startTask = Task { await appState.startRecording() }
        await systemCapture.waitUntilStarted()
        let session = try XCTUnwrap(appState.currentSession)
        let sessionStartedAt = try XCTUnwrap(session.metadata.startedAt)

        XCTAssertEqual(
            appState.meetingNotesTimestampLinePrefix(at: sessionStartedAt),
            "- [00:00:00] "
        )

        await systemCapture.releaseStart()
        await startTask.value
        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testCaptureStartDoesNotSurviveIntoFollowingSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let firstCaptureStartedAt = Date().addingTimeInterval(4)
        let secondCaptureStartedAt = firstCaptureStartedAt.addingTimeInterval(60)
        let capture = ResilienceCaptureService(startedAt: firstCaptureStartedAt)
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: capture,
                microphoneCapture: capture
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )
        await appState.prepareStorage()

        await appState.startRecording()
        XCTAssertEqual(appState.captureStartedAt, firstCaptureStartedAt)
        await appState.stopRecording()
        await appState.waitForProcessing()
        XCTAssertNil(appState.captureStartedAt)

        await capture.setStartedAt(secondCaptureStartedAt)
        await appState.startRecording()
        XCTAssertEqual(appState.captureStartedAt, secondCaptureStartedAt)

        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testFlushMeetingNotesPersistsLatestTextBeforeStop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)

        await appState.updateMeetingNotes("First agenda")
        await appState.flushMeetingNotes()
        await appState.updateMeetingNotes("Latest agenda")
        await appState.flushMeetingNotes()

        XCTAssertEqual(try String(contentsOf: session.notesURL, encoding: .utf8), "Latest agenda")
        XCTAssertEqual(appState.currentMeetingNotes, "Latest agenda")
        XCTAssertEqual(appState.meetingNotesDraft, "Latest agenda")

        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testFlushMeetingNotesDeletesEmptiedEditorContent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        appState.meetingNotesDraft = "Remove me"
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        appState.meetingNotesDraft = ""

        await appState.flushMeetingNotes()

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.notesURL.path))
        XCTAssertNil(appState.currentSession?.metadata.notes)
        XCTAssertNil(try decodeMetadata(at: session.manifestURL).notes)
        XCTAssertEqual(appState.currentMeetingNotes, "")

        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testFailedNotesWriteKeepsDraftAndSetsError() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        try FileManager.default.createDirectory(
            at: session.notesURL,
            withIntermediateDirectories: false
        )

        await appState.updateMeetingNotes("Preserved agenda")

        XCTAssertEqual(appState.meetingNotesDraft, "Preserved agenda")
        XCTAssertEqual(appState.currentMeetingNotes, "Preserved agenda")
        XCTAssertNotNil(appState.lastError)
    }

    func testCurrentMeetingNotesReturnsDraftWithoutDiskAccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        appState.meetingNotesDraft = "Editor draft"
        try "Different disk content".write(to: session.notesURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(appState.currentMeetingNotes, "Editor draft")
    }

    func testLoadMeetingNotesFromDiskRespectsExistingDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        await appState.updateMeetingNotes("Persisted agenda")
        appState.meetingNotesDraft = ""

        await appState.loadMeetingNotesFromDisk()

        XCTAssertEqual(appState.meetingNotesDraft, "Persisted agenda")

        appState.meetingNotesDraft = "Local draft"
        try "Different disk content".write(to: session.notesURL, atomically: true, encoding: .utf8)

        await appState.loadMeetingNotesFromDisk()

        XCTAssertEqual(appState.meetingNotesDraft, "Local draft")
    }

    func testUpdateMeetingNotesDoesNotLogPerSave() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)

        await appState.updateMeetingNotes("First")
        await appState.updateMeetingNotes("Second")
        await appState.updateMeetingNotes("Third")
        await appState.flushMeetingNotes()

        let log = try String(contentsOf: session.processingLogURL, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: #""event":"noteSaved""#).count - 1, 1)

        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testOnboardingTestSessionIgnoresNotesAndPreservesDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        appState.meetingNotesDraft = "Preserved agenda"
        await appState.startOnboardingTest()
        let session = try XCTUnwrap(appState.currentSession)

        XCTAssertNil(session.metadata.notes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.notesURL.path))
        XCTAssertEqual(appState.meetingNotesDraft, "Preserved agenda")

        await appState.stopOnboardingTest()
        await appState.waitForProcessing()
    }

    func testPrepareStorageRunsInitializationOnlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let analysisRunner = CountingResilienceAnalysisCommandRunner()
        AnalysisSettingsStore(defaults: fixture.defaults).setEnabled(true)
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            analysisCommandRunner: analysisRunner,
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.prepareStorage()

        let runCount = await analysisRunner.runCount()
        XCTAssertEqual(runCount, 2)
        XCTAssertEqual(appState.status, .idle)
        XCTAssertEqual(appState.fluidAudioModelState.asrStatus, .missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("Models/FluidAudio/.staging", isDirectory: true).path))
    }

    func testDisabledAnalysisDoesNotLaunchAnyExternalCommand() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let runner = CountingResilienceAnalysisCommandRunner()
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            analysisCommandRunner: runner,
            defaults: fixture.defaults
        )

        await appState.prepareStorage()

        XCTAssertFalse(appState.aiAnalysisEnabled)
        let runCount = await runner.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testPrepareStorageTreatsMissingAnalysisToolAsNonfatal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let analysisSettings = AnalysisSettingsStore(defaults: fixture.defaults)
        analysisSettings.setEnabled(true)
        analysisSettings.setExecutablePath("/missing/codex", for: .codex)
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()

        XCTAssertEqual(appState.status, .idle)
        XCTAssertEqual(appState.analysisToolStatus, .unavailable)
    }

    func testPrepareStorageReportsMissingCLIAuthentication() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let analysisSettings = AnalysisSettingsStore(defaults: fixture.defaults)
        analysisSettings.setEnabled(true)
        analysisSettings.setExecutablePath("/bin/echo", for: .codex)
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            analysisCommandRunner: SignedOutResilienceAnalysisCommandRunner(),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()

        XCTAssertEqual(
            appState.analysisToolStatus,
            .authenticationRequired(
                path: "/bin/echo",
                version: "codex-test 1.0",
                loginCommand: "'/bin/echo' login"
            )
        )
    }

    func testCompletedMeetingUsesSnapshottedCLIPromptAndExportsFreeformMarkdown() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let settings = AnalysisSettingsStore(defaults: fixture.defaults)
        settings.setEnabled(true)
        settings.setTool(.codex)
        settings.setExecutablePath("/bin/echo", for: .codex)
        settings.setPrompt("Create a custom section for {{meeting_title}} in {{output_language}}.")
        let runner = SuccessfulResilienceAnalysisCommandRunner(
            markdown: "## Vlastný výstup\n\nAnalýza bola vytvorená."
        )
        let notifier = ResilienceProcessingNotifier()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            analysisCommandRunner: runner,
            defaults: fixture.defaults,
            processingNotifier: notifier
        )

        await appState.prepareStorage()
        await appState.setNotificationsEnabled(true)
        appState.meetingTitle = "Prompt snapshot"
        await appState.startRecording()
        let activeSession = try XCTUnwrap(appState.currentSession)
        XCTAssertEqual(
            activeSession.metadata.analysisConfiguration?.prompt,
            "Create a custom section for {{meeting_title}} in {{output_language}}."
        )
        appState.analysisPrompt = "This later edit must not affect the active meeting."
        appState.persistAnalysisSettings()
        await appState.stopRecording()
        await appState.waitForProcessing()

        XCTAssertEqual(appState.status, .idle)
        let completed = try XCTUnwrap(appState.lastCompletedSession)
        XCTAssertEqual(completed.metadata.analysis?.status, .completed)
        XCTAssertEqual(completed.metadata.analysis?.provider, "codex")
        let artifact = try JSONDecoder().decode(
            AIAnalysisArtifact.self,
            from: Data(contentsOf: completed.analysisURL)
        )
        XCTAssertEqual(artifact.markdown, "## Vlastný výstup\n\nAnalýza bola vytvorená.")
        XCTAssertEqual(
            artifact.prompt,
            "Create a custom section for Prompt snapshot in "
                + "Slovak (slovenčina, ISO 639-1: sk)."
        )
        let markdownURL = try XCTUnwrap(appState.lastMarkdownURL)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Vlastný výstup"))
        XCTAssertTrue(markdown.contains(#""ai analysis": "#))
        let analysisInputs = await runner.analysisInputs()
        XCTAssertEqual(analysisInputs.count, 1)
        XCTAssertTrue(analysisInputs[0].contains(
            "Create a custom section for Prompt snapshot in "
                + "Slovak (slovenčina, ISO 639-1: sk)."
        ))
        XCTAssertTrue(analysisInputs[0].contains(
            "Write every part of the `markdown` value in "
                + "Slovak (slovenčina, ISO 639-1: sk)."
        ))
        XCTAssertFalse(analysisInputs[0].contains("This later edit"))
        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertTrue(notifier.notifications[0].succeeded)
    }

    func testManualAIAnalysisUsesCurrentSettingsAndUpdatesExistingRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let sessionDirectory = recordingsRoot.appendingPathComponent(
            "manual-analysis",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        let markdownURL = fixture.root.appendingPathComponent("manual-analysis.md")
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = SessionMetadata(
            id: "manual-analysis",
            title: "Existing meeting",
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "test-model",
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(60),
                systemSegmentCount: 1,
                microphoneSegmentCount: 0,
                warnings: [],
                failureReason: nil
            ),
            output: SessionOutputMetadata(
                status: .completed,
                markdownFileName: markdownURL.lastPathComponent,
                markdownPath: markdownURL.path,
                exportedAt: startedAt.addingTimeInterval(60),
                failureReason: nil
            )
        )
        let session = RecordingSession(metadata: metadata, directoryURL: sessionDirectory)
        let transcript = makeTranscript(sessionID: metadata.id, title: metadata.title)
        try TranscriptJSONCoder.makeEncoder().encode(transcript).write(
            to: session.mergedTranscriptURL,
            options: .atomic
        )
        let sourceBlocks = SourceConversationBlockGrouper().group(
            transcript: transcript,
            sourceFingerprint: "test-source-blocks"
        )
        try TranscriptJSONCoder.makeEncoder().encode(sourceBlocks).write(
            to: session.utteranceTranscriptURL,
            options: .atomic
        )
        try SessionJSONCoder.makeEncoder().encode(metadata).write(
            to: session.manifestURL,
            options: .atomic
        )
        try Data(
            MarkdownRenderer().render(session: metadata, transcript: transcript).utf8
        ).write(to: markdownURL, options: .atomic)

        let settings = AnalysisSettingsStore(defaults: fixture.defaults)
        settings.setEnabled(false)
        settings.setTool(.codex)
        settings.setExecutablePath("/bin/echo", for: .codex)
        settings.setPrompt("Analyze {{meeting_title}} with the current prompt.")
        let runner = SuccessfulResilienceAnalysisCommandRunner(
            markdown: "## Nová analýza\n\nAktualizovaný výsledok."
        )
        let notifier = ResilienceProcessingNotifier()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            analysisCommandRunner: runner,
            defaults: fixture.defaults,
            processingNotifier: notifier
        )
        await appState.prepareStorage()
        await appState.setNotificationsEnabled(true)

        let updatedMarkdownURL = try await appState.reanalyze(session: session)

        XCTAssertEqual(updatedMarkdownURL, markdownURL)
        XCTAssertNil(appState.aiAnalysisReprocessingSessionID)
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.analysis?.status, .completed)
        XCTAssertEqual(
            persisted.analysisConfiguration?.prompt,
            "Analyze {{meeting_title}} with the current prompt."
        )
        let artifact = try JSONDecoder().decode(
            AIAnalysisArtifact.self,
            from: Data(contentsOf: session.analysisURL)
        )
        XCTAssertEqual(artifact.prompt, "Analyze Existing meeting with the current prompt.")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Nová analýza"))
        XCTAssertTrue(markdown.contains("Recovered transcript text"))
        XCTAssertFalse(markdown.contains("AI analýza zatiaľ nebola vytvorená"))
        let analysisInputs = await runner.analysisInputs()
        XCTAssertEqual(analysisInputs.count, 1)
        XCTAssertTrue(analysisInputs[0].contains("[00:00:00]"))
        XCTAssertFalse(analysisInputs[0].contains("[segment-000000]"))
        XCTAssertFalse(analysisInputs[0].contains("[source-block-000000]"))
        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertTrue(try XCTUnwrap(notifier.notifications.first).succeeded)
        _ = try await appState.reanalyze(session: session)
        XCTAssertEqual(notifier.notifications.count, 2)
        XCTAssertNotEqual(notifier.notifications.first?.id, notifier.notifications.last?.id)
    }

    func testCompletedMeetingWithoutTranscriptSegmentsSkipsCLIAnalysis() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let settings = AnalysisSettingsStore(defaults: fixture.defaults)
        settings.setEnabled(true)
        settings.setExecutablePath("/bin/echo", for: .codex)
        let runner = CountingResilienceAnalysisCommandRunner()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: EmptyResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            analysisCommandRunner: runner,
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        let runsAfterAvailabilityCheck = await runner.runCount()
        await appState.startRecording()
        await appState.stopRecording()
        await appState.waitForProcessing()

        XCTAssertEqual(appState.status, .idle)
        XCTAssertNil(appState.lastCompletedSession?.metadata.analysis)
        let finalRunCount = await runner.runCount()
        XCTAssertEqual(finalRunCount, runsAfterAvailabilityCheck)
    }

    func testAppStateRecoversInterruptedSessionFromMergedTranscriptEndToEnd() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let sessionDirectory = recordingsRoot.appendingPathComponent("crashed-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let metadata = SessionMetadata(
            id: "crashed-session",
            title: "Recovered meeting",
            status: .recording,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = RecordingSession(metadata: metadata, directoryURL: sessionDirectory)
        try SessionJSONCoder.makeEncoder().encode(metadata)
            .write(to: session.manifestURL, options: .atomic)
        let transcript = makeTranscript(sessionID: metadata.id, title: metadata.title)
        try TranscriptJSONCoder.makeEncoder().encode(transcript)
            .write(to: session.mergedTranscriptURL, options: .atomic)

        let notifier = ResilienceProcessingNotifier()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(modelsRoot: modelsRoot),
            defaults: fixture.defaults,
            processingNotifier: notifier
        )

        await appState.prepareStorage()
        XCTAssertTrue(notifier.notifications.isEmpty)
        await appState.setNotificationsEnabled(true)
        let candidate = try XCTUnwrap(appState.recoveryCandidates.first)
        await appState.recoverSession(candidate)
        await appState.waitForProcessing()

        XCTAssertEqual(appState.status, .idle)
        XCTAssertTrue(appState.recoveryCandidates.isEmpty)
        let markdownURL = try XCTUnwrap(appState.lastMarkdownURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Recovered transcript text"))
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.status, .recorded)
        XCTAssertEqual(persisted.recovery?.status, .completed)
        XCTAssertEqual(persisted.recovery?.attemptCount, 1)
        XCTAssertEqual(persisted.output?.status, .completed)
        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertTrue(notifier.notifications[0].succeeded)
        let log = try String(contentsOf: session.processingLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains(#""event":"recoveryCompleted""#))
    }

    func testMarkdownExportDoesNotBlockMainActorDuringRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let sessionDirectory = recordingsRoot.appendingPathComponent("background-export", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let metadata = SessionMetadata(
            id: "background-export",
            title: "Background export",
            status: .recording,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = RecordingSession(metadata: metadata, directoryURL: sessionDirectory)
        try SessionJSONCoder.makeEncoder().encode(metadata)
            .write(to: session.manifestURL, options: .atomic)
        try TranscriptJSONCoder.makeEncoder().encode(
            makeTranscript(sessionID: metadata.id, title: metadata.title)
        ).write(to: session.mergedTranscriptURL, options: .atomic)

        let gate = BlockingFileServiceGate()
        let fileService = BlockingExportProcessingFileService(gate: gate)
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            processingFileService: fileService,
            defaults: fixture.defaults
        )
        await appState.prepareStorage()
        let candidate = try XCTUnwrap(appState.recoveryCandidates.first)

        let recoveryTask = Task { await appState.recoverSession(candidate) }
        let didReachBackgroundExport = await gate.waitUntilBlocked()

        XCTAssertTrue(didReachBackgroundExport)
        XCTAssertEqual(appState.status, .idle)
        XCTAssertEqual(appState.processingJobs.first?.metadata.processing?.stage, .exporting)
        gate.release()
        await recoveryTask.value
        await appState.waitForProcessing()
        XCTAssertEqual(appState.status, .idle)
    }

    func testConcurrentStartCallsShareOneRecordingOperation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let systemCapture = SuspendedResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )
        await appState.prepareStorage()

        let firstStart = Task { await appState.startRecording() }
        await systemCapture.waitUntilStarted()
        let secondStart = Task { await appState.startRecording() }
        await Task.yield()

        XCTAssertEqual(appState.status, .preparing)
        await systemCapture.releaseStart()
        await firstStart.value
        await secondStart.value

        let startCount = await systemCapture.startCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(appState.status, .recording)
        XCTAssertNil(appState.lastError)
        await appState.stopRecording()
        await appState.waitForProcessing()
    }

    func testConcurrentStopCallsShareOneProcessingOperation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let systemCapture = ResilienceCaptureService()
        let gate = BlockingFileServiceGate()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: ResilienceSessionTranscriber(),
            processingFileService: BlockingExportProcessingFileService(gate: gate),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )
        await appState.prepareStorage()
        await appState.startRecording()

        let firstStop = Task { await appState.stopRecording() }
        let didReachExport = await gate.waitUntilBlocked()
        XCTAssertTrue(didReachExport)
        let secondStop = Task { await appState.stopRecording() }
        await Task.yield()

        let stopCountBeforeRelease = await systemCapture.stopCount()
        XCTAssertEqual(stopCountBeforeRelease, 1)
        gate.release()
        await firstStop.value
        await secondStop.value
        await appState.waitForProcessing()

        let stopCount = await systemCapture.stopCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(appState.status, .idle)
        XCTAssertFalse(appState.lastError?.contains("Invalid state transition") == true)
    }

    func testRequiredSystemCaptureFailureTriggersSafeAutomaticStop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let systemCapture = ResilienceCaptureService()
        let microphoneCapture = ResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: microphoneCapture
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1_000
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        XCTAssertEqual(appState.status, .recording)
        let session = try XCTUnwrap(appState.currentSession)

        await systemCapture.fail(reason: "Simulated required capture failure")
        try await waitUntil { appState.status != .recording }
        try await waitUntil { appState.currentSession == nil }
        await appState.waitForProcessing()

        XCTAssertEqual(appState.status, .idle)
        XCTAssertEqual(
            appState.lastError,
            AppLocalization.message(
                .captureFailedSafeStop,
                language: appState.selectedAppLanguage
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.systemAudio?.failureReason, "Simulated required capture failure")
        XCTAssertEqual(persisted.output?.status, .completed)
    }

    func testCancelledLowStorageCheckDoesNotStopRecordingTwice() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let storageCheck = SuspendedLowStorageCheck()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1
            ),
            storageStatusProvider: { await storageCheck.status() },
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        await storageCheck.waitUntilRequested()

        let stopTask = Task { await appState.stopRecording() }
        try await waitUntil { appState.status != .recording }
        await storageCheck.resume()
        await stopTask.value
        try await waitUntil { appState.currentSession == nil }
        await appState.waitForProcessing()

        XCTAssertEqual(appState.status, .idle)
        XCTAssertFalse(appState.lastError?.contains("Invalid state transition") == true)
    }

    func testRepeatedStorageCheckFailuresTriggerSafeAutomaticStop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let failureCounter = StorageFailureCounter()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1,
                maximumStorageCheckFailures: 2
            ),
            storageStatusProvider: {
                await failureCounter.increment()
                throw StorageCheckTestError.unavailable
            },
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        try await waitUntil { appState.status != .recording }
        try await waitUntil { appState.currentSession == nil }
        await appState.waitForProcessing()

        XCTAssertEqual(appState.status, .idle)
        let failureCount = await failureCounter.value
        XCTAssertGreaterThanOrEqual(failureCount, 2)
        XCTAssertEqual(
            appState.lastError,
            AppLocalization.message(
                .storageCheckFailedSafeStop,
                language: appState.selectedAppLanguage
            )
        )
    }

    func testTransientSystemAudioStallRecoversWithoutStoppingRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let systemCapture = ResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1_000,
                stalledSystemAudioCheckCount: 20
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        await systemCapture.stall()
        try await waitUntil { appState.captureDiagnostics.systemAudio.health() == .stalled }

        await systemCapture.resumeBuffers()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(appState.status, .recording)
        await appState.stopRecording()
        await appState.waitForProcessing()
        XCTAssertEqual(appState.status, .idle)
    }

    func testPersistentSystemAudioStallTriggersSafeAutomaticStop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let systemCapture = ResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: modelsRoot,
                isTranscriptionReady: true
            ),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1_000,
                stalledSystemAudioCheckCount: 2
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        await systemCapture.stall()
        try await waitUntil { appState.status != .recording }
        try await waitUntil { appState.currentSession == nil }
        await appState.waitForProcessing()

        XCTAssertEqual(appState.status, .idle)
        XCTAssertEqual(
            appState.lastError,
            AppLocalization.message(
                .captureStalledSafeStop,
                language: appState.selectedAppLanguage
            )
        )
        let log = try String(contentsOf: session.processingLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains(#""event":"captureFailed""#))
        XCTAssertFalse(log.contains("System audio capture stopped producing buffers."))
    }

    func testLiveCaptureDiagnosticsDoNotInvalidateCompleteAppState() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            defaults: fixture.defaults
        )

        var appStateChangeCount = 0
        let appStateObservation = appState.objectWillChange.sink {
            appStateChangeCount += 1
        }
        defer { appStateObservation.cancel() }

        var diagnostics = CaptureSessionDiagnostics.empty
        for bufferCount in 1...1_000 {
            diagnostics.systemAudio.bufferCount = bufferCount
            appState.captureDiagnosticsModel.update(diagnostics)
        }

        XCTAssertEqual(appStateChangeCount, 0)
        XCTAssertEqual(appState.captureDiagnostics.systemAudio.bufferCount, 1_000)
    }

    private func makeSessionManager(root: URL) -> SessionManager {
        SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(
                provider: AppStateCapacityProvider(),
                minimumBytes: 1
            )
        )
    }

    private func makeAppState(
        sessionManager: SessionManager,
        captureCoordinator: CaptureCoordinator = CaptureCoordinator(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        fluidAudioModelManager: any FluidAudioModelManaging,
        sessionTranscriber: any SessionTranscribing = SessionTranscriber(),
        processingFileService: (any ProcessingFileServicing)? = nil,
        monitoring: CaptureMonitoringConfiguration = CaptureMonitoringConfiguration(),
        storageStatusProvider: (@Sendable () async throws -> StorageStatus)? = nil,
        analysisCommandRunner: any AnalysisCommandRunning = ResilienceAnalysisCommandRunner(),
        defaults: UserDefaults,
        processingNotifier: any ProcessingNotifying = ProcessingNotificationService()
    ) -> AppState {
        let applicationSettingsStore = ApplicationSettingsStore(defaults: defaults)
        applicationSettingsStore.setMinimumStorageBytes(1)
        let analysisSettingsStore = AnalysisSettingsStore(defaults: defaults)
        if analysisSettingsStore.executablePath(for: .codex).isEmpty {
            analysisSettingsStore.setExecutablePath("/bin/echo", for: .codex)
        }
        return AppState(
            sessionManager: sessionManager,
            captureCoordinator: captureCoordinator,
            audioFinalizer: audioFinalizer,
            fluidAudioModelManager: fluidAudioModelManager,
            sessionTranscriber: sessionTranscriber,
            processingFileService: processingFileService,
            outputFolderStore: OutputFolderStore(defaults: defaults),
            analysisSettingsStore: analysisSettingsStore,
            analysisCommandRunner: analysisCommandRunner,
            transcriptionSettingsStore: TranscriptionSettingsStore(defaults: defaults),
            audioRetentionSettingsStore: AudioRetentionSettingsStore(defaults: defaults),
            applicationSettingsStore: applicationSettingsStore,
            captureMonitoringConfiguration: monitoring,
            storageStatusProvider: storageStatusProvider,
            processingNotifier: processingNotifier,
            notificationDefaults: defaults,
            resourceMonitoringEnabled: false
        )
    }

    private func makeFixture() throws -> ResilienceTestFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeAppStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "MeetingScribeAppStateTests.\(UUID().uuidString)"
        return ResilienceTestFixture(
            root: root,
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            suiteName: suiteName
        )
    }

    private func makeTranscript(sessionID: String, title: String) -> MergedTranscript {
        MergedTranscript(
            sessionID: sessionID,
            title: title,
            completedAt: Date(timeIntervalSince1970: 1_700_000_010),
            tracks: [],
            segments: [
                TranscriptSegment(
                    id: "segment-000000",
                    source: .system,
                    speaker: "Other",
                    start: 0,
                    end: 1,
                    language: "sk",
                    text: "Recovered transcript text",
                    confidence: nil
                ),
            ]
        )
    }

    private func decodeMetadata(at url: URL) throws -> SessionMetadata {
        try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: Data(contentsOf: url))
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for AppState transition.")
    }
}

private enum StorageCheckTestError: Error {
    case unavailable
}

private actor StorageFailureCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor BlockingExportProcessingFileService: ProcessingFileServicing {
    private let delegate = ProcessingFileService()
    private let gate: BlockingFileServiceGate

    init(gate: BlockingFileServiceGate) {
        self.gate = gate
    }

    func loadRecoveredArtifacts(
        from session: RecordingSession
    ) async -> RecoveredProcessingArtifacts? {
        await delegate.loadRecoveredArtifacts(from: session)
    }

    func loadUserNotes(from session: RecordingSession) async -> String? {
        await delegate.loadUserNotes(from: session)
    }

    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws {
        try await delegate.persistAnalysis(analysis, to: url)
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        analysis: AIAnalysisArtifact?,
        notes: String?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        gate.block()
        return try await delegate.exportMarkdown(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            analysis: analysis,
            notes: notes,
            to: directoryURL
        )
    }
}

private final class BlockingFileServiceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    func block() {
        condition.lock()
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<500 {
            if blockedStatus() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private func blockedStatus() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor SuspendedLowStorageCheck {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var statusContinuation: CheckedContinuation<StorageStatus, Never>?
    private var wasRequested = false

    func status() async -> StorageStatus {
        wasRequested = true
        requestContinuation?.resume()
        requestContinuation = nil
        return await withCheckedContinuation { continuation in
            statusContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        guard !wasRequested else { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func resume() {
        statusContinuation?.resume(
            returning: StorageStatus(availableBytes: 0, requiredBytes: 1)
        )
        statusContinuation = nil
    }
}

private struct ResilienceTestFixture {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ResilienceFluidAudioModelManager: FluidAudioModelManaging {
    private let modelsRoot: URL
    private var isTranscriptionReady: Bool

    init(modelsRoot: URL, isTranscriptionReady: Bool = false) {
        self.modelsRoot = modelsRoot.appendingPathComponent("FluidAudio", isDirectory: true)
        self.isTranscriptionReady = isTranscriptionReady
    }

    func prepareStorage() throws {
        try FileManager.default.createDirectory(
            at: modelsRoot.appendingPathComponent(".staging", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func status(for descriptor: FluidAudioModelDescriptor) -> FluidAudioModelStatus {
        guard descriptor.kind == .transcription, isTranscriptionReady else { return .missing }
        return .ready(
            bundleURL: modelsRoot.appendingPathComponent(
                descriptor.installationFolderName,
                isDirectory: true
            ),
            sizeBytes: descriptor.approximateSizeBytes
        )
    }

    func validateInstalledModel(_ descriptor: FluidAudioModelDescriptor) throws -> URL {
        modelsRoot.appendingPathComponent(descriptor.installationFolderName, isDirectory: true)
    }

    func install(
        _ descriptor: FluidAudioModelDescriptor,
        repair: Bool,
        progress: @escaping @Sendable (FluidAudioModelDownloadProgress) -> Void
    ) throws -> URL {
        isTranscriptionReady = descriptor.kind == .transcription
        progress(.init(
            fractionCompleted: 1,
            downloadedBytes: descriptor.approximateSizeBytes,
            totalBytes: descriptor.approximateSizeBytes
        ))
        return modelsRoot.appendingPathComponent(descriptor.installationFolderName, isDirectory: true)
    }

    func importBundle(
        from sourceBundleURL: URL,
        as descriptor: FluidAudioModelDescriptor
    ) throws -> URL {
        isTranscriptionReady = descriptor.kind == .transcription
        return modelsRoot.appendingPathComponent(descriptor.installationFolderName, isDirectory: true)
    }

    func removeModel(_ descriptor: FluidAudioModelDescriptor) {
        if descriptor.kind == .transcription { isTranscriptionReady = false }
    }
}

private struct AppStateCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 { 2_000_000_000 }
}

private actor ResilienceAnalysisCommandRunner: AnalysisCommandRunning {
    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        AnalysisCommandResult(
            exitCode: 0,
            standardOutput: Data("\(tool.displayName) test".utf8),
            standardError: Data()
        )
    }
}

@MainActor
private final class ResilienceProcessingNotifier: ProcessingNotifying {
    private(set) var authorizationRequests = 0
    private(set) var notifications: [ProcessingNotification] = []

    func requestAuthorization() async {
        authorizationRequests += 1
    }

    func send(_ notification: ProcessingNotification) async {
        notifications.append(notification)
    }
}

private actor CountingResilienceAnalysisCommandRunner: AnalysisCommandRunning {
    private var runs = 0

    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        runs += 1
        return AnalysisCommandResult(
            exitCode: 0,
            standardOutput: Data("\(tool.displayName) test".utf8),
            standardError: Data()
        )
    }

    func runCount() -> Int { runs }
}

private actor SignedOutResilienceAnalysisCommandRunner: AnalysisCommandRunning {
    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        if command.arguments == ["--version"] {
            return AnalysisCommandResult(
                exitCode: 0,
                standardOutput: Data("codex-test 1.0".utf8),
                standardError: Data()
            )
        }
        return AnalysisCommandResult(
            exitCode: 1,
            standardOutput: Data(),
            standardError: Data()
        )
    }
}

private actor SuccessfulResilienceAnalysisCommandRunner: AnalysisCommandRunning {
    private let markdown: String
    private var inputs: [String] = []

    init(markdown: String) {
        self.markdown = markdown
    }

    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        if command.arguments == ["--version"] {
            return AnalysisCommandResult(
                exitCode: 0,
                standardOutput: Data("codex-test 1.0".utf8),
                standardError: Data()
            )
        }
        if command.arguments == ["login", "status"] {
            return AnalysisCommandResult(
                exitCode: 0,
                standardOutput: Data("Logged in".utf8),
                standardError: Data()
            )
        }
        inputs.append(String(decoding: command.standardInput, as: UTF8.self))
        let response = try JSONEncoder().encode(AnalysisMarkdown(markdown: markdown))
        if let index = command.arguments.firstIndex(of: "--output-last-message") {
            try response.write(
                to: URL(fileURLWithPath: command.arguments[index + 1]),
                options: .atomic
            )
        }
        return AnalysisCommandResult(
            exitCode: 0,
            standardOutput: Data(),
            standardError: Data()
        )
    }

    func analysisInputs() -> [String] { inputs }
}

private actor ResilienceCaptureService: AudioCaptureService {
    private var current = AudioCaptureDiagnostics.empty
    private var starts = 0
    private var stops = 0
    private var startedAtOverride: Date?

    init(startedAt: Date? = nil) {
        self.startedAtOverride = startedAt
    }

    func start(outputURL: URL) async throws {
        starts += 1
        try Data("preserved mock audio".utf8).write(to: outputURL, options: .atomic)
        current = AudioCaptureDiagnostics(
            fileName: outputURL.lastPathComponent,
            startedAt: startedAtOverride ?? Date()
        )
        current.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 1,
            presentationTimestamp: 0
        )
    }

    func stop() async -> AudioCaptureDiagnostics {
        stops += 1
        return current
    }
    func diagnostics() async -> AudioCaptureDiagnostics { current }
    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }

    func fail(reason: String) {
        current.failureReason = reason
    }

    func stall() {
        current.lastBufferReceivedAt = Date().addingTimeInterval(-20)
    }

    func setStartedAt(_ startedAt: Date?) {
        startedAtOverride = startedAt
    }

    func resumeBuffers() {
        current.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 1,
            presentationTimestamp: current.lastPresentationTimestamp ?? 0
        )
    }
}

private actor SuspendedResilienceCaptureService: AudioCaptureService {
    private var current = AudioCaptureDiagnostics.empty
    private var starts = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func start(outputURL: URL) async throws {
        starts += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        try Data("preserved mock audio".utf8).write(to: outputURL, options: .atomic)
        current = AudioCaptureDiagnostics(
            fileName: outputURL.lastPathComponent,
            startedAt: Date()
        )
    }

    func stop() async -> AudioCaptureDiagnostics { current }
    func diagnostics() async -> AudioCaptureDiagnostics { current }

    func waitUntilStarted() async {
        guard starts == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func startCount() -> Int { starts }
}

private struct ResilienceAudioFinalizer: AudioFinalizing {
    func finalize(
        session: RecordingSession,
        diagnostics: CaptureSessionDiagnostics
    ) async throws -> AudioFinalizationMetadata {
        AudioFinalizationMetadata(
            completedAt: Date(),
            timelineOrigin: 0,
            system: FinalizedAudioTrackMetadata(
                fileName: session.systemWorkingAudioURL.lastPathComponent,
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 1_600,
                durationSeconds: 0.1,
                timelineOffsetSeconds: 0
            ),
            microphone: nil,
            warnings: []
        )
    }
}

private actor ResilienceSessionTranscriber: SessionTranscribing {
    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
        let segment = TranscriptSegment(
            id: "segment-000000",
            source: .system,
            speaker: "Other",
            start: 0,
            end: 0.1,
            language: "sk",
            text: "Safely stopped transcript",
            confidence: nil
        )
        let track = TrackTranscript(
            source: .system,
            model: model.provenance.model,
            requestedLanguage: language,
            detectedLanguage: "sk",
            completedAt: Date(),
            segments: [segment]
        )
        let merged = MergedTranscript(
            sessionID: session.metadata.id,
            title: session.metadata.title,
            completedAt: Date(),
            tracks: [],
            segments: [segment]
        )
        return SessionTranscriptionResult(
            metadata: SessionTranscriptionMetadata(
                status: .completed,
                model: model.provenance.model,
                systemSegmentCount: 1,
                microphoneSegmentCount: 0,
                mergedSegmentCount: 1,
                warnings: [],
                failureReason: nil,
                provenance: model.provenance
            ),
            systemTranscript: track,
            microphoneTranscript: nil,
            mergedTranscript: merged
        )
    }
}

private actor EmptyResilienceSessionTranscriber: SessionTranscribing {
    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        model: TranscriptionModelReference,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
        let track = TrackTranscript(
            source: .system,
            model: model.provenance.model,
            requestedLanguage: language,
            detectedLanguage: "sk",
            completedAt: Date(),
            segments: []
        )
        let merged = MergedTranscript(
            sessionID: session.metadata.id,
            title: session.metadata.title,
            completedAt: Date(),
            tracks: [],
            segments: []
        )
        return SessionTranscriptionResult(
            metadata: SessionTranscriptionMetadata(
                status: .completed,
                model: model.provenance.model,
                systemSegmentCount: 0,
                microphoneSegmentCount: 0,
                mergedSegmentCount: 0,
                warnings: [],
                failureReason: nil,
                provenance: model.provenance
            ),
            systemTranscript: track,
            microphoneTranscript: nil,
            mergedTranscript: merged
        )
    }
}

private struct NotificationFailingFinalizer: AudioFinalizing {
    func finalize(session: RecordingSession, diagnostics: CaptureSessionDiagnostics) async throws -> AudioFinalizationMetadata {
        throw CocoaError(.fileReadCorruptFile)
    }
}

private actor NotificationFailingTranscriber: SessionTranscribing {
    func transcribe(session: RecordingSession, finalization: AudioFinalizationMetadata, model: TranscriptionModelReference, language: TranscriptionLanguage) async throws -> SessionTranscriptionResult {
        throw CocoaError(.fileReadCorruptFile)
    }
}

private actor NotificationFailingExporter: ProcessingFileServicing {
    func loadRecoveredArtifacts(from session: RecordingSession) async -> RecoveredProcessingArtifacts? { nil }
    func loadUserNotes(from session: RecordingSession) async -> String? { nil }
    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws {}
    func exportMarkdown(session: SessionMetadata, transcript: MergedTranscript, utteranceTranscript: ContinuousUtteranceTranscript?, analysis: AIAnalysisArtifact?, notes: String?, to directoryURL: URL) async throws -> MarkdownExportResult {
        throw CocoaError(.fileWriteNoPermission)
    }
}
