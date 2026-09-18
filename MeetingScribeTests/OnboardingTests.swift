import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MeetingScribe

@MainActor
final class OnboardingTests: XCTestCase {
    func testFirstRunPromptIsShownOnceAndDeferSurvivesRestart() throws {
        let defaults = try makeDefaults()
        let store = OnboardingStore(defaults: defaults)

        XCTAssertTrue(store.shouldOpenOnLaunch)
        XCTAssertTrue(store.shouldShowInvitation)
        XCTAssertEqual(store.state.step, .welcome)

        store.setStep(.audioPermissions)
        store.advance()
        store.markPresentedOnLaunch()
        store.deferOnboarding()

        let restoredStore = OnboardingStore(defaults: defaults)
        XCTAssertFalse(restoredStore.shouldOpenOnLaunch)
        XCTAssertTrue(restoredStore.shouldShowInvitation)
        XCTAssertTrue(restoredStore.state.isDeferred)
        XCTAssertEqual(restoredStore.state.step, .transcriptionAndOutput)

        restoredStore.resume()
        XCTAssertFalse(restoredStore.state.isDeferred)
        XCTAssertEqual(restoredStore.state.step, .transcriptionAndOutput)
    }

    func testExistingInstallationGetsInvitationWithoutAutomaticPrompt() throws {
        let defaults = try makeDefaults()
        let store = OnboardingStore(defaults: defaults, existingInstallationDetector: { true })

        XCTAssertFalse(store.shouldOpenOnLaunch)
        XCTAssertTrue(store.shouldShowInvitation)
        XCTAssertTrue(store.state.isExistingInstallation)

        store.complete()
        XCTAssertFalse(store.shouldShowInvitation)

        let restoredStore = OnboardingStore(defaults: defaults)
        XCTAssertFalse(restoredStore.shouldOpenOnLaunch)
        XCTAssertFalse(restoredStore.shouldShowInvitation)
        XCTAssertTrue(restoredStore.state.isCompleted)
        XCTAssertEqual(restoredStore.state.step, .review)
    }

    func testExistingInstallationDetectionIgnoresDefaultAIPreferenceWrites() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "aiAnalysisEnabled")
        XCTAssertFalse(OnboardingStore.detectsExistingInstallation(defaults: defaults))

        defaults.set(AppLanguage.slovak.rawValue, forKey: "applicationLanguage")
        XCTAssertTrue(OnboardingStore.detectsExistingInstallation(defaults: defaults))

        defaults.removeObject(forKey: "applicationLanguage")
        defaults.set(TranscriptionLanguage.english.rawValue, forKey: "selectedTranscriptionLanguage")
        XCTAssertTrue(OnboardingStore.detectsExistingInstallation(defaults: defaults))
    }

    func testUnknownOnboardingVersionIsReinitialized() throws {
        let defaults = try makeDefaults()
        let staleState = OnboardingState(
            version: 99,
            step: .review,
            isCompleted: true,
            isDeferred: true,
            hasPromptedOnLaunch: true,
            isExistingInstallation: false
        )
        let data = try JSONEncoder().encode(staleState)
        defaults.set(data, forKey: "onboardingReadinessState")

        let store = OnboardingStore(defaults: defaults)
        XCTAssertEqual(store.state.version, OnboardingState.currentVersion)
        XCTAssertEqual(store.state.step, .welcome)
        XCTAssertFalse(store.state.isCompleted)
        XCTAssertFalse(store.state.isDeferred)
        XCTAssertTrue(store.shouldOpenOnLaunch)
    }

    func testAppStatePublishesAndPersistsOnboardingProgress() throws {
        let defaults = try makeDefaults()
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appState = AppState(
            sessionManager: SessionManager(recordingsRoot: root),
            outputFolderStore: OutputFolderStore(defaults: defaults),
            analysisSettingsStore: AnalysisSettingsStore(defaults: defaults),
            transcriptionSettingsStore: TranscriptionSettingsStore(defaults: defaults),
            audioRetentionSettingsStore: AudioRetentionSettingsStore(defaults: defaults),
            applicationSettingsStore: ApplicationSettingsStore(defaults: defaults),
            notificationDefaults: defaults,
            readinessService: makeReadinessService(),
            onboardingStore: OnboardingStore(defaults: defaults)
        )

        XCTAssertEqual(appState.onboardingStep, .welcome)
        XCTAssertTrue(appState.shouldShowOnboardingInvitation)

        appState.advanceOnboarding()
        appState.deferOnboarding()

        let restoredAppState = AppState(
            sessionManager: SessionManager(recordingsRoot: root),
            outputFolderStore: OutputFolderStore(defaults: defaults),
            analysisSettingsStore: AnalysisSettingsStore(defaults: defaults),
            transcriptionSettingsStore: TranscriptionSettingsStore(defaults: defaults),
            audioRetentionSettingsStore: AudioRetentionSettingsStore(defaults: defaults),
            applicationSettingsStore: ApplicationSettingsStore(defaults: defaults),
            notificationDefaults: defaults,
            readinessService: makeReadinessService(),
            onboardingStore: OnboardingStore(defaults: defaults)
        )
        XCTAssertEqual(restoredAppState.onboardingStep, .audioPermissions)
        XCTAssertTrue(restoredAppState.onboardingState.isDeferred)

        restoredAppState.completeOnboarding()
        XCTAssertFalse(restoredAppState.shouldShowOnboardingInvitation)
        XCTAssertEqual(restoredAppState.onboardingStep, .review)
    }

    func testReadinessConfigurationReflectsOptionalFeatures() throws {
        let defaults = try makeDefaults()
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appState = AppState(
            sessionManager: SessionManager(recordingsRoot: root),
            outputFolderStore: OutputFolderStore(defaults: defaults),
            analysisSettingsStore: AnalysisSettingsStore(defaults: defaults),
            transcriptionSettingsStore: TranscriptionSettingsStore(defaults: defaults),
            audioRetentionSettingsStore: AudioRetentionSettingsStore(defaults: defaults),
            applicationSettingsStore: ApplicationSettingsStore(defaults: defaults),
            notificationDefaults: defaults,
            readinessService: makeReadinessService(),
            onboardingStore: OnboardingStore(defaults: defaults)
        )

        appState.aiAnalysisEnabled = true
        appState.setCalendarIntegrationEnabled(true)

        let configuration = appState.readinessConfiguration
        XCTAssertEqual(configuration.captureMode, CaptureMode.systemAndMicrophone)
        XCTAssertTrue(configuration.aiAnalysis.isEnabled)
        XCTAssertTrue(configuration.calendar.isEnabled)
        XCTAssertEqual(configuration.calendar.authorization, ReadinessPermissionStatus.notDetermined)
        XCTAssertFalse(configuration.notifications.isEnabled)
    }

    func testReadinessRefreshPublishesSnapshotAndClearsTransientCheckingState() async throws {
        let defaults = try makeDefaults()
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appState = AppState(
            sessionManager: SessionManager(recordingsRoot: root),
            outputFolderStore: OutputFolderStore(defaults: defaults),
            analysisSettingsStore: AnalysisSettingsStore(defaults: defaults),
            transcriptionSettingsStore: TranscriptionSettingsStore(defaults: defaults),
            audioRetentionSettingsStore: AudioRetentionSettingsStore(defaults: defaults),
            applicationSettingsStore: ApplicationSettingsStore(defaults: defaults),
            notificationDefaults: defaults,
            readinessService: makeReadinessService(),
            onboardingStore: OnboardingStore(defaults: defaults)
        )

        await appState.refreshReadiness()

        XCTAssertNotNil(appState.readinessSnapshot)
        XCTAssertNil(appState.readinessError)
        XCTAssertFalse(appState.isRefreshingReadiness)
        XCTAssertEqual(appState.readinessSnapshot?.summary, ReadinessRecordingSummary.readyForRecordingAndTranscription)
        XCTAssertEqual(appState.readinessSnapshot?.checks.count, 8)
    }

    func testOnboardingTimeoutProducesPartialAudioResultWithoutDraftOrAI() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: true)
        let finalizer = CountingOnboardingTestFinalizer()
        let analysisRunner = CountingOnboardingAnalysisRunner()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            analysisRunner: analysisRunner,
            delay: ImmediateOnboardingTestDelay()
        )

        await appState.prepareStorage()
        appState.aiAnalysisEnabled = true
        appState.meetingTitle = "Draft meeting"
        await appState.startOnboardingTest()
        await waitForOnboardingTestCompletion(appState)

        XCTAssertEqual(appState.onboardingTestPhase, .completed)
        let result = try XCTUnwrap(appState.onboardingTestResult)
        XCTAssertEqual(result.title, AppState.onboardingTestSessionTitle)
        XCTAssertEqual(appState.meetingTitle, "Draft meeting")
        XCTAssertEqual(result.systemAudio.bufferCount, 1)
        XCTAssertTrue(result.systemAudio.activityDetected)
        XCTAssertEqual(result.microphone.bufferCount, 1)
        XCTAssertFalse(result.microphone.activityDetected)
        XCTAssertEqual(result.transcriptionStatus, .modelMissing)
        XCTAssertNil(result.markdownURL)
        let finalizationCount = await finalizer.finalizationCount()
        let captureStopCount = await capture.stopCount()
        let analysisRunCount = await analysisRunner.runCount()
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(captureStopCount, 1)
        XCTAssertEqual(analysisRunCount, 0)
        XCTAssertNil(appState.lastCompletedSession?.metadata.analysis)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.sessionDirectoryURL.path))
    }

    func testOnboardingManualStopFinalizesOnceAndIgnoresLaterTimeout() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: false)
        let finalizer = CountingOnboardingTestFinalizer()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            delay: NeverOnboardingTestDelay()
        )

        await appState.startOnboardingTest()
        XCTAssertEqual(appState.onboardingTestPhase, .recording)
        async let firstStop: Void = appState.stopOnboardingTest()
        async let secondStop: Void = appState.stopOnboardingTest()
        await firstStop
        await secondStop
        await waitForOnboardingTestCompletion(appState)

        XCTAssertEqual(appState.onboardingTestPhase, .completed)
        let finalizationCount = await finalizer.finalizationCount()
        let captureStopCount = await capture.stopCount()
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(captureStopCount, 1)
        XCTAssertNotNil(appState.onboardingTestResult)
    }

    func testOnboardingCountdownUsesCaptureStartRatherThanSessionCreation() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: true, startDelay: 0.1)
        let finalizer = CountingOnboardingTestFinalizer()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            delay: NeverOnboardingTestDelay()
        )

        await appState.startOnboardingTest()
        let sessionStartedAt: Date = try XCTUnwrap(appState.currentSession?.metadata.startedAt)
        let captureStartedAt = try XCTUnwrap(appState.captureDiagnostics.systemAudio.startedAt)

        XCTAssertLessThan(sessionStartedAt, captureStartedAt)
        let remainingSeconds = try XCTUnwrap(
            appState.onboardingTestRemainingSeconds(at: captureStartedAt)
        )
        XCTAssertEqual(remainingSeconds, 10)

        await appState.stopOnboardingTest()
    }

    func testOnboardingStopDuringStartingStopsTestAfterStartupResolves() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = BlockingOnboardingTestCaptureService()
        let finalizer = CountingOnboardingTestFinalizer()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            modelManager: OnboardingTestModelManager(isReady: true),
            delay: NeverOnboardingTestDelay()
        )

        async let startedTest = appState.startOnboardingTest()
        while appState.onboardingTestPhase != .starting {
            await Task.yield()
        }

        await appState.stopOnboardingTest()
        XCTAssertEqual(appState.onboardingTestPhase, .starting)

        await capture.resumeStart()
        await startedTest
        await waitForOnboardingTestCompletion(appState)

        XCTAssertEqual(appState.status, .idle)
        XCTAssertEqual(appState.lastCompletedSession?.metadata.processing?.state, .completed)
        XCTAssertEqual(appState.onboardingTestPhase, .completed)
        XCTAssertNotNil(appState.onboardingTestResult)
        let finalizationCount = await finalizer.finalizationCount()
        let captureStopCount = await capture.stopCount()
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(captureStopCount, 1)
    }

    func testExternalStopRecordingFinalizesOnboardingTestOnce() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: true)
        let finalizer = CountingOnboardingTestFinalizer()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            modelManager: OnboardingTestModelManager(isReady: true),
            delay: NeverOnboardingTestDelay()
        )

        await appState.startOnboardingTest()
        XCTAssertEqual(appState.onboardingTestPhase, .recording)

        await appState.stopRecording()
        await waitForOnboardingTestCompletion(appState)

        XCTAssertEqual(appState.status, .idle)
        XCTAssertEqual(appState.lastCompletedSession?.metadata.processing?.state, .completed)
        XCTAssertEqual(appState.onboardingTestPhase, .completed)
        XCTAssertNotNil(appState.onboardingTestResult)
        let finalizationCount = await finalizer.finalizationCount()
        let captureStopCount = await capture.stopCount()
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(captureStopCount, 1)
    }

    func testRenamingDuringOnboardingTestPreservesDraftTitle() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: false)
        let finalizer = CountingOnboardingTestFinalizer()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            delay: NeverOnboardingTestDelay()
        )

        appState.meetingTitle = "Draft meeting"
        await appState.startOnboardingTest()
        XCTAssertEqual(appState.currentSession?.metadata.title, AppState.onboardingTestSessionTitle)

        await appState.renameCurrentSession(to: "Renamed draft")

        XCTAssertEqual(appState.currentSession?.metadata.title, AppState.onboardingTestSessionTitle)
        XCTAssertEqual(appState.meetingTitle, "Draft meeting")

        await appState.stopOnboardingTest()
        await waitForOnboardingTestCompletion(appState)
        XCTAssertEqual(appState.onboardingTestPhase, .completed)
        XCTAssertEqual(appState.onboardingTestResult?.title, AppState.onboardingTestSessionTitle)
    }

    func testOnboardingTestPreservesPendingCalendarSelection() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: true)
        let finalizer = CountingOnboardingTestFinalizer()
        let provider = OnboardingTestCalendarEventProvider()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            delay: NeverOnboardingTestDelay(),
            calendarEventProvider: provider
        )

        appState.calendarIntegrationEnabled = true
        await appState.loadCalendarEventCandidates()
        let candidate = try XCTUnwrap(appState.calendarEventCandidates.first)
        let approved = await appState.approveCalendarEvent(
            candidate,
            participantIDs: [],
            eventDescription: nil
        )
        XCTAssertTrue(approved)

        await appState.startOnboardingTest()
        XCTAssertNil(appState.currentSession?.metadata.calendarEvent)

        await appState.stopOnboardingTest()
        await waitForOnboardingTestCompletion(appState)

        XCTAssertEqual(appState.onboardingTestPhase, .completed)
        XCTAssertEqual(appState.pendingCalendarEvent?.title, provider.candidate.title)
    }

    func testOnboardingTestWithReadyModelTranscribesAndExportsMarkdown() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: true)
        let finalizer = CountingOnboardingTestFinalizer()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            analysisRunner: CountingOnboardingAnalysisRunner(),
            modelManager: OnboardingTestModelManager(isReady: true),
            transcriber: OnboardingTestSessionTranscriber(),
            delay: ImmediateOnboardingTestDelay()
        )

        await appState.startOnboardingTest()
        await waitForOnboardingTestCompletion(appState)

        let result = try XCTUnwrap(appState.onboardingTestResult)
        XCTAssertEqual(result.transcriptionStatus, .completed)
        let markdownURL = try XCTUnwrap(result.markdownURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
        XCTAssertNil(result.error)
    }

    func testOnboardingTestIsRejectedDuringNormalRecording() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let capture = OnboardingTestCaptureService(systemActivity: true)
        let finalizer = CountingOnboardingTestFinalizer()
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: capture,
            finalizer: finalizer,
            delay: NeverOnboardingTestDelay()
        )

        await appState.startRecording()
        XCTAssertEqual(appState.status, .recording)

        await appState.startOnboardingTest()
        XCTAssertEqual(appState.onboardingTestPhase, .idle)
        XCTAssertNotNil(appState.onboardingTestError)
        XCTAssertNil(appState.onboardingTestResult)
        let captureStartCount = await capture.startCount()
        XCTAssertEqual(captureStartCount, 1)

        await appState.stopRecording()
        await appState.waitForProcessing()
        let finalizationCount = await finalizer.finalizationCount()
        XCTAssertEqual(finalizationCount, 1)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MeetingScribeTests.Onboarding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeOnboardingTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// The last step's only action used to be "Finish without test", so after
    /// a successful setup test there was no button that read as finishing.
    func testSetupCanBeFinishedAfterTheSetupTest() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: OnboardingTestCaptureService(systemActivity: true),
            finalizer: CountingOnboardingTestFinalizer(),
            delay: ImmediateOnboardingTestDelay()
        )
        await appState.prepareStorage()
        appState.setOnboardingStep(.review)

        await appState.startOnboardingTest()
        await waitForOnboardingTestCompletion(appState)
        XCTAssertEqual(appState.onboardingTestPhase, .completed)
        XCTAssertNotNil(appState.onboardingTestResult)
        XCTAssertFalse(appState.onboardingTestPhase.isRunning)

        appState.completeOnboarding()

        XCTAssertTrue(appState.onboardingState.isCompleted)
        XCTAssertFalse(appState.shouldShowOnboardingInvitation)
        XCTAssertFalse(OnboardingStore(defaults: fixture.defaults).shouldOpenOnLaunch)
    }

    func testSetupCannotBeFinishedWhileTheSetupTestIsStillRunning() {
        XCTAssertTrue(OnboardingTestPhase.starting.isRunning)
        XCTAssertTrue(OnboardingTestPhase.recording.isRunning)
        XCTAssertTrue(OnboardingTestPhase.processing.isRunning)
        XCTAssertFalse(OnboardingTestPhase.idle.isRunning)
        XCTAssertFalse(OnboardingTestPhase.completed.isRunning)
        XCTAssertFalse(OnboardingTestPhase.failed.isRunning)
    }

    /// The onboarding window opens at 780x580. Before the step body became
    /// scrollable, the review step needed 944pt, so the header, the step
    /// indicator and the Back/Continue/Finish buttons were clipped away and the
    /// guide could not be finished at all.
    func testEveryOnboardingStepFitsTheOnboardingWindow() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: OnboardingTestCaptureService(systemActivity: true),
            finalizer: CountingOnboardingTestFinalizer(),
            delay: ImmediateOnboardingTestDelay()
        )
        await appState.refreshReadiness()
        XCTAssertEqual(appState.readinessSnapshot?.checks.count, 8)

        let windowHeight: CGFloat = 580
        let controller = NSHostingController(
            rootView: OnboardingView(
                appState: appState,
                openSettingsAction: {},
                closeAction: {}
            )
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 780, height: windowHeight)

        for step in OnboardingStep.allCases {
            appState.setOnboardingStep(step)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(
                controller.view.fittingSize.height,
                windowHeight,
                "Step \(step) wants \(controller.view.fittingSize.height)pt of a \(windowHeight)pt window."
            )
        }
    }

    /// The readiness overview now carries the setup test as well, so it has to
    /// keep a bounded height instead of growing with the eight checks and a
    /// test result.
    func testReadinessOverviewStaysInsideASettingsSizedWindow() async throws {
        let fixture = try makeOnboardingTestFixture()
        defer { fixture.cleanup() }
        let appState = makeOnboardingTestAppState(
            fixture: fixture,
            capture: OnboardingTestCaptureService(systemActivity: true),
            finalizer: CountingOnboardingTestFinalizer(),
            delay: ImmediateOnboardingTestDelay()
        )
        await appState.refreshReadiness()
        XCTAssertEqual(appState.readinessSnapshot?.checks.count, 8)

        let controller = NSHostingController(
            rootView: ReadinessView(appState: appState, openOnboardingAction: {})
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            controller.view.fittingSize.height,
            620,
            "Readiness wants \(controller.view.fittingSize.height)pt."
        )
    }

    private func makeReadinessService() -> ReadinessService {
        ReadinessService(
            permissionProbe: OnboardingPermissionProbe(),
            storageProbe: OnboardingStorageProbe(),
            modelProbe: OnboardingModelProbe(),
            outputProbe: OnboardingOutputProbe(),
            analysisStatusProvider: CachedAnalysisStatusProvider(status: .unknown)
        )
    }

    private func makeOnboardingTestAppState(
        fixture: OnboardingTestFixture,
        capture: any AudioCaptureService,
        finalizer: CountingOnboardingTestFinalizer,
        analysisRunner: CountingOnboardingAnalysisRunner = CountingOnboardingAnalysisRunner(),
        modelManager: OnboardingTestModelManager = OnboardingTestModelManager(isReady: false),
        transcriber: any SessionTranscribing = OnboardingTestSessionTranscriber(),
        delay: any OnboardingTestDelaying,
        calendarEventProvider: (any CalendarEventProviding)? = nil
    ) -> AppState {
        let analysisSettingsStore = AnalysisSettingsStore(defaults: fixture.defaults)
        analysisSettingsStore.setEnabled(true)
        analysisSettingsStore.setExecutablePath("/bin/echo", for: .codex)
        let applicationSettingsStore = ApplicationSettingsStore(defaults: fixture.defaults)
        applicationSettingsStore.setMinimumStorageBytes(1)
        return AppState(
            sessionManager: SessionManager(
                recordingsRoot: fixture.recordingsRoot,
                storageGuard: StorageGuard(
                    provider: OnboardingTestStorageCapacityProvider(),
                    minimumBytes: 1
                )
            ),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: capture,
                microphoneCapture: OnboardingTestCaptureService(systemActivity: false)
            ),
            audioFinalizer: finalizer,
            fluidAudioModelManager: modelManager,
            sessionTranscriber: transcriber,
            analysisSettingsStore: analysisSettingsStore,
            analysisCommandRunner: analysisRunner,
            transcriptionSettingsStore: TranscriptionSettingsStore(defaults: fixture.defaults),
            audioRetentionSettingsStore: AudioRetentionSettingsStore(defaults: fixture.defaults),
            applicationSettingsStore: applicationSettingsStore,
            calendarEventProvider: calendarEventProvider,
            notificationDefaults: fixture.defaults,
            readinessService: makeReadinessService(),
            onboardingStore: OnboardingStore(defaults: fixture.defaults),
            onboardingTestDelay: delay
        )
    }

    private func makeOnboardingTestFixture() throws -> OnboardingTestFixture {
        let root = makeTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "MeetingScribeTests.OnboardingTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return OnboardingTestFixture(
            root: root,
            recordingsRoot: root.appendingPathComponent("Recordings", isDirectory: true),
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func waitForOnboardingTestCompletion(_ appState: AppState) async {
        let deadline = Date().addingTimeInterval(5)
        while appState.onboardingTestPhase != .completed
            && appState.onboardingTestPhase != .failed
            && Date() < deadline {
            await Task.yield()
        }
    }
}

private struct OnboardingTestFixture {
    let root: URL
    let recordingsRoot: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor OnboardingPermissionProbe: ReadinessPermissionProbing {
    func snapshot() async -> ReadinessPermissionSnapshot {
        ReadinessPermissionSnapshot(systemAudio: .granted, microphone: .granted)
    }
}

private actor OnboardingStorageProbe: ReadinessStorageProbing {
    func status() async -> ReadinessStorageProbeResult {
        .available(
            StorageStatus(
                availableBytes: 2_000_000_000,
                requiredBytes: StorageGuard.defaultMinimumBytes
            )
        )
    }
}

private actor OnboardingModelProbe: ReadinessModelProbing {
    func status() async -> ReadinessModelProbeResult {
        .ready
    }
}

private actor OnboardingOutputProbe: ReadinessOutputProbing {
    func verifyWritableDirectory(_ url: URL) async -> ReadinessOutputProbeResult {
        .writable
    }
}

private struct ImmediateOnboardingTestDelay: OnboardingTestDelaying {
    func sleep(for duration: TimeInterval) async throws {}
}

private struct NeverOnboardingTestDelay: OnboardingTestDelaying {
    func sleep(for duration: TimeInterval) async throws {
        throw CancellationError()
    }
}

private struct OnboardingTestStorageCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 {
        4 * 1_073_741_824
    }
}

private struct OnboardingTestCalendarEventProvider: CalendarEventProviding {
    let candidate = CalendarEventCandidate(
        id: "onboarding-calendar-event",
        title: "Pending calendar event",
        startsAt: Date(),
        endsAt: Date().addingTimeInterval(3_600),
        isAllDay: false,
        participants: []
    )

    var authorizationStatus: CalendarAuthorizationStatus { .fullAccess }

    func requestFullAccess() async throws -> Bool { true }

    func eventCandidates(for query: CalendarEventQuery) throws -> [CalendarEventCandidate] {
        [candidate]
    }
}

private actor OnboardingTestModelManager: FluidAudioModelManaging {
    private let isReady: Bool

    init(isReady: Bool) {
        self.isReady = isReady
    }

    func prepareStorage() throws {}

    func status(for descriptor: FluidAudioModelDescriptor) -> FluidAudioModelStatus {
        guard isReady else { return .missing }
        return .ready(
            bundleURL: URL(fileURLWithPath: "/tmp/meeting-scribe-test-model"),
            sizeBytes: descriptor.approximateSizeBytes
        )
    }

    func validateInstalledModel(_ descriptor: FluidAudioModelDescriptor) throws -> URL {
        URL(fileURLWithPath: "/tmp/meeting-scribe-test-model")
    }

    func install(
        _ descriptor: FluidAudioModelDescriptor,
        repair: Bool,
        progress: @escaping @Sendable (FluidAudioModelDownloadProgress) -> Void
    ) throws -> URL {
        URL(fileURLWithPath: "/tmp/meeting-scribe-test-model")
    }

    func importBundle(
        from sourceBundleURL: URL,
        as descriptor: FluidAudioModelDescriptor
    ) throws -> URL {
        URL(fileURLWithPath: "/tmp/meeting-scribe-test-model")
    }

    func removeModel(_ descriptor: FluidAudioModelDescriptor) throws {}
}

private actor OnboardingTestCaptureService: AudioCaptureService {
    private let systemActivity: Bool
    private let startDelay: TimeInterval
    private var currentDiagnostics = AudioCaptureDiagnostics.empty
    private var starts = 0
    private var stops = 0

    init(systemActivity: Bool, startDelay: TimeInterval = 0) {
        self.systemActivity = systemActivity
        self.startDelay = startDelay
    }

    func start(outputURL: URL) async throws {
        if startDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
        }
        starts += 1
        currentDiagnostics = AudioCaptureDiagnostics(
            fileName: outputURL.lastPathComponent,
            startedAt: Date()
        )
        currentDiagnostics.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 1,
            presentationTimestamp: 0,
            audioLevel: systemActivity
                ? AudioLevelMeasurement(rmsDecibels: -20, peakDecibels: -12)
                : nil
        )
    }

    func stop() async -> AudioCaptureDiagnostics {
        stops += 1
        return currentDiagnostics
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        currentDiagnostics
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private actor BlockingOnboardingTestCaptureService: AudioCaptureService {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var shouldResumeStartImmediately = false
    private var currentDiagnostics = AudioCaptureDiagnostics.empty
    private var stops = 0

    func start(outputURL: URL) async throws {
        await withCheckedContinuation { continuation in
            if shouldResumeStartImmediately {
                continuation.resume()
            } else {
                startContinuation = continuation
            }
        }
        currentDiagnostics = AudioCaptureDiagnostics(
            fileName: outputURL.lastPathComponent,
            startedAt: Date()
        )
    }

    func resumeStart() {
        if let startContinuation {
            startContinuation.resume()
            self.startContinuation = nil
        } else {
            shouldResumeStartImmediately = true
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        stops += 1
        return currentDiagnostics
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        currentDiagnostics
    }

    func stopCount() -> Int { stops }
}

private actor CountingOnboardingTestFinalizer: AudioFinalizing {
    private var finalizations = 0

    func finalize(
        session: RecordingSession,
        diagnostics: CaptureSessionDiagnostics
    ) async throws -> AudioFinalizationMetadata {
        finalizations += 1
        return AudioFinalizationMetadata(
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

    func finalizationCount() -> Int { finalizations }
}

private actor OnboardingTestSessionTranscriber: SessionTranscribing {
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
            text: "Setup test transcript",
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

private actor CountingOnboardingAnalysisRunner: AnalysisCommandRunning {
    private var runs = 0

    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        if command.arguments == ["--version"] || command.arguments == ["login", "status"] {
            return AnalysisCommandResult(
                exitCode: 0,
                standardOutput: Data("status".utf8),
                standardError: Data()
            )
        }
        runs += 1
        return AnalysisCommandResult(
            exitCode: 0,
            standardOutput: Data("analysis".utf8),
            standardError: Data()
        )
    }

    func runCount() -> Int { runs }
}
