import AppKit
import Darwin
import AVFoundation
import CoreGraphics
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

struct CaptureMonitoringConfiguration: Sendable {
    // Five diagnostics snapshots per second keep the live audio meter responsive.
    // Storage checks retain their previous five-second cadence, and a stalled
    // source still needs roughly three seconds of consecutive confirmation.
    var interval: Duration = .milliseconds(200)
    var storageCheckEveryTicks = 25
    var stalledSystemAudioCheckCount = 15
    var maximumStorageCheckFailures = 3
}

@MainActor
final class CaptureDiagnosticsModel {
    private(set) var snapshot: CaptureSessionDiagnostics

    init(snapshot: CaptureSessionDiagnostics = .empty) {
        self.snapshot = snapshot
    }

    func update(_ snapshot: CaptureSessionDiagnostics) {
        self.snapshot = snapshot
    }
}

struct RecordingsNavigationRequest: Equatable, Sendable {
    let requestID: UUID
    let sessionID: String
    let occurredAt: Date
}

/// Model installation can report byte-level progress many times per second.
/// Keeping it separate prevents those updates from invalidating every window
/// that needs general application state.
@MainActor
final class FluidAudioModelState: ObservableObject {
    @Published var asrStatus: FluidAudioModelStatus = .missing
    @Published var asrDownloadProgress: FluidAudioModelDownloadProgress?
    @Published var isInstallingASRModel = false
}

@MainActor
final class AppState: ObservableObject {
    static let onboardingTestSessionTitle = "MeetingScribe Setup Test"
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var lastCompletedSession: RecordingSession?
    @Published private(set) var lastError: String?
    let captureDiagnosticsModel = CaptureDiagnosticsModel()

    var captureDiagnostics: CaptureSessionDiagnostics {
        captureDiagnosticsModel.snapshot
    }
    let fluidAudioModelState = FluidAudioModelState()
    @Published private(set) var legacyModelCleanupReport = LegacyModelCleanupReport(
        fileCount: 0,
        totalBytes: 0
    )
    @Published private(set) var isRemovingLegacyModels = false
    @Published private(set) var fluidAudioReprocessingSessionID: String?
    @Published private(set) var aiAnalysisReprocessingSessionID: String?
    @Published private(set) var outputFolderURL: URL?
    @Published private(set) var lastMarkdownURL: URL?
    @Published private(set) var analysisToolStatus: AnalysisToolStatus = .unknown
    @Published private(set) var isCheckingAnalysisTool = false
    @Published private(set) var readinessSnapshot: ReadinessSnapshot?
    @Published private(set) var readinessError: String?
    @Published private(set) var isRefreshingReadiness = false
    @Published private(set) var onboardingTestPhase: OnboardingTestPhase = .idle
    @Published private(set) var onboardingTestResult: OnboardingTestResult?
    @Published private(set) var onboardingTestError: String?
    @Published private(set) var onboardingState: OnboardingState
    @Published private(set) var onboardingWindowRequest: UUID?
    @Published private(set) var isApplicationPrepared = false
    @Published private(set) var recoveryCandidates: [SessionRecoveryCandidate] = []
    @Published private(set) var recoveryIssues: [SessionRecoveryIssue] = []
    @Published private(set) var recordingsNavigationRequest: RecordingsNavigationRequest?
    @Published private(set) var isRecoveringSession = false
    @Published private(set) var processingSteps = ProcessingStep.initial
    @Published private(set) var calendarAuthorizationStatus: CalendarAuthorizationStatus = .notDetermined
    @Published private(set) var calendarEventCandidates: [CalendarEventCandidate] = []
    @Published private(set) var pendingCalendarEvent: CalendarEventSnapshot?
    @Published private(set) var isLoadingCalendarEvents = false
    @Published private(set) var isRequestingCalendarAccess = false
    @Published private(set) var calendarAccessError: String?
    @Published private(set) var recordingAudioCleanupPlan = RecordingAudioCleanupPlan.empty
    @Published private(set) var recordingAudioCleanupReport: RecordingAudioCleanupReport?
    @Published private(set) var recordingAudioCleanupError: String?
    @Published private(set) var isScanningRecordingAudio = false
    @Published private(set) var isCleaningRecordingAudio = false
    @Published var selectedTranscriptionLanguage: TranscriptionLanguage = .automatic
    @Published var aiAnalysisEnabled = false
    @Published var selectedAnalysisTool: AnalysisTool = .codex
    @Published var analysisExecutablePath = ""
    @Published var selectedAnalysisModel: AnalysisModelSelection = .automatic
    @Published var customAnalysisModel = ""
    @Published var analysisPrompt = AnalysisPrompt.defaultTemplate
    @Published var meetingTitle = ""
    @Published var meetingNotesDraft = ""
    @Published var automaticallyDeleteSourceCAF = false
    @Published var audioRetentionPolicy: AudioRetentionPolicy = .keepForever
    @Published var selectedAppLanguage: AppLanguage = .system
    @Published var selectedOutputLanguage: OutputLanguage = .slovak
    @Published var markdownFileNameTemplate = MarkdownFileNameTemplate.defaultValue
    @Published var minimumStorageBytes = StorageGuard.defaultMinimumBytes
    @Published var calendarIntegrationEnabled = false
    @Published private(set) var notificationsEnabled = false
    @Published var selectedSettingsSection = "general"
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

    private var stateMachine = AppStateMachine()
    private let sessionManager: SessionManager
    private let captureCoordinator: CaptureCoordinator
    private let audioFinalizer: any AudioFinalizing
    private let fluidAudioModelManager: any FluidAudioModelManaging
    private let legacyModelCleaner: LegacyModelCleaner
    private let sessionTranscriber: any SessionTranscribing
    private let processingFileService: any ProcessingFileServicing
    private let outputFolderStore: OutputFolderStore
    private let obsidianService: ObsidianService
    private let analysisSettingsStore: AnalysisSettingsStore
    private let analysisCommandRunner: any AnalysisCommandRunning
    private let transcriptionSettingsStore: TranscriptionSettingsStore
    private let audioRetentionSettingsStore: AudioRetentionSettingsStore
    private let applicationSettingsStore: ApplicationSettingsStore
    private let calendarEventProvider: any CalendarEventProviding
    private let audioSourceCleaner: any AudioSourceCleaning
    private let recordingAudioCleanupService: RecordingAudioCleanupService
    private let recoveredAudioInspector: RecoveredAudioInspector
    private let processingLogger: ProcessingLogger
    private let processingNotifier: any ProcessingNotifying
    private let notificationDefaults: UserDefaults
    private let readinessService: ReadinessService
    private let onboardingStore: OnboardingStore
    private let readinessAnalysisStatusStore: ReadinessAnalysisStatusStore
    private let captureMonitoringConfiguration: CaptureMonitoringConfiguration
    private let storageStatusProvider: @Sendable () async throws -> StorageStatus
    private var captureMonitorTask: Task<Void, Never>?
    private var storageCheckTick = 0
    private var storageCheckFailureCount = 0
    private var stalledSystemAudioCheckTick = 0
    private var isStoppingForLowStorage = false
    private var isStoppingForCaptureFailure = false
    private var hasPreparedStorage = false
    private var isPreparingStorage = false
    private var fluidAudioInstallTasks: [FluidAudioModelKind: Task<Void, Never>] = [:]
    private var startRecordingOperation: (id: UUID, task: Task<Void, Never>)?
    private var stopRecordingOperation: (id: UUID, task: Task<Void, Never>)?
    private let onboardingTestDelay: any OnboardingTestDelaying
    private var onboardingTestSessionID: String?
    private var onboardingTestStartedAt: Date?
    private var onboardingTestTimer: Task<Void, Never>?
    private var isOnboardingTestStopRequested = false
    private var usesDetectedAnalysisExecutable = true
    @Published private(set) var processingJobs: [RecordingSession] = []
    @Published private(set) var processingQueueStatus = ProcessingQueueStatus.idle
    private var queueIsObserved = false
    private let resourceMonitoringEnabled: Bool
    private var resourceMonitorTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var resourceMemoryPressure: ProcessingResourceSnapshot.MemoryPressure = .normal
    private var resourceGovernor = ProcessingResourceGovernor()
    private var observedDroppedBuffers = 0

    private func startResourceMonitoring() {
        guard resourceMonitoringEnabled, resourceMonitorTask == nil else { return }
        resourceGovernor = ProcessingResourceGovernor(
            limits: .backgroundReserve(captureMinimumBytes: minimumStorageBytes)
        )
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        // The handler reads the source through this property, so assigning it
        // after `resume()` made the first event fall back to `.normal`.
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let event = self.memoryPressureSource?.data {
                    self.resourceMemoryPressure = event.contains(.critical) ? .critical
                        : event.contains(.warning) ? .warning : .normal
                }
                await self.updateResourcePolicy()
            }
        }
        source.resume()
        resourceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateResourcePolicy()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    /// Memory-pressure notifications only fire on transitions. A missed return to
    /// `.normal` would otherwise hold the queue for the rest of the process, so
    /// the level is polled and the last event value is only a fallback.
    private static func pollMemoryPressure() -> ProcessingResourceSnapshot.MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }

    /// Applies the user's capture reserve to background work when the setting changes.
    func refreshProcessingResourceLimits() {
        guard resourceMonitoringEnabled else { return }
        resourceGovernor = ProcessingResourceGovernor(
            limits: .backgroundReserve(captureMinimumBytes: minimumStorageBytes)
        )
    }

    private func updateResourcePolicy() async {
        guard resourceMonitoringEnabled else { return }
        let lifecycle: ProcessingResourceSnapshot.CaptureLifecycle = switch status {
        case .preparing: .preparing
        case .recording: .recording
        case .stopping: .stopping
        default: .idle
        }
        let thermal: ProcessingResourceSnapshot.ThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        let diagnostic = captureDiagnostics
        let dropped = diagnostic.systemAudio.droppedBufferCount + diagnostic.microphone.droppedBufferCount
        let healthy = diagnostic.systemAudio.health() != .stalled && diagnostic.systemAudio.health() != .failed
            && dropped <= observedDroppedBuffers
        observedDroppedBuffers = dropped
        let available = try? await sessionManager.storageStatus().availableBytes
        if let polled = Self.pollMemoryPressure() { resourceMemoryPressure = polled }
        let snapshot = ProcessingResourceSnapshot(captureLifecycle: lifecycle,
            captureIsHealthy: lifecycle == .recording ? healthy : nil,
            memoryPressure: resourceMemoryPressure, thermalState: thermal, availableStorageBytes: available)
        // The queue's published pause is the single source of truth. Mirroring it
        // in a local flag used to strand the queue whenever the two disagreed,
        // for example after a resume that threw.
        let pause = processingQueueStatus.pause
        switch resourceGovernor.decision(for: snapshot, workerIsRunning: isProcessingInBackground) {
        case .allow:
            guard pause?.kind == .resource else { return }
            do { try await processingQueue.resume() } catch { lastError = localized(error) }
        case let .hold(reasons), let .cancelRunning(reasons):
            let reason = localizedResourcePauseReason(reasons)
            guard pause?.kind != .resource || pause?.reason != reason else { return }
            await processingQueue.pause(reason: reason, kind: .resource)
        }
    }

    private func localizedResourcePauseReason(
        _ reasons: [ProcessingResourceReason]
    ) -> String {
        guard let reason = reasons.first else {
            return localized(.processingPausedForResources)
        }
        switch reason {
        case .captureUnhealthy:
            return localized(.processingPausedForCapture)
        case .memoryPressure:
            return localized(.processingPausedForMemory)
        case .thermal:
            return localized(.processingPausedForThermal)
        case .storageReserve:
            return localized(.processingPausedForStorage)
        }
    }

    /// Clears a resource pause on the user's explicit request. The governor
    /// re-evaluates on the next tick, so a still-blocked queue pauses again with
    /// a visible reason rather than silently doing nothing.
    func resumeProcessing() async {
        do {
            try await processingQueue.resume()
            lastError = nil
        } catch {
            lastError = localized(error)
        }
    }

    private var pendingCaptureHandoff: (sessionID: String, endedAt: Date, diagnostics: CaptureSessionDiagnostics)?
    private let injectedProcessor: (any SessionProcessing)?
    private lazy var processingQueue = ProcessingQueue(
        repository: sessionManager,
        processor: injectedProcessor ?? SessionProcessor(
            audioFinalizer: audioFinalizer,
            transcriber: sessionTranscriber,
            fileService: processingFileService,
            modelResolver: DefaultTranscriptionModelResolver(manager: fluidAudioModelManager),
            analysisCommandRunner: analysisCommandRunner,
            audioSourceCleaner: audioSourceCleaner,
            logger: processingLogger
        )
    )

    var hasPendingProcessing: Bool {
        processingJobs.contains { session in
            guard let job = session.metadata.processing else { return false }
            return job.state != .completed && job.state != .failed
        }
    }

    var isProcessingInBackground: Bool {
        processingJobs.contains { [.running, .pauseRequested].contains($0.metadata.processing?.state) }
    }

    var hasProcessingFailures: Bool { processingJobs.contains { $0.metadata.processing?.state == .failed } }

    /// True only when a pause actually withholds work the queue would run.
    var isProcessingPaused: Bool {
        processingQueueStatus.isPaused && hasPendingProcessing
    }

    var processingPauseReason: String? {
        isProcessingPaused ? processingQueueStatus.pause?.reason : nil
    }

    /// A shutdown pause belongs to a terminating app and must not offer a button.
    var canResumeProcessing: Bool {
        guard let pause = processingQueueStatus.pause, hasPendingProcessing else { return false }
        return pause.kind != .shutdown
    }

    var canStartRecording: Bool {
        currentSession == nil && ![.preparing, .recording, .stopping].contains(status)
            && !isCleaningRecordingAudio && !isScanningRecordingAudio
    }

    func canEnqueueProcessing(sessionID: String) -> Bool {
        currentSession?.metadata.id != sessionID && !isCleaningRecordingAudio && !isScanningRecordingAudio
            && !processingJobs.contains {
                $0.metadata.id == sessionID && $0.metadata.processing?.state != .completed
                    && $0.metadata.processing?.state != .failed
            }
    }

    var canChangeModels: Bool { !hasPendingProcessing }

    private var processingConfiguration: ProcessingJobConfiguration {
        ProcessingJobConfiguration(outputDirectoryURL: outputFolderURL,
                                   outputDirectoryBookmark: outputFolderStore.bookmark(for: outputFolderURL),
                                   automaticallyDeleteSourceCAF: automaticallyDeleteSourceCAF)
    }

    private func observeProcessingQueue() async {
        guard !queueIsObserved else { return }
        queueIsObserved = true
        startResourceMonitoring()
        await updateResourcePolicy()
        await processingQueue.observe(onChange: { [weak self] sessions, status in
            await self?.receiveProcessingSessions(sessions, status: status)
        }, onCompletion: { [weak self] session, result in
            await self?.processingDidFinish(session, result: result)
        })
    }

    private func receiveProcessingSessions(
        _ sessions: [RecordingSession],
        status: ProcessingQueueStatus
    ) {
        processingJobs = sessions
        processingQueueStatus = status
    }

    private func processingDidFinish(_ session: RecordingSession, result: SessionProcessingResult?) async {
        guard let job = session.metadata.processing else { return }
        lastCompletedSession = session
        let markdownURL = result?.revision.flatMap { revision in
            revision.manifest.markdownFileName.map { revision.directoryURL.appendingPathComponent($0) }
        } ?? session.metadata.output?.markdownPath.map { URL(fileURLWithPath: $0) }
        lastMarkdownURL = markdownURL
        if onboardingTestPhase == .processing, isOnboardingTestSession(session) {
            await finalizeOnboardingTestAfterProcessing(session: session, result: result)
        }
        guard notificationsEnabled else { return }
        let language: ProcessingNotificationLanguage = switch selectedAppLanguage.resolved {
        case .slovak: .slovak
        case .czech: .czech
        case .english, .system: .english
        }
        let failedSteps = result?.failedSteps ?? (job.state == .failed ? [job.stage ?? .preparingAudio] : [])
        await processingNotifier.send(ProcessingNotification(
            id: job.attemptID, sessionID: session.metadata.id, title: session.metadata.title,
            failedSteps: Array(failedSteps), markdownURL: markdownURL, language: language,
            occurredAt: session.metadata.startedAt ?? session.metadata.createdAt
        ))
    }

    func waitForProcessing() async {
        await processingQueue.waitUntilSettled()
    }

    func retryProcessing(_ session: RecordingSession) async {
        do {
            guard canEnqueueProcessing(sessionID: session.metadata.id) else {
                // A pending job cannot be re-enqueued. Say so instead of
                // returning silently, which looks like a dead button.
                if canResumeProcessing { lastError = processingQueueStatus.pause?.reason }
                return
            }
            let job = session.metadata.processing
            let queued = try await sessionManager.queueProcessing(
                sessionID: session.metadata.id, kind: job?.kind ?? .recovery,
                configuration: job?.configuration ?? processingConfiguration
            )
            await observeProcessingQueue()
            await processingQueue.accept(queued)
        } catch { lastError = localized(error) }
    }

    func prepareForTermination() async -> Bool {
        if status == .recording { await stopRecording() }
        guard currentSession == nil, status != .preparing, status != .stopping else { return false }
        resourceMonitorTask?.cancel()
        memoryPressureSource?.cancel()
        await processingQueue.shutdown()
        return true
    }

    /// The system can withdraw a termination the app already prepared for. The
    /// monitor task and the scheduler must come back, or the queue stays dead for
    /// the rest of the process with no way to restart it.
    func abortTermination() async {
        resourceMonitorTask = nil
        memoryPressureSource = nil
        do { try await processingQueue.cancelShutdown() } catch { lastError = localized(error) }
        startResourceMonitoring()
        await updateResourcePolicy()
    }

    init(
        sessionManager: SessionManager = SessionManager(),
        captureCoordinator: CaptureCoordinator = CaptureCoordinator(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        fluidAudioModelManager: (any FluidAudioModelManaging)? = nil,
        legacyModelCleaner: LegacyModelCleaner = LegacyModelCleaner(),
        sessionTranscriber: (any SessionTranscribing)? = nil,
        outputExporter: OutputExporter = OutputExporter(),
        processingFileService: (any ProcessingFileServicing)? = nil,
        outputFolderStore: OutputFolderStore? = nil,
        obsidianService: ObsidianService? = nil,
        analysisSettingsStore: AnalysisSettingsStore? = nil,
        analysisCommandRunner: any AnalysisCommandRunning = AnalysisProcessRunner(),
        transcriptionSettingsStore: TranscriptionSettingsStore? = nil,
        audioRetentionSettingsStore: AudioRetentionSettingsStore? = nil,
        applicationSettingsStore: ApplicationSettingsStore? = nil,
        calendarEventProvider: (any CalendarEventProviding)? = nil,
        audioSourceCleaner: any AudioSourceCleaning = AudioSourceCleaner(),
        recordingAudioCleanupService: RecordingAudioCleanupService? = nil,
        recoveredAudioInspector: RecoveredAudioInspector = RecoveredAudioInspector(),
        processingLogger: ProcessingLogger = ProcessingLogger(),
        captureMonitoringConfiguration: CaptureMonitoringConfiguration = CaptureMonitoringConfiguration(),
        storageStatusProvider: (@Sendable () async throws -> StorageStatus)? = nil,
        processingNotifier: any ProcessingNotifying = ProcessingNotificationService(),
        notificationDefaults: UserDefaults = .standard,
        sessionProcessor: (any SessionProcessing)? = nil,
        resourceMonitoringEnabled: Bool = true,
        readinessService: ReadinessService? = nil,
        onboardingStore: OnboardingStore? = nil,
        onboardingTestDelay: any OnboardingTestDelaying = DefaultOnboardingTestDelay()
    ) {
        self.resourceMonitoringEnabled = resourceMonitoringEnabled
        self.injectedProcessor = sessionProcessor
        self.sessionManager = sessionManager
        self.captureCoordinator = captureCoordinator
        self.audioFinalizer = audioFinalizer
        let resolvedFluidAudioModelManager = fluidAudioModelManager ?? FluidAudioModelManager()
        self.fluidAudioModelManager = resolvedFluidAudioModelManager
        self.legacyModelCleaner = legacyModelCleaner
        self.sessionTranscriber = sessionTranscriber ?? SessionTranscriber()
        self.processingFileService = processingFileService
            ?? ProcessingFileService(outputExporter: outputExporter)
        self.outputFolderStore = outputFolderStore ?? OutputFolderStore()
        self.obsidianService = obsidianService ?? ObsidianService()
        self.analysisSettingsStore = analysisSettingsStore ?? AnalysisSettingsStore()
        self.analysisCommandRunner = analysisCommandRunner
        self.transcriptionSettingsStore = transcriptionSettingsStore
            ?? TranscriptionSettingsStore()
        self.audioRetentionSettingsStore = audioRetentionSettingsStore
            ?? AudioRetentionSettingsStore()
        self.applicationSettingsStore = applicationSettingsStore
            ?? ApplicationSettingsStore()
        self.calendarEventProvider = calendarEventProvider ?? CalendarEventService()
        self.audioSourceCleaner = audioSourceCleaner
        self.recordingAudioCleanupService = recordingAudioCleanupService
            ?? RecordingAudioCleanupService(recordingsRoot: sessionManager.recordingsRoot)
        self.recoveredAudioInspector = recoveredAudioInspector
        self.processingLogger = processingLogger
        self.processingNotifier = processingNotifier
        self.notificationDefaults = notificationDefaults
        let analysisStatusStore = ReadinessAnalysisStatusStore()
        let resolvedReadinessService = readinessService ?? ReadinessService(
            storageProbe: SessionStorageProbe(recordingsRoot: sessionManager.recordingsRoot),
            modelProbe: FluidAudioReadinessProbe(manager: resolvedFluidAudioModelManager),
            analysisStatusProvider: analysisStatusStore
        )
        let resolvedOnboardingStore = onboardingStore ?? OnboardingStore(defaults: notificationDefaults)
        self.readinessAnalysisStatusStore = analysisStatusStore
        self.readinessService = resolvedReadinessService
        self.onboardingStore = resolvedOnboardingStore
        self.onboardingTestDelay = onboardingTestDelay
        self.onboardingState = resolvedOnboardingStore.state
        self.notificationsEnabled = notificationDefaults.bool(forKey: "processingNotificationsEnabled")
        self.captureMonitoringConfiguration = captureMonitoringConfiguration
        self.storageStatusProvider = storageStatusProvider ?? {
            try await sessionManager.storageStatus()
        }
    }

    func prepareStorage() async {
        guard !hasPreparedStorage, !isPreparingStorage else { return }
        isPreparingStorage = true
        let hadRecordingRootBeforePreparation = FileManager.default.fileExists(
            atPath: sessionManager.recordingsRoot.path
        )
        defer { isPreparingStorage = false }

        do {
            try await sessionManager.prepareStorage()
            try await fluidAudioModelManager.prepareStorage()
        } catch {
            setFailure(error)
            return
        }

        notificationsEnabled = notificationDefaults.bool(forKey: "processingNotificationsEnabled")

        outputFolderURL = outputFolderStore.restoreFolder()
        selectedTranscriptionLanguage = self.transcriptionSettingsStore.selectedLanguage
        selectedAppLanguage = applicationSettingsStore.appLanguage
        selectedOutputLanguage = applicationSettingsStore.outputLanguage
        markdownFileNameTemplate = applicationSettingsStore.markdownFileNameTemplate
        minimumStorageBytes = applicationSettingsStore.minimumStorageBytes
        calendarIntegrationEnabled = applicationSettingsStore.calendarIntegrationEnabled
        calendarAuthorizationStatus = calendarEventProvider.authorizationStatus
        await sessionManager.setMinimumStorageBytes(minimumStorageBytes)
        automaticallyDeleteSourceCAF = audioRetentionSettingsStore
            .automaticallyDeleteSourceCAF
        audioRetentionPolicy = audioRetentionSettingsStore.policy
        aiAnalysisEnabled = analysisSettingsStore.isEnabled
        selectedAnalysisTool = analysisSettingsStore.tool
        selectedAnalysisModel = analysisSettingsStore.modelSelection(for: selectedAnalysisTool)
        customAnalysisModel = analysisSettingsStore.customModel(for: selectedAnalysisTool)
        analysisPrompt = analysisSettingsStore.prompt
        usesDetectedAnalysisExecutable = analysisSettingsStore
            .executablePath(for: selectedAnalysisTool).isEmpty
        analysisExecutablePath = resolvedAnalysisExecutablePath(for: selectedAnalysisTool)
        if aiAnalysisEnabled {
            await refreshAnalysisToolStatus()
        } else {
            setAnalysisToolStatus(.unknown)
        }

        await refreshFluidAudioModelStatuses()
        refreshLegacyModelCleanupReport()
        await observeProcessingQueue()
        do { try await processingQueue.restore() }
        catch { lastError = localized(error) }
        await refreshRecoveryCandidates()
        hasPreparedStorage = true
        await runAutomaticRecordingAudioCleanup()
        if OnboardingStore.detectsExistingInstallation(defaults: notificationDefaults)
            || hadRecordingRootBeforePreparation
            || hasExistingRecordingSessions() {
            onboardingStore.markExistingInstallation()
            onboardingState = onboardingStore.state
        }
        isApplicationPrepared = true
    }

    /// Persists the opt-in and requests permission only when notifications are enabled.
    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationsEnabled = enabled
        notificationDefaults.set(enabled, forKey: "processingNotificationsEnabled")
        if enabled {
            await processingNotifier.requestAuthorization()
        }
    }

    func reprocessWithFluidAudio(session: RecordingSession) async throws -> TranscriptionRevisionResult {
        guard canEnqueueProcessing(sessionID: session.metadata.id) else { throw TranscriptionRevisionError.applicationBusy }
        let queued = try await sessionManager.queueProcessing(
            sessionID: session.metadata.id, kind: .retranscribe, configuration: processingConfiguration
        )
        await observeProcessingQueue()
        await processingQueue.accept(queued)
        let result = try await processingQueue.result(for: queued.metadata.processing!.attemptID)
        guard let revision = result.revision else {
            throw NSError(domain: "MeetingScribe.Processing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: result.failureDescription ?? "Transcription revision failed."])
        }
        return revision
    }

    @discardableResult
    func reanalyze(session: RecordingSession) async throws -> URL {
        guard canEnqueueProcessing(sessionID: session.metadata.id) else { throw AnalysisRevisionError.applicationBusy }
        var configuration = processingConfiguration
        configuration.analysisConfiguration = configuredAnalysisConfiguration()
        let queued = try await sessionManager.queueProcessing(
            sessionID: session.metadata.id, kind: .reanalyze, configuration: configuration
        )
        await observeProcessingQueue()
        await processingQueue.accept(queued)
        let result = try await processingQueue.result(for: queued.metadata.processing!.attemptID)
        guard result.failedSteps.isEmpty, let path = result.artifacts.output?.markdownPath else {
            throw NSError(domain: "MeetingScribe.Processing", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: result.failureDescription ?? "Analysis failed."])
        }
        return URL(fileURLWithPath: path)
    }

    func startRecording() async {
        await startRecording(isOnboardingTest: false)
    }

    private func startRecording(isOnboardingTest: Bool) async {
        if let operation = startRecordingOperation {
            await operation.task.value
            return
        }
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartRecording(isOnboardingTest: isOnboardingTest)
        }
        startRecordingOperation = (operationID, task)
        await task.value
        if startRecordingOperation?.id == operationID {
            startRecordingOperation = nil
        }
    }

    private func performStartRecording(isOnboardingTest: Bool) async {
        do {
            if let markdownFileNameTemplateError {
                lastError = markdownFileNameTemplateError
                return
            }
            guard canStartRecording else { return }
            if status == .completed || status == .failed { reset() }
            try transition(to: .preparing)
            lastError = nil
            lastMarkdownURL = nil
            isStoppingForLowStorage = false
            isStoppingForCaptureFailure = false
            storageCheckTick = 0
            storageCheckFailureCount = 0
            stalledSystemAudioCheckTick = 0

            let session = try await sessionManager.startSession(
                title: isOnboardingTest ? Self.onboardingTestSessionTitle : meetingTitle,
                language: selectedTranscriptionLanguage,
                outputLanguage: selectedOutputLanguage,
                outputFileNameTemplate: markdownFileNameTemplate,
                calendarEvent: isOnboardingTest ? nil : pendingCalendarEvent,
                notes: isOnboardingTest ? nil : meetingNotesDraft,
                analysisConfiguration: isOnboardingTest ? nil : currentAnalysisConfiguration()
            )
            currentSession = session
            if isOnboardingTest {
                onboardingTestSessionID = session.metadata.id
            } else {
                pendingCalendarEvent = nil
            }
            try? await processingLogger.log(.sessionCreated, for: session)
            if let notes = session.metadata.notes {
                try? await processingLogger.log(
                    .noteSaved,
                    for: session,
                    attributes: [.characterCount(notes.characterCount)]
                )
            }

            do {
                let diagnostics = try await captureCoordinator.start(for: session)
                updateCaptureDiagnostics(diagnostics)
                if isOnboardingTest {
                    onboardingTestStartedAt = diagnostics.systemAudio.startedAt ?? Date()
                }
                try transition(to: .recording)
            } catch {
                let diagnostics = await captureCoordinator.stop()
                let failedSession = try? await sessionManager.failSession(
                    reason: error.localizedDescription,
                    systemAudio: diagnostics.systemAudio.sessionMetadata,
                    microphoneAudio: diagnostics.microphone.sessionMetadata
                )
                currentSession = nil
                lastCompletedSession = failedSession
                updateCaptureDiagnostics(diagnostics)
                if isOnboardingTest {
                    onboardingTestPhase = .failed
                    onboardingTestError = error.localizedDescription
                    onboardingTestSessionID = nil
                }
                try? await processingLogger.log(
                    .captureFailed,
                    for: session,
                    attributes: processingErrorAttributes(error)
                )
                throw error
            }

            try? await processingLogger.log(.captureStarted, for: session)
            startCaptureMonitoring()
            if isOnboardingTest {
                onboardingTestPhase = .recording
            }
        } catch {
            setFailure(error)
        }
    }

    func stopRecording() async {
        if let operation = stopRecordingOperation {
            await operation.task.value
            return
        }
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStopRecording()
        }
        stopRecordingOperation = (operationID, task)
        await task.value
        if stopRecordingOperation?.id == operationID {
            stopRecordingOperation = nil
        }
    }

    private func performStopRecording() async {
        guard let session = currentSession,
              status == .recording || pendingCaptureHandoff?.sessionID == session.metadata.id else { return }
        let stoppedOnboardingTestSessionID = (currentSession?.metadata.id ?? pendingCaptureHandoff?.sessionID)
            .flatMap { sessionID in
                onboardingTestSessionID == sessionID ? sessionID : nil
            }
        await flushMeetingNotes()
        do {
            if stoppedOnboardingTestSessionID != nil {
                onboardingTestTimer?.cancel()
                onboardingTestTimer = nil
                onboardingTestPhase = .processing
            }
            if pendingCaptureHandoff == nil {
                try transition(to: .stopping)
                let stoppedAt = Date()
                stopCaptureMonitoring()
                let diagnostics = await captureCoordinator.stop()
                updateCaptureDiagnostics(diagnostics)
                pendingCaptureHandoff = (session.metadata.id,
                    max(stoppedAt, session.metadata.startedAt ?? stoppedAt), diagnostics)
                try? await processingLogger.log(.captureStopped, for: session,
                    attributes: [.bufferCount(diagnostics.systemAudio.bufferCount), .frameCount(diagnostics.systemAudio.totalFrames)])
            }
            guard let handoff = pendingCaptureHandoff else { return }
            let queued = try await sessionManager.finishCaptureAndQueue(
                expectedSessionID: handoff.sessionID, endedAt: handoff.endedAt,
                diagnostics: handoff.diagnostics, configuration: processingConfiguration
            )
            pendingCaptureHandoff = nil
            currentSession = nil
            if stoppedOnboardingTestSessionID == nil {
                meetingTitle = ""
                meetingNotesDraft = ""
                pendingCalendarEvent = nil
                calendarEventCandidates = []
            }
            // Capture is now independent of all subsequent processing.
            stateMachine = AppStateMachine()
            status = .idle
            await observeProcessingQueue()
            await processingQueue.accept(queued)
        } catch {
            // Keep the stopped capture and original diagnostics until the durable handoff succeeds.
            lastError = localized(error)
            status = .failed
            stateMachine = AppStateMachine(status: .failed)
            if let stoppedOnboardingTestSessionID,
               onboardingTestSessionID == stoppedOnboardingTestSessionID {
                onboardingTestPhase = .failed
                onboardingTestError = localized(error)
                clearOnboardingTestSessionState()
            }
        }
    }

    var canStartOnboardingTest: Bool {
        status == .idle || status == .completed || status == .failed
    }

    var onboardingTestArtifactDestinationURL: URL {
        outputFolderURL ?? sessionManager.recordingsRoot
    }

    var onboardingTestAudioDestinationURL: URL {
        sessionManager.recordingsRoot
    }

    func onboardingTestRemainingSeconds(at date: Date = Date()) -> Int? {
        guard onboardingTestPhase == .recording,
              let startedAt = onboardingTestStartedAt else { return nil }
        return max(0, Int((startedAt.addingTimeInterval(10).timeIntervalSince(date)).rounded(.up)))
    }

    func startOnboardingTest() async {
        guard onboardingTestPhase == .idle
            || onboardingTestPhase == .completed
            || onboardingTestPhase == .failed else {
            onboardingTestError = localized(.onboardingTestAlreadyRunning)
            return
        }

        guard canStartOnboardingTest,
              !status.isProcessing,
              status != .recording,
              !hasPendingProcessing,
              !isRecoveringSession,
              !isScanningRecordingAudio,
              !isCleaningRecordingAudio,
              recoveryCandidates.isEmpty,
              recoveryIssues.isEmpty else {
            onboardingTestError = localized(.onboardingTestUnavailableWhileBusy)
            return
        }

        onboardingTestResult = nil
        onboardingTestError = nil
        onboardingTestPhase = .starting
        onboardingTestStartedAt = nil
        isOnboardingTestStopRequested = false
        await startRecording(isOnboardingTest: true)

        if isOnboardingTestStopRequested {
            isOnboardingTestStopRequested = false
            guard status == .recording,
                  let session = currentSession,
                  session.metadata.id == onboardingTestSessionID else {
                onboardingTestPhase = .failed
                onboardingTestError = lastError ?? localized(.onboardingTestCouldNotStart)
                clearOnboardingTestSessionState()
                return
            }
            await finishOnboardingTest()
            return
        }

        guard status == .recording,
              let session = currentSession,
              session.metadata.title == Self.onboardingTestSessionTitle else {
            onboardingTestPhase = .failed
            onboardingTestError = lastError ?? localized(.onboardingTestCouldNotStart)
            return
        }

        onboardingTestSessionID = session.metadata.id
        onboardingTestPhase = .recording
        scheduleOnboardingTestTimeout()
    }

    func stopOnboardingTest() async {
        if onboardingTestPhase == .starting {
            isOnboardingTestStopRequested = true
            return
        }
        await finishOnboardingTest()
    }

    private func scheduleOnboardingTestTimeout() {
        onboardingTestTimer?.cancel()
        let delay = onboardingTestDelay
        let remainingSeconds = onboardingTestStartedAt.map {
            max(0, $0.addingTimeInterval(10).timeIntervalSinceNow)
        } ?? 10
        onboardingTestTimer = Task { [weak self] in
            do {
                try await delay.sleep(for: remainingSeconds)
                await self?.finishOnboardingTest()
            } catch is CancellationError {
            } catch {
                self?.failOnboardingTestTimer(error: error)
            }
        }
    }

    private func failOnboardingTestTimer(error: Error) {
        guard onboardingTestPhase == .recording else { return }
        onboardingTestError = error.localizedDescription
    }

    private func finishOnboardingTest() async {
        guard onboardingTestPhase == .recording,
              status == .recording,
              let session = currentSession,
              session.metadata.id == onboardingTestSessionID else {
            return
        }

        onboardingTestTimer?.cancel()
        onboardingTestTimer = nil
        onboardingTestPhase = .processing
        await stopRecording()
    }

    private func finalizeOnboardingTestAfterProcessing(
        session: RecordingSession,
        result: SessionProcessingResult?
    ) async {
        guard let sessionID = onboardingTestSessionID,
              session.metadata.id == sessionID,
              isOnboardingTestSession(session) else {
            return
        }

        let testResult = await makeOnboardingTestResult(
            session: session,
            processingResult: result
        )
        onboardingTestResult = testResult
        let missingModelIsOnlyFailure = testResult?.transcriptionStatus == .modelMissing
            && result?.failedSteps == [.transcribing]
        let processingFailed = session.metadata.processing?.state == .failed
        onboardingTestPhase = processingFailed && !missingModelIsOnlyFailure ? .failed : .completed
        if onboardingTestPhase == .failed, onboardingTestError == nil {
            onboardingTestError = result?.failureDescription ?? lastError
        }
        clearOnboardingTestSessionState()
    }

    private func makeOnboardingTestResult(
        session: RecordingSession,
        processingResult: SessionProcessingResult?
    ) async -> OnboardingTestResult? {
        guard let sessionID = onboardingTestSessionID,
              session.metadata.id == sessionID,
              isOnboardingTestSession(session) else {
            return nil
        }

        let diagnostics = captureDiagnostics
        var transcriptionStatus = session.metadata.transcription?.status
        var transcriptionFailureReason = session.metadata.transcription?.failureReason
        if transcriptionStatus == .failed,
           processingResult?.failedSteps.contains(.transcribing) == true,
           await isTranscriptionModelUnavailable() {
            transcriptionStatus = .modelMissing
            transcriptionFailureReason = nil
        }

        let markdownURL = processingResult?.revision.flatMap { revision in
            revision.manifest.markdownFileName.map {
                revision.directoryURL.appendingPathComponent($0)
            }
        } ?? session.metadata.output?.markdownPath.map { URL(fileURLWithPath: $0) }

        return OnboardingTestResult(
            sessionID: sessionID,
            title: session.metadata.title,
            systemAudio: OnboardingTestTrackResult(
                id: "system",
                diagnostics: diagnostics.systemAudio
            ),
            microphone: OnboardingTestTrackResult(
                id: "microphone",
                diagnostics: diagnostics.microphone
            ),
            transcriptionStatus: transcriptionStatus,
            transcriptionFailureReason: transcriptionFailureReason,
            markdownURL: markdownURL,
            sessionDirectoryURL: session.directoryURL,
            error: onboardingTestError
        )
    }

    private func isTranscriptionModelUnavailable() async -> Bool {
        switch await fluidAudioModelManager.status(for: .parakeetV3) {
        case .missing, .invalid:
            return true
        case .ready:
            return false
        }
    }

    private func clearOnboardingTestSessionState() {
        onboardingTestSessionID = nil
        onboardingTestStartedAt = nil
        isOnboardingTestStopRequested = false
    }

    private func isOnboardingTestSession(_ session: RecordingSession) -> Bool {
        session.metadata.id == onboardingTestSessionID
            && session.metadata.title == Self.onboardingTestSessionTitle
    }

    func renameCurrentSession(to title: String) async {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let currentSession, isOnboardingTestSession(currentSession) {
            return
        }
        guard !normalizedTitle.isEmpty,
              normalizedTitle != currentSession?.metadata.title else {
            return
        }

        let expectedID = currentSession?.metadata.id
        do {
            let renamedSession = try await sessionManager.renameActiveSession(
                to: normalizedTitle
            )
            guard currentSession?.metadata.id == expectedID else { return }
            currentSession = renamedSession
            meetingTitle = renamedSession.metadata.title
        } catch {
            lastError = "The meeting title could not be updated: \(error.localizedDescription)"
        }
    }

    func updateMeetingNotes(_ text: String) async {
        meetingNotesDraft = text
        guard let activeSession = currentSession,
              !isOnboardingTestSession(activeSession) else {
            return
        }

        do {
            let updatedSession = try await sessionManager.updateActiveSessionNotes(text)
            currentSession = updatedSession
        } catch {
            lastError = localized(error)
        }
    }

    func flushMeetingNotes() async {
        guard let currentSession,
              !isOnboardingTestSession(currentSession) else {
            return
        }

        do {
            let updatedSession = try await sessionManager.updateActiveSessionNotes(meetingNotesDraft)
            self.currentSession = updatedSession
            if let notes = updatedSession.metadata.notes {
                try? await processingLogger.log(
                    .noteSaved,
                    for: updatedSession,
                    attributes: [.characterCount(notes.characterCount)]
                )
            }
        } catch {
            lastError = localized(error)
        }
    }

    var currentMeetingNotes: String {
        meetingNotesDraft
    }

    func loadMeetingNotesFromDisk() async {
        guard let activeSession = currentSession,
              !isOnboardingTestSession(activeSession),
              activeSession.metadata.notes != nil,
              meetingNotesDraft.isEmpty else {
            return
        }

        let sessionID = activeSession.metadata.id
        let notesURL = activeSession.notesURL
        let notes: String
        do {
            notes = try await Task.detached(priority: .utility) {
                try String(contentsOf: notesURL, encoding: .utf8)
            }.value
        } catch {
            return
        }

        guard let currentSession,
              currentSession.metadata.id == sessionID,
              !isOnboardingTestSession(currentSession),
              meetingNotesDraft.isEmpty else {
            return
        }
        meetingNotesDraft = notes
    }

    func recoverSession(_ candidate: SessionRecoveryCandidate) async {
        guard canEnqueueProcessing(sessionID: candidate.id) else { return }
        do {
            let queued = try await sessionManager.queueProcessing(
                sessionID: candidate.id, kind: .recovery, configuration: processingConfiguration
            )
            removeRecoveryCandidate(id: candidate.id)
            await observeProcessingQueue()
            await processingQueue.accept(queued)
        } catch { lastError = localized(error) }
    }

    func closeRecovery(_ candidate: SessionRecoveryCandidate) async {
        guard canEnqueueProcessing(sessionID: candidate.id) else { return }
        do {
            let closed = try await sessionManager.closeRecovery(id: candidate.id)
            lastCompletedSession = closed
            try? await processingLogger.log(.recoveryClosed, for: closed)
            removeRecoveryCandidate(id: candidate.id)
            lastError = nil
        } catch {
            lastError = localized(error)
        }
    }

    func closeRecoveryIssue(_ issue: SessionRecoveryIssue) async {
        do {
            try await sessionManager.closeRecoveryIssue(
                directoryName: issue.directoryName
            )
            recoveryIssues.removeAll { $0.id == issue.id }
            lastError = nil
        } catch {
            lastError = localized(error)
        }
    }

    func revealRecovery(_ candidate: SessionRecoveryCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([candidate.session.manifestURL])
    }

    func revealRecoveryIssue(_ issue: SessionRecoveryIssue) {
        let directoryURL = sessionManager.recordingsRoot.appendingPathComponent(
            issue.directoryName,
            isDirectory: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    func requestRecordingsOverview(for session: RecordingSession) {
        requestRecordingsOverview(
            sessionID: session.metadata.id,
            occurredAt: session.metadata.startedAt ?? session.metadata.createdAt
        )
    }

    func requestRecordingsOverview(sessionID: String, occurredAt: Date) {
        recordingsNavigationRequest = RecordingsNavigationRequest(
            requestID: UUID(), sessionID: sessionID, occurredAt: occurredAt
        )
    }

    func reset() {
        guard currentSession == nil else { return }
        guard status == .completed || status == .failed else { return }

        do {
            try transition(to: .idle)
            lastError = nil
            updateCaptureDiagnostics(.empty)
            resetProcessingProgress()
            isStoppingForLowStorage = false
            isStoppingForCaptureFailure = false
            storageCheckFailureCount = 0
        } catch {
            setFailure(error)
        }
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(sessionManager.recordingsRoot)
    }

    func revealLastSession() {
        guard let session = lastCompletedSession ?? currentSession else {
            openRecordingsFolder()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([session.manifestURL])
    }

    func revealLastProcessingLog() {
        guard let session = lastCompletedSession ?? currentSession else {
            openRecordingsFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([session.processingLogURL])
    }

    var outputFolderDescription: String {
        outputFolderURL?.path ?? localized(.recordingSessionFolderDescription)
    }

    var readinessConfiguration: ReadinessConfiguration {
        ReadinessConfiguration(
            captureMode: .systemAndMicrophone,
            outputFolderURL: outputFolderURL,
            outputFileNameTemplate: markdownFileNameTemplate,
            aiAnalysis: ReadinessOptionalFeature(isEnabled: aiAnalysisEnabled),
            calendar: ReadinessOptionalFeature(
                isEnabled: calendarIntegrationEnabled,
                authorization: readinessPermissionStatus(for: calendarAuthorizationStatus)
            ),
            notifications: ReadinessOptionalFeature(isEnabled: notificationsEnabled)
        )
    }

    var onboardingStep: OnboardingStep {
        onboardingState.step
    }

    var shouldShowOnboardingInvitation: Bool {
        onboardingStore.shouldShowInvitation
    }

    var shouldOpenOnboardingOnLaunch: Bool {
        onboardingStore.shouldOpenOnLaunch
    }

    func refreshReadiness() async {
        guard !isRefreshingReadiness else { return }
        isRefreshingReadiness = true
        defer { isRefreshingReadiness = false }

        do {
            readinessSnapshot = try await readinessService.refresh(readinessConfiguration)
            readinessError = nil
        } catch {
            readinessError = localized(.readinessRefreshFailed(localized(error)))
        }
    }

    func performReadinessAction(
        _ action: ReadinessAction,
        openSettings: () -> Void
    ) async {
        switch action {
        case .requestSystemAudioPermission:
            requestSystemAudioPermission()
        case .openSystemAudioSettings:
            openSystemAudioPrivacySettings()
        case .requestMicrophonePermission:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted:
                openMicrophonePrivacySettings()
            default:
                await requestMicrophonePermission()
            }
        case .connectMicrophoneInput:
            openSystemAudioPrivacySettings()
        case .freeStorageSpace, .fixStorageAccess:
            openRecordingsFolder()
        case .downloadTranscriptionModel:
            installFluidAudioModel(.transcription)
        case .importTranscriptionModel:
            await importFluidAudioModel(.transcription)
        case .repairTranscriptionModel:
            installFluidAudioModel(.transcription, repair: true)
        case .chooseOutputFolder:
            chooseOutputFolder()
        case .useSessionFolder:
            useDefaultOutputFolder()
        case .fixOutputFileNameTemplate:
            selectedSettingsSection = "output"
            openSettings()
        case .openAISettings:
            selectedSettingsSection = "ai"
            openSettings()
        case .disableAI:
            aiAnalysisEnabled = false
            analysisEnabledDidChange()
        case .openCalendarSettings:
            openCalendarPrivacySettings()
        case .openNotificationSettings:
            openNotificationPrivacySettings()
        case .none:
            break
        }

        if refreshesAfterAction(action) {
            await refreshReadiness()
        }
    }

    func requestSystemAudioPermission() {
        CGRequestScreenCaptureAccess()
    }

    func requestMicrophonePermission() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    func openSystemAudioPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func deferOnboarding() {
        onboardingStore.deferOnboarding()
        onboardingState = onboardingStore.state
    }

    func resumeOnboarding() {
        onboardingStore.resume()
        onboardingState = onboardingStore.state
        requestOnboardingWindow()
    }

    func setOnboardingStep(_ step: OnboardingStep) {
        onboardingStore.setStep(step)
        onboardingState = onboardingStore.state
    }

    func advanceOnboarding() {
        onboardingStore.advance()
        onboardingState = onboardingStore.state
    }

    func moveToPreviousOnboardingStep() {
        let steps = OnboardingStep.allCases
        guard let index = steps.firstIndex(of: onboardingState.step), index > 0 else { return }
        setOnboardingStep(steps[index - 1])
    }

    func completeOnboarding() {
        onboardingStore.complete()
        onboardingState = onboardingStore.state
    }

    func markOnboardingPresentedOnLaunch() {
        onboardingStore.markPresentedOnLaunch()
        onboardingState = onboardingStore.state
    }

    func requestOnboardingWindow() {
        onboardingWindowRequest = UUID()
    }

    func clearOnboardingWindowRequest() {
        onboardingWindowRequest = nil
    }

    private func refreshesAfterAction(_ action: ReadinessAction) -> Bool {
        switch action {
        case
            .requestSystemAudioPermission,
            .openSystemAudioSettings,
            .requestMicrophonePermission,
            .connectMicrophoneInput,
            .chooseOutputFolder,
            .useSessionFolder,
            .disableAI:
            return true
        default:
            return false
        }
    }

    private func readinessPermissionStatus(
        for status: CalendarAuthorizationStatus
    ) -> ReadinessPermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        case .fullAccess: return .granted
        }
    }

    private func hasExistingRecordingSessions() -> Bool {
        let fileManager = FileManager.default
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: sessionManager.recordingsRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else {
            return false
        }
        return children.contains { child in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
            return fileManager.fileExists(
                atPath: child.appendingPathComponent("session.json", isDirectory: false).path
            )
        }
    }

    private func openNotificationPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    var canOpenLastMarkdownInObsidian: Bool {
        guard let lastMarkdownURL else { return false }
        return obsidianService.openURL(for: lastMarkdownURL) != nil
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = localized(.chooseOutputFolderTitle)
        panel.prompt = localized(.choose)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolderURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try outputFolderStore.selectFolder(url)
            outputFolderURL = url.standardizedFileURL
            lastError = nil
        } catch {
            lastError = localized(.outputFolderSave(localized(error)))
        }
    }

    func useDefaultOutputFolder() {
        outputFolderStore.clearFolder()
        outputFolderURL = nil
    }

    func openLastMarkdown() {
        guard let lastMarkdownURL else { return }
        NSWorkspace.shared.open(lastMarkdownURL)
    }

    func revealLastMarkdown() {
        guard let lastMarkdownURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastMarkdownURL])
    }

    func openLastMarkdownInObsidian() {
        guard let lastMarkdownURL,
              let url = obsidianService.openURL(for: lastMarkdownURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func persistAnalysisSettings() {
        analysisSettingsStore.setEnabled(aiAnalysisEnabled)
        analysisSettingsStore.setTool(selectedAnalysisTool)
        analysisSettingsStore.setModelSelection(
            selectedAnalysisModel,
            for: selectedAnalysisTool
        )
        analysisSettingsStore.setCustomModel(
            customAnalysisModel,
            for: selectedAnalysisTool
        )
        analysisSettingsStore.setPrompt(analysisPrompt)
        analysisSettingsStore.setExecutablePath(
            usesDetectedAnalysisExecutable ? "" : analysisExecutablePath,
            for: selectedAnalysisTool
        )
    }

    func analysisEnabledDidChange() {
        persistAnalysisSettings()
        if aiAnalysisEnabled {
            Task { await refreshAnalysisToolStatus() }
        } else {
            setAnalysisToolStatus(.unknown)
        }
    }

    func analysisToolSelectionDidChange() {
        analysisSettingsStore.setTool(selectedAnalysisTool)
        selectedAnalysisModel = analysisSettingsStore.modelSelection(for: selectedAnalysisTool)
        customAnalysisModel = analysisSettingsStore.customModel(for: selectedAnalysisTool)
        usesDetectedAnalysisExecutable = analysisSettingsStore
            .executablePath(for: selectedAnalysisTool).isEmpty
        analysisExecutablePath = resolvedAnalysisExecutablePath(for: selectedAnalysisTool)
        persistAnalysisSettings()
        setAnalysisToolStatus(.unknown)
        Task { await refreshAnalysisToolStatus() }
    }

    var analysisModelOptions: [AnalysisModelSelection] {
        AnalysisModelSelection.options(for: selectedAnalysisTool)
    }

    var resolvedAnalysisModel: String? {
        selectedAnalysisModel.resolvedModel(customModel: customAnalysisModel)
    }

    func resetAnalysisPrompt() {
        analysisPrompt = AnalysisPrompt.defaultTemplate
        persistAnalysisSettings()
    }

    func chooseAnalysisExecutable() {
        let panel = NSOpenPanel()
        panel.title = localized(.chooseAnalysisExecutableTitle(selectedAnalysisTool.displayName))
        panel.prompt = localized(.choose)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        usesDetectedAnalysisExecutable = false
        analysisExecutablePath = url.standardizedFileURL.path
        persistAnalysisSettings()
        Task { await refreshAnalysisToolStatus() }
    }

    func useDetectedAnalysisExecutable() {
        usesDetectedAnalysisExecutable = true
        analysisSettingsStore.setExecutablePath("", for: selectedAnalysisTool)
        analysisExecutablePath = resolvedAnalysisExecutablePath(for: selectedAnalysisTool)
        persistAnalysisSettings()
        Task { await refreshAnalysisToolStatus() }
    }

    func analysisExecutablePathDidChange() {
        usesDetectedAnalysisExecutable = false
        persistAnalysisSettings()
        Task { await refreshAnalysisToolStatus() }
    }

    func refreshAnalysisToolStatus() async {
        guard !isCheckingAnalysisTool else { return }
        isCheckingAnalysisTool = true
        defer { isCheckingAnalysisTool = false }

        guard let executableURL = AnalysisExecutableResolver.resolve(
            tool: selectedAnalysisTool,
            configuredPath: analysisExecutablePath
        ) else {
            setAnalysisToolStatus(.unavailable)
            return
        }
        analysisExecutablePath = executableURL.path
        do {
            let provider = CLIAnalysisProvider(
                tool: selectedAnalysisTool,
                executableURL: executableURL,
                model: resolvedAnalysisModel,
                runner: analysisCommandRunner
            )
            let version = try await provider.toolVersion()
            switch try await provider.authenticationStatus() {
            case .authenticated:
                setAnalysisToolStatus(.available(path: executableURL.path, version: version))
            case .authenticationRequired:
                setAnalysisToolStatus(.authenticationRequired(
                    path: executableURL.path,
                    version: version,
                    loginCommand: selectedAnalysisTool.loginCommand(
                        executableURL: executableURL
                    )
                ))
            }
            lastError = nil
        } catch {
            setAnalysisToolStatus(.failed(
                path: executableURL.path,
                reason: localized(error)
            ))
        }
    }

    private func setAnalysisToolStatus(_ status: AnalysisToolStatus) {
        analysisToolStatus = status
        readinessAnalysisStatusStore.update(status)
    }

    func copyAnalysisLoginCommandAndOpenTerminal() {
        guard case let .authenticationRequired(_, _, loginCommand) = analysisToolStatus else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(loginCommand, forType: .string)
        let terminalURL = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
            isDirectory: true
        )
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func resolvedAnalysisExecutablePath(for tool: AnalysisTool) -> String {
        let configured = analysisSettingsStore.executablePath(for: tool)
        return AnalysisExecutableResolver.resolve(tool: tool, configuredPath: configured)?.path
            ?? configured
    }

    private func currentAnalysisConfiguration() -> SessionAnalysisConfiguration? {
        guard aiAnalysisEnabled else { return nil }
        return configuredAnalysisConfiguration()
    }

    private func configuredAnalysisConfiguration() -> SessionAnalysisConfiguration {
        let executablePath = AnalysisExecutableResolver.resolve(
            tool: selectedAnalysisTool,
            configuredPath: analysisExecutablePath
        )?.path ?? analysisExecutablePath
        return SessionAnalysisConfiguration(
            tool: selectedAnalysisTool,
            executablePath: executablePath,
            model: resolvedAnalysisModel,
            prompt: analysisPrompt
        )
    }

    var canEditSessionConfiguration: Bool {
        switch status {
        case .idle, .completed, .failed:
            return currentSession == nil
        case .preparing, .recording, .stopping, .transcribing, .analyzing, .exporting:
            return false
        }
    }

    func persistTranscriptionLanguageSelection() {
        transcriptionSettingsStore.setSelectedLanguage(selectedTranscriptionLanguage)
    }

    func persistAudioRetentionSettings() {
        audioRetentionSettingsStore.setAutomaticallyDeleteSourceCAF(
            automaticallyDeleteSourceCAF
        )
    }

    func setAudioRetentionPolicy(_ policy: AudioRetentionPolicy) async {
        audioRetentionPolicy = policy
        audioRetentionSettingsStore.setPolicy(policy)
        await runAutomaticRecordingAudioCleanup()
    }

    func refreshRecordingAudioCleanupPlan() async {
        guard !isScanningRecordingAudio, !isCleaningRecordingAudio, !hasPendingProcessing, currentSession == nil else { return }
        isScanningRecordingAudio = true
        recordingAudioCleanupError = nil
        defer { isScanningRecordingAudio = false }
        do {
            recordingAudioCleanupPlan = try await recordingAudioCleanupService.scan()
        } catch {
            recordingAudioCleanupError = localized(error)
        }
    }

    func cleanProcessedRecordingAudio() async {
        guard !isScanningRecordingAudio, !isCleaningRecordingAudio,
              currentSession == nil, !hasPendingProcessing,
              fluidAudioReprocessingSessionID == nil,
              aiAnalysisReprocessingSessionID == nil else { return }
        isCleaningRecordingAudio = true
        recordingAudioCleanupError = nil
        defer { isCleaningRecordingAudio = false }
        do {
            let plan = try await recordingAudioCleanupService.scan()
            let report = try await recordingAudioCleanupService.execute(
                plan,
                trigger: .manual
            )
            recordingAudioCleanupReport = report
            recordingAudioCleanupPlan = try await recordingAudioCleanupService.scan()
            if !report.failures.isEmpty {
                recordingAudioCleanupError = report.failures.joined(separator: "\n")
            }
        } catch {
            recordingAudioCleanupError = localized(error)
        }
    }

    func setKeepRecordingAudio(
        _ keepAudio: Bool,
        for session: RecordingSession
    ) async throws {
        guard canEnqueueProcessing(sessionID: session.metadata.id),
              fluidAudioReprocessingSessionID == nil,
              aiAnalysisReprocessingSessionID == nil,
              !isCleaningRecordingAudio else {
            throw RecordingAudioCleanupError.sessionNotEligible(session.metadata.id)
        }
        _ = try await recordingAudioCleanupService.setKeepAudio(
            keepAudio,
            sessionID: session.metadata.id
        )
        await refreshRecordingAudioCleanupPlan()
    }

    private func runAutomaticRecordingAudioCleanup() async {
        guard let cutoff = audioRetentionPolicy.cutoffDate(now: Date()),
              !isScanningRecordingAudio,
              !isCleaningRecordingAudio,
              currentSession == nil, !hasPendingProcessing,
              fluidAudioReprocessingSessionID == nil,
              aiAnalysisReprocessingSessionID == nil else { return }
        isCleaningRecordingAudio = true
        defer { isCleaningRecordingAudio = false }
        do {
            let plan = try await recordingAudioCleanupService.scan(olderThan: cutoff)
            guard !plan.candidates.isEmpty else { return }
            let report = try await recordingAudioCleanupService.execute(
                plan,
                trigger: .automatic
            )
            recordingAudioCleanupReport = report
            if !report.failures.isEmpty {
                recordingAudioCleanupError = report.failures.joined(separator: "\n")
            }
        } catch {
            recordingAudioCleanupError = localized(error)
        }
    }

    func persistApplicationSettings() async {
        applicationSettingsStore.setAppLanguage(selectedAppLanguage)
        applicationSettingsStore.setOutputLanguage(selectedOutputLanguage)
        applicationSettingsStore.setMarkdownFileNameTemplate(markdownFileNameTemplate)
        applicationSettingsStore.setMinimumStorageBytes(minimumStorageBytes)
        await sessionManager.setMinimumStorageBytes(minimumStorageBytes)
        refreshProcessingResourceLimits()
        await updateResourcePolicy()
    }

    var approvedCalendarEvent: CalendarEventSnapshot? {
        currentSession?.metadata.calendarEvent ?? pendingCalendarEvent
    }

    var canChooseCalendarEvent: Bool {
        switch status {
        case .idle, .recording, .completed, .failed:
            return !isRecoveringSession
        case .preparing, .stopping, .transcribing, .analyzing, .exporting:
            return false
        }
    }

    func setCalendarIntegrationEnabled(_ enabled: Bool) {
        calendarIntegrationEnabled = enabled
        applicationSettingsStore.setCalendarIntegrationEnabled(enabled)
        calendarAuthorizationStatus = calendarEventProvider.authorizationStatus
        calendarAccessError = nil
        if !enabled {
            calendarEventCandidates = []
            if currentSession == nil {
                pendingCalendarEvent = nil
            }
        }
    }

    func refreshCalendarAuthorizationStatus() {
        calendarAuthorizationStatus = calendarEventProvider.authorizationStatus
        if calendarAuthorizationStatus.canReadEvents {
            calendarAccessError = nil
        }
    }

    func requestCalendarAccess() async {
        guard calendarIntegrationEnabled else {
            let message = localized(CalendarIntegrationError.integrationDisabled)
            calendarAccessError = message
            lastError = message
            return
        }

        isRequestingCalendarAccess = true
        calendarAccessError = nil
        defer { isRequestingCalendarAccess = false }

        do {
            NSApplication.shared.activate()
            await Task.yield()
            let granted = try await calendarEventProvider.requestFullAccess()
            calendarAuthorizationStatus = calendarEventProvider.authorizationStatus
            guard granted, calendarAuthorizationStatus.canReadEvents else {
                let message = localized(CalendarIntegrationError.fullAccessRequired)
                calendarAccessError = message
                lastError = message
                return
            }

            await loadCalendarEventCandidates()
            calendarAccessError = nil
            lastError = nil
        } catch {
            calendarAuthorizationStatus = calendarEventProvider.authorizationStatus
            let message = localized(error)
            calendarAccessError = message
            lastError = message
        }
    }

    func loadCalendarEventCandidates(now: Date = Date()) async {
        guard calendarIntegrationEnabled else {
            calendarEventCandidates = []
            return
        }
        calendarAuthorizationStatus = calendarEventProvider.authorizationStatus
        guard calendarAuthorizationStatus.canReadEvents else {
            calendarEventCandidates = []
            return
        }

        isLoadingCalendarEvents = true
        defer { isLoadingCalendarEvents = false }
        do {
            calendarEventCandidates = try calendarEventProvider.eventCandidates(
                for: calendarEventQuery(now: now)
            )
            lastError = nil
        } catch {
            calendarEventCandidates = []
            lastError = localized(error)
        }
    }

    func approveCalendarEvent(
        _ candidate: CalendarEventCandidate,
        participantIDs: Set<String>,
        eventDescription: String?,
        now: Date = Date()
    ) async -> Bool {
        let participants = candidate.participants.compactMap { participant -> ConfirmedParticipant? in
            guard participantIDs.contains(participant.id) else { return nil }
            return ConfirmedParticipant(displayName: participant.displayName)
        }
        let snapshot = CalendarEventSnapshot(
            source: .appleCalendar,
            title: candidate.title,
            startsAt: candidate.startsAt,
            endsAt: candidate.endsAt,
            selectedAt: now,
            participants: participants,
            shareParticipantNamesWithAnalysis: !participants.isEmpty,
            eventDescription: normalizedCalendarDescription(eventDescription)
        )

        do {
            if currentSession != nil {
                let updated = try await sessionManager.updateActiveSessionCalendarEvent(
                    snapshot,
                    title: candidate.title
                )
                currentSession = updated
                meetingTitle = updated.metadata.title
            } else {
                pendingCalendarEvent = snapshot
                meetingTitle = candidate.title
            }
            calendarEventCandidates = []
            lastError = nil
            return true
        } catch {
            lastError = localized(error)
            return false
        }
    }

    private func normalizedCalendarDescription(_ description: String?) -> String? {
        let normalized = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    func clearCalendarSelection() async {
        do {
            if currentSession != nil {
                currentSession = try await sessionManager.updateActiveSessionCalendarEvent(nil)
            } else {
                pendingCalendarEvent = nil
            }
            lastError = nil
        } catch {
            lastError = localized(error)
        }
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func calendarEventQuery(now: Date) -> CalendarEventQuery {
        let grace: TimeInterval = 15 * 60
        let targetStart: Date
        let targetEnd: Date
        if status == .recording, let startedAt = currentSession?.metadata.startedAt {
            targetStart = min(startedAt, now).addingTimeInterval(-grace)
            targetEnd = max(startedAt, now).addingTimeInterval(grace)
        } else {
            targetStart = now.addingTimeInterval(-grace)
            targetEnd = now.addingTimeInterval(grace)
        }

        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: targetStart)
        let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: targetEnd)
        ) ?? targetEnd.addingTimeInterval(24 * 60 * 60)
        return CalendarEventQuery(
            targetInterval: DateInterval(start: targetStart, end: targetEnd),
            searchInterval: DateInterval(start: dayStart, end: max(nextDay, targetEnd))
        )
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            lastError = nil
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            lastError = localized(.launchAtLogin(localized(error)))
        }
    }

    var markdownFileNameTemplateError: String? {
        let unsupported = MarkdownFileNameTemplate.unsupportedTokens(in: markdownFileNameTemplate)
        guard unsupported.isEmpty else {
            return localized(.unsupportedToken(unsupported.joined(separator: ", ")))
        }
        return nil
    }

    var fluidAudioASRDescriptor: FluidAudioModelDescriptor {
        .parakeetV3
    }

    func refreshFluidAudioModelStatuses() async {
        fluidAudioModelState.asrStatus = localizedFluidAudioStatus(
            await fluidAudioModelManager.status(for: fluidAudioASRDescriptor)
        )
    }

    func refreshLegacyModelCleanupReport() {
        legacyModelCleanupReport = legacyModelCleaner.report()
    }

    func removeLegacyModels() {
        guard !isRemovingLegacyModels else { return }
        isRemovingLegacyModels = true
        defer { isRemovingLegacyModels = false }
        do {
            try legacyModelCleaner.remove()
            lastError = nil
        } catch {
            lastError = localized(.legacyModelDelete(localized(error)))
        }
        refreshLegacyModelCleanupReport()
    }

    func installFluidAudioModel(
        _ kind: FluidAudioModelKind,
        repair: Bool = false
    ) {
        guard canChangeModels, fluidAudioInstallTasks[kind] == nil else { return }
        setFluidAudioInstalling(true, kind: kind)
        setFluidAudioProgress(
            .init(
                fractionCompleted: 0,
                downloadedBytes: 0,
                totalBytes: descriptor(for: kind).approximateSizeBytes
            ),
            kind: kind
        )
        lastError = nil
        fluidAudioInstallTasks[kind] = Task { [weak self] in
            await self?.performFluidAudioInstallation(kind: kind, repair: repair)
        }
    }

    func cancelFluidAudioModelInstallation(_ kind: FluidAudioModelKind) {
        fluidAudioInstallTasks[kind]?.cancel()
    }

    func importFluidAudioModel(_ kind: FluidAudioModelKind) async {
        guard canChangeModels, fluidAudioInstallTasks[kind] == nil else { return }
        let descriptor = descriptor(for: kind)
        let panel = NSOpenPanel()
        panel.title = localized(.importFluidAudioModelTitle(descriptor.displayName))
        panel.prompt = localized(.importAction)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        setFluidAudioInstalling(true, kind: kind)
        defer { setFluidAudioInstalling(false, kind: kind) }
        do {
            _ = try await fluidAudioModelManager.importBundle(
                from: sourceURL,
                as: descriptor
            )
            lastError = nil
        } catch {
            lastError = localized(.fluidAudioModelImport(
                descriptor.displayName,
                localized(error)
            ))
        }
        await refreshFluidAudioModelStatus(kind)
        await refreshReadiness()
    }

    func deleteFluidAudioModel(_ kind: FluidAudioModelKind) async {
        guard canChangeModels, fluidAudioInstallTasks[kind] == nil else { return }
        let descriptor = descriptor(for: kind)
        do {
            try await fluidAudioModelManager.removeModel(descriptor)
            lastError = nil
        } catch {
            lastError = localized(.fluidAudioModelDelete(
                descriptor.displayName,
                localized(error)
            ))
        }
        await refreshFluidAudioModelStatus(kind)
    }

    private func performFluidAudioInstallation(
        kind: FluidAudioModelKind,
        repair: Bool
    ) async {
        let descriptor = descriptor(for: kind)
        defer {
            fluidAudioInstallTasks[kind] = nil
            setFluidAudioInstalling(false, kind: kind)
            setFluidAudioProgress(nil, kind: kind)
        }
        do {
            _ = try await fluidAudioModelManager.install(
                descriptor,
                repair: repair
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.setFluidAudioProgress(progress, kind: kind)
                }
            }
            lastError = nil
        } catch is CancellationError {
            lastError = nil
        } catch {
            lastError = localized(.fluidAudioModelDownload(
                descriptor.displayName,
                localized(error)
            ))
        }
        await refreshFluidAudioModelStatus(kind)
        await refreshReadiness()
    }

    private func refreshFluidAudioModelStatus(_ kind: FluidAudioModelKind) async {
        let status = localizedFluidAudioStatus(
            await fluidAudioModelManager.status(for: descriptor(for: kind))
        )
        switch kind {
        case .transcription:
            fluidAudioModelState.asrStatus = status
        }
    }

    private func descriptor(
        for kind: FluidAudioModelKind
    ) -> FluidAudioModelDescriptor {
        switch kind {
        case .transcription: return fluidAudioASRDescriptor
        }
    }

    private func setFluidAudioInstalling(
        _ installing: Bool,
        kind: FluidAudioModelKind
    ) {
        switch kind {
        case .transcription:
            fluidAudioModelState.isInstallingASRModel = installing
        }
    }

    private func setFluidAudioProgress(
        _ progress: FluidAudioModelDownloadProgress?,
        kind: FluidAudioModelKind
    ) {
        switch kind {
        case .transcription:
            fluidAudioModelState.asrDownloadProgress = progress
        }
    }

    private func localizedFluidAudioStatus(
        _ status: FluidAudioModelStatus
    ) -> FluidAudioModelStatus {
        guard case .invalid = status else { return status }
        return .invalid(reason: localized(.fluidAudioModelInvalid))
    }

    private func refreshRecoveryCandidates() async {
        do {
            let result = try await sessionManager.scanForRecovery()
            recoveryCandidates = result.candidates
            recoveryIssues = result.issues
            for candidate in result.candidates {
                try? await processingLogger.log(.recoveryDetected, for: candidate.session)
            }
            if !result.issues.isEmpty, lastError == nil {
                lastError = localized(.recoveryIssues)
            }
        } catch {
            recoveryCandidates = []
            recoveryIssues = []
            lastError = localized(.recoveryScan(localized(error)))
        }
    }

    private func removeRecoveryCandidate(id: String) {
        recoveryCandidates.removeAll { $0.id == id }
    }

    private func refreshRecoveryCandidate(id: String) async {
        do {
            if let candidate = try await sessionManager.recoveryCandidate(id: id) {
                if let index = recoveryCandidates.firstIndex(where: { $0.id == id }) {
                    recoveryCandidates[index] = candidate
                } else {
                    recoveryCandidates.append(candidate)
                }
            } else {
                removeRecoveryCandidate(id: id)
            }
        } catch {
            // The original recovery error remains the actionable error.
        }
    }

    private func transition(to nextStatus: AppStatus) throws {
        try stateMachine.transition(to: nextStatus)
        status = stateMachine.status
    }

    private func setFailure(_ error: Error) {
        stopCaptureMonitoring()
        lastError = localized(error)
        if let activeStep = processingSteps.first(where: { $0.state == .active })?.id {
            setProcessingStep(activeStep, to: .failed)
        }

        if status != .failed {
            do {
                try stateMachine.transition(to: .failed)
                status = stateMachine.status
            } catch {
                lastError = "\(lastError ?? localized(.unknownError)) \(localized(error))"
            }
        }
    }

    func localized(_ message: AppUserMessage) -> String {
        AppLocalization.message(message, language: selectedAppLanguage)
    }

    private func localized(_ error: Error) -> String {
        AppLocalization.error(error, language: selectedAppLanguage)
    }

    func errorMessage(for error: Error) -> String {
        localized(error)
    }

    private func processingErrorAttributes(_ error: Error) -> [ProcessingLogAttribute] {
        let error = error as NSError
        return [
            .errorDomain(error.domain),
            .errorCode(error.code),
        ]
    }

    private func resetProcessingProgress() {
        processingSteps = ProcessingStep.initial
    }

    private func setProcessingStep(
        _ id: ProcessingStepID,
        to state: ProcessingStepState
    ) {
        guard let index = processingSteps.firstIndex(where: { $0.id == id }) else { return }
        processingSteps[index].state = state
    }

    private func startCaptureMonitoring() {
        stopCaptureMonitoring()
        let monitoringConfiguration = captureMonitoringConfiguration

        captureMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: monitoringConfiguration.interval)
                } catch {
                    break
                }

                guard let self else { break }
                let captureID = self.currentSession?.metadata.id
                let diagnostics = await self.captureCoordinator.diagnostics()
                guard !Task.isCancelled, self.status == .recording,
                      self.currentSession?.metadata.id == captureID else { break }
                self.updateCaptureDiagnostics(diagnostics)
                let requiredAudioHealth: AudioCaptureHealth
                if self.currentSession?.metadata.resolvedCaptureMode == .microphoneOnly {
                    requiredAudioHealth = diagnostics.microphone.health()
                } else {
                    requiredAudioHealth = diagnostics.systemAudio.health()
                }

                if requiredAudioHealth == .stalled {
                    self.stalledSystemAudioCheckTick += 1
                } else {
                    self.stalledSystemAudioCheckTick = 0
                }

                if requiredAudioHealth == .failed {
                    if await self.stopRecordingForCaptureFailure(
                        message: self.localized(.captureFailedSafeStop)
                    ) {
                        break
                    }
                }

                let stalledCheckCount = max(
                    1,
                    monitoringConfiguration.stalledSystemAudioCheckCount
                )
                if requiredAudioHealth == .stalled,
                   self.stalledSystemAudioCheckTick >= stalledCheckCount {
                    if await self.stopRecordingForCaptureFailure(
                        message: self.localized(.captureStalledSafeStop)
                    ) {
                        break
                    }
                }

                self.storageCheckTick += 1
                let storageFrequency = max(
                    1,
                    monitoringConfiguration.storageCheckEveryTicks
                )
                guard self.storageCheckTick.isMultiple(of: storageFrequency),
                      !self.isStoppingForLowStorage else {
                    continue
                }

                let storage: StorageStatus
                do {
                    storage = try await self.storageStatusProvider()
                    self.storageCheckFailureCount = 0
                } catch is CancellationError {
                    break
                } catch {
                    self.storageCheckFailureCount += 1
                    let maximumFailures = max(
                        1,
                        monitoringConfiguration.maximumStorageCheckFailures
                    )
                    guard self.storageCheckFailureCount >= maximumFailures else {
                        continue
                    }
                    if await self.stopRecordingForCaptureFailure(
                        message: self.localized(.storageCheckFailedSafeStop)
                    ) {
                        break
                    }
                    continue
                }

                guard !storage.hasSufficientCapacity else { continue }

                guard !Task.isCancelled, self.status == .recording else {
                    break
                }

                self.isStoppingForLowStorage = true
                if let session = self.currentSession {
                    try? await self.processingLogger.log(
                        .diskSpaceLow,
                        for: session,
                        attributes: [
                            .availableBytes(storage.availableBytes),
                            .requiredBytes(storage.requiredBytes),
                        ]
                    )
                }
                let message = self.localized(.lowStorageSafeStop)
                self.lastError = message
                await self.stopRecording()
                self.lastError = message
                break
            }
        }
    }

    private func stopRecordingForCaptureFailure(message: String) async -> Bool {
        guard !isStoppingForCaptureFailure, status == .recording else {
            return false
        }

        isStoppingForCaptureFailure = true
        if let session = currentSession {
            try? await processingLogger.log(
                .captureFailed,
                for: session
            )
        }
        lastError = message
        await stopRecording()
        lastError = message
        return true
    }

    private func stopCaptureMonitoring() {
        captureMonitorTask?.cancel()
        captureMonitorTask = nil
    }

    private func updateCaptureDiagnostics(_ diagnostics: CaptureSessionDiagnostics) {
        captureDiagnosticsModel.update(diagnostics)
    }
}
