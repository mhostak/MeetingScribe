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

    func testAllApplicationLanguagesResolveToAConcreteLocalization() {
        XCTAssertEqual(AppLanguage.slovak.resolved, .slovak)
        XCTAssertEqual(AppLanguage.czech.resolved, .czech)
        XCTAssertEqual(AppLanguage.english.resolved, .english)
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
    }

    func testAudioRetentionSettingDefaultsOffAndPersistsOptIn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = AudioRetentionSettingsStore(defaults: fixture.defaults)
        XCTAssertFalse(store.automaticallyDeleteSourceCAF)
        store.setAutomaticallyDeleteSourceCAF(true)

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
        appState.automaticallyDeleteSourceCAF = false
        appState.persistAudioRetentionSettings()
        XCTAssertFalse(store.automaticallyDeleteSourceCAF)
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
        XCTAssertNotEqual(appState.status, .recording)
        XCTAssertTrue(appState.canEditSessionConfiguration)
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
        XCTAssertEqual(appState.fluidAudioASRModelStatus, .missing)
        XCTAssertEqual(appState.fluidAudioDiarizationModelStatus, .missing)
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
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
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

        XCTAssertEqual(appState.status, .completed)
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
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            analysisCommandRunner: runner,
            defaults: fixture.defaults
        )
        await appState.prepareStorage()

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

        XCTAssertEqual(appState.status, .completed)
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

        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            fluidAudioModelManager: ResilienceFluidAudioModelManager(modelsRoot: modelsRoot),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        let candidate = try XCTUnwrap(appState.recoveryCandidates.first)
        await appState.recoverSession(candidate)

        XCTAssertEqual(appState.status, .completed)
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
        XCTAssertEqual(appState.status, .exporting)
        gate.release()
        await recoveryTask.value
        XCTAssertEqual(appState.status, .completed)
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

        let stopCount = await systemCapture.stopCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(appState.status, .completed)
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
        try await waitUntil { appState.status == .completed || appState.status == .failed }

        XCTAssertEqual(appState.status, .completed)
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
        try await waitUntil { appState.status == .completed || appState.status == .failed }

        XCTAssertEqual(appState.status, .completed)
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
        try await waitUntil { appState.status == .completed || appState.status == .failed }

        XCTAssertEqual(appState.status, .completed)
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
        XCTAssertEqual(appState.status, .completed)
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
        try await waitUntil { appState.status == .completed || appState.status == .failed }

        XCTAssertEqual(appState.status, .completed)
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
        defaults: UserDefaults
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
            storageStatusProvider: storageStatusProvider
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

    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws {
        try await delegate.persistAnalysis(analysis, to: url)
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        resolvedTranscript: ResolvedTranscript?,
        analysis: AIAnalysisArtifact?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        gate.block()
        return try await delegate.exportMarkdown(
            session: session,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            resolvedTranscript: resolvedTranscript,
            analysis: analysis,
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
    func availableCapacity(at url: URL) throws -> Int64 { 1_000_000 }
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

    func start(outputURL: URL) async throws {
        starts += 1
        try Data("preserved mock audio".utf8).write(to: outputURL, options: .atomic)
        current = AudioCaptureDiagnostics(
            fileName: outputURL.lastPathComponent,
            startedAt: Date()
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
