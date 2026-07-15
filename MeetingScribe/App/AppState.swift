import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

struct CaptureMonitoringConfiguration: Sendable {
    var interval: Duration = .seconds(1)
    var storageCheckEveryTicks = 5
    var stalledSystemAudioCheckCount = 3
    var maximumStorageCheckFailures = 3
}

struct RecordingsNavigationRequest: Equatable, Sendable {
    let requestID: UUID
    let sessionID: String
    let occurredAt: Date
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var lastCompletedSession: RecordingSession?
    @Published private(set) var lastError: String?
    @Published private(set) var captureDiagnostics = CaptureSessionDiagnostics.empty
    @Published private(set) var fluidAudioASRModelStatus: FluidAudioModelStatus = .missing
    @Published private(set) var fluidAudioASRDownloadProgress: FluidAudioModelDownloadProgress?
    @Published private(set) var isInstallingFluidAudioASRModel = false
    @Published private(set) var fluidAudioDiarizationModelStatus: FluidAudioModelStatus = .missing
    @Published private(set) var fluidAudioDiarizationDownloadProgress: FluidAudioModelDownloadProgress?
    @Published private(set) var isInstallingFluidAudioDiarizationModel = false
    @Published private(set) var legacyModelCleanupReport = LegacyModelCleanupReport(
        fileCount: 0,
        totalBytes: 0
    )
    @Published private(set) var isRemovingLegacyModels = false
    @Published private(set) var fluidAudioReprocessingSessionID: String?
    @Published private(set) var outputFolderURL: URL?
    @Published private(set) var lastMarkdownURL: URL?
    @Published private(set) var hasOpenAIAPIKey = false
    @Published private(set) var isSavingOpenAIAPIKey = false
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
    @Published var selectedTranscriptionLanguage: TranscriptionLanguage = .automatic
    @Published var aiAnalysisEnabled = false
    @Published var selectedOpenAIModel = OpenAIAnalysisProvider.defaultModel
    @Published var openAIAPIKeyInput = ""
    @Published var meetingTitle = ""
    @Published var automaticallyDeleteSourceCAF = false
    @Published var selectedAppLanguage: AppLanguage = .system
    @Published var selectedOutputLanguage: OutputLanguage = .slovak
    @Published var markdownFileNameTemplate = MarkdownFileNameTemplate.defaultValue
    @Published var minimumStorageBytes = StorageGuard.defaultMinimumBytes
    @Published var calendarIntegrationEnabled = false
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
    private let apiKeyStore: any APIKeyStoring
    private let analysisSettingsStore: AnalysisSettingsStore
    private let transcriptionSettingsStore: TranscriptionSettingsStore
    private let audioRetentionSettingsStore: AudioRetentionSettingsStore
    private let applicationSettingsStore: ApplicationSettingsStore
    private let calendarEventProvider: any CalendarEventProviding
    private let audioSourceCleaner: any AudioSourceCleaning
    private let recoveredAudioInspector: RecoveredAudioInspector
    private let processingLogger: ProcessingLogger
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
        apiKeyStore: (any APIKeyStoring)? = nil,
        analysisSettingsStore: AnalysisSettingsStore? = nil,
        transcriptionSettingsStore: TranscriptionSettingsStore? = nil,
        audioRetentionSettingsStore: AudioRetentionSettingsStore? = nil,
        applicationSettingsStore: ApplicationSettingsStore? = nil,
        calendarEventProvider: (any CalendarEventProviding)? = nil,
        audioSourceCleaner: any AudioSourceCleaning = AudioSourceCleaner(),
        recoveredAudioInspector: RecoveredAudioInspector = RecoveredAudioInspector(),
        processingLogger: ProcessingLogger = ProcessingLogger(),
        captureMonitoringConfiguration: CaptureMonitoringConfiguration = CaptureMonitoringConfiguration(),
        storageStatusProvider: (@Sendable () async throws -> StorageStatus)? = nil
    ) {
        self.sessionManager = sessionManager
        self.captureCoordinator = captureCoordinator
        self.audioFinalizer = audioFinalizer
        self.fluidAudioModelManager = fluidAudioModelManager ?? FluidAudioModelManager()
        self.legacyModelCleaner = legacyModelCleaner
        self.sessionTranscriber = sessionTranscriber ?? SessionTranscriber()
        self.processingFileService = processingFileService
            ?? ProcessingFileService(outputExporter: outputExporter)
        self.outputFolderStore = outputFolderStore ?? OutputFolderStore()
        self.obsidianService = obsidianService ?? ObsidianService()
        self.apiKeyStore = apiKeyStore ?? KeychainAPIKeyStore()
        self.analysisSettingsStore = analysisSettingsStore ?? AnalysisSettingsStore()
        self.transcriptionSettingsStore = transcriptionSettingsStore
            ?? TranscriptionSettingsStore()
        self.audioRetentionSettingsStore = audioRetentionSettingsStore
            ?? AudioRetentionSettingsStore()
        self.applicationSettingsStore = applicationSettingsStore
            ?? ApplicationSettingsStore()
        self.calendarEventProvider = calendarEventProvider ?? CalendarEventService()
        self.audioSourceCleaner = audioSourceCleaner
        self.recoveredAudioInspector = recoveredAudioInspector
        self.processingLogger = processingLogger
        self.captureMonitoringConfiguration = captureMonitoringConfiguration
        self.storageStatusProvider = storageStatusProvider ?? {
            try await sessionManager.storageStatus()
        }
    }

    func prepareStorage() async {
        guard !hasPreparedStorage, !isPreparingStorage else { return }
        isPreparingStorage = true
        defer { isPreparingStorage = false }

        do {
            try await sessionManager.prepareStorage()
            try await fluidAudioModelManager.prepareStorage()
        } catch {
            setFailure(error)
            return
        }

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
        aiAnalysisEnabled = analysisSettingsStore.isEnabled
        let storedModel = analysisSettingsStore.model
        selectedOpenAIModel = OpenAIModelDescriptor.supported.contains { $0.id == storedModel }
            ? storedModel
            : OpenAIAnalysisProvider.defaultModel

        do {
            hasOpenAIAPIKey = try await apiKeyStore.load() != nil
        } catch {
            hasOpenAIAPIKey = false
            lastError = localized(.openAIKeyLoad(localized(error)))
        }

        await refreshFluidAudioModelStatuses()
        refreshLegacyModelCleanupReport()
        await refreshRecoveryCandidates()
        hasPreparedStorage = true
    }

    func reprocessWithFluidAudio(
        session: RecordingSession
    ) async throws -> TranscriptionRevisionResult {
        guard status != .recording, !status.isProcessing,
              fluidAudioReprocessingSessionID == nil else {
            throw TranscriptionRevisionError.applicationBusy
        }
        let descriptor = FluidAudioModelDescriptor.parakeetV3
        let modelStatus = await fluidAudioModelManager.status(for: descriptor)
        fluidAudioASRModelStatus = modelStatus
        guard case let .ready(bundleURL, _) = modelStatus else {
            if case .missing = modelStatus {
                lastError = localized(.fluidAudioTranscriptionModelRequired)
            } else {
                lastError = localized(.recordingSaved(localized(.fluidAudioModelInvalid)))
            }
            throw TranscriptionError.modelBundleCouldNotBeLoaded(
                name: descriptor.displayName
            )
        }

        fluidAudioReprocessingSessionID = session.metadata.id
        defer { fluidAudioReprocessingSessionID = nil }
        do {
            let diarizationModelBundleURL = await availableDiarizationBundleURL()
            return try await FluidAudioTranscriptionRevisionService().reprocess(
                session: session,
                modelBundleURL: bundleURL,
                diarizationModelBundleURL: diarizationModelBundleURL,
                descriptor: descriptor
            )
        } catch {
            lastError = localized(.recordingSavedTranscription(localized(error)))
            throw error
        }
    }

    func startRecording() async {
        if let operation = startRecordingOperation {
            await operation.task.value
            return
        }
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartRecording()
        }
        startRecordingOperation = (operationID, task)
        await task.value
        if startRecordingOperation?.id == operationID {
            startRecordingOperation = nil
        }
    }

    private func performStartRecording() async {
        do {
            if let markdownFileNameTemplateError {
                lastError = markdownFileNameTemplateError
                return
            }
            guard recoveryCandidates.isEmpty else {
                throw SessionRecoveryError.pendingRecoveryMustBeResolved
            }
            try transition(to: .preparing)
            lastError = nil
            lastMarkdownURL = nil
            isStoppingForLowStorage = false
            isStoppingForCaptureFailure = false
            storageCheckTick = 0
            storageCheckFailureCount = 0
            stalledSystemAudioCheckTick = 0

            let session = try await sessionManager.startSession(
                title: meetingTitle,
                language: selectedTranscriptionLanguage,
                outputLanguage: selectedOutputLanguage,
                outputFileNameTemplate: markdownFileNameTemplate,
                calendarEvent: pendingCalendarEvent
            )
            currentSession = session
            pendingCalendarEvent = nil
            try? await processingLogger.log(.sessionCreated, for: session)

            do {
                captureDiagnostics = try await captureCoordinator.start(for: session)
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
                captureDiagnostics = diagnostics
                try? await processingLogger.log(
                    .captureFailed,
                    for: session,
                    attributes: processingErrorAttributes(error)
                )
                throw error
            }

            try? await processingLogger.log(.captureStarted, for: session)
            startCaptureMonitoring()
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
        do {
            try transition(to: .stopping)
            resetProcessingProgress()
            setProcessingStep(.preparingAudio, to: .active)
            let stoppedAt = Date()
            stopCaptureMonitoring()

            let diagnostics = await captureCoordinator.stop()
            captureDiagnostics = diagnostics

            guard let session = currentSession else {
                throw SessionManagerError.noActiveSession
            }
            let recordingEndedAt = max(stoppedAt, session.metadata.startedAt ?? stoppedAt)
            try? await processingLogger.log(
                .captureStopped,
                for: session,
                attributes: [
                    .bufferCount(diagnostics.systemAudio.bufferCount),
                    .frameCount(diagnostics.systemAudio.totalFrames),
                ]
            )
            await processStoppedSession(
                session: session,
                diagnostics: diagnostics,
                recordingEndedAt: recordingEndedAt
            )
        } catch {
            setFailure(error)
        }
    }

    func renameCurrentSession(to title: String) async {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle != currentSession?.metadata.title else {
            return
        }

        do {
            let renamedSession = try await sessionManager.renameActiveSession(
                to: normalizedTitle
            )
            currentSession = renamedSession
            meetingTitle = renamedSession.metadata.title
        } catch {
            lastError = "The meeting title could not be updated: \(error.localizedDescription)"
        }
    }

    func recoverSession(_ candidate: SessionRecoveryCandidate) async {
        guard !isRecoveringSession else { return }
        isRecoveringSession = true
        defer { isRecoveringSession = false }

        do {
            if status == .completed || status == .failed { reset() }
            guard status == .idle else { return }
            try transition(to: .preparing)
            lastError = nil
            lastMarkdownURL = nil
            resetProcessingProgress()

            let session = try await sessionManager.beginRecovery(id: candidate.id)
            currentSession = session
            try transition(to: .recording)
            try transition(to: .stopping)
            try? await processingLogger.log(.recoveryStarted, for: session)

            if let recoveredArtifacts = await processingFileService.loadRecoveredArtifacts(
                from: session
            ) {
                setProcessingStep(.preparingAudio, to: .completed)
                let diagnostics = recoveredMetadataDiagnostics(for: session)
                captureDiagnostics = diagnostics
                let speakerProcessing: SpeakerProcessingResult?
                if let finalization = session.metadata.audioFinalization {
                    speakerProcessing = try await sessionTranscriber.processSpeakers(
                        session: session,
                        transcript: recoveredArtifacts.transcript,
                        finalization: finalization,
                        diarizationModelBundleURL: await availableDiarizationBundleURL()
                    )
                } else {
                    speakerProcessing = nil
                }
                await completeProcessedSession(
                    session: session,
                    diagnostics: diagnostics,
                    recordingEndedAt: candidate.suggestedEndAt,
                    finalization: session.metadata.audioFinalization,
                    transcription: recoveredTranscriptionOutcome(
                        session: session,
                        transcript: recoveredArtifacts.transcript,
                        utteranceTranscript: recoveredArtifacts.utteranceTranscript,
                        diarizationMetadata: speakerProcessing?.metadata
                            ?? session.metadata.diarization,
                        resolvedTranscript: speakerProcessing?.resolvedTranscript
                            ?? recoveredArtifacts.resolvedTranscript
                    ),
                    recoveredAnalysis: recoveredAnalysisOutcome(
                        session: session,
                        analysis: recoveredArtifacts.analysis
                    )
                )
            } else {
                let diagnostics = try recoveredAudioInspector.inspect(session: session)
                captureDiagnostics = diagnostics
                await processStoppedSession(
                    session: session,
                    diagnostics: diagnostics,
                    recordingEndedAt: candidate.suggestedEndAt
                )
            }
            await refreshRecoveryCandidates()
        } catch {
            if await sessionManager.currentSession() != nil {
                let failed = try? await sessionManager.failSession(reason: error.localizedDescription)
                lastCompletedSession = failed
            }
            currentSession = nil
            setFailure(error)
            await refreshRecoveryCandidates()
        }
    }

    func closeRecovery(_ candidate: SessionRecoveryCandidate) async {
        do {
            let closed = try await sessionManager.closeRecovery(id: candidate.id)
            lastCompletedSession = closed
            try? await processingLogger.log(.recoveryClosed, for: closed)
            await refreshRecoveryCandidates()
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
            await refreshRecoveryCandidates()
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
        recordingsNavigationRequest = RecordingsNavigationRequest(
            requestID: UUID(),
            sessionID: session.metadata.id,
            occurredAt: session.metadata.startedAt ?? session.metadata.createdAt
        )
    }

    func reset() {
        guard status == .completed || status == .failed else { return }

        do {
            try transition(to: .idle)
            lastError = nil
            captureDiagnostics = .empty
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
        outputFolderURL?.path ?? "Recording session folder (default)"
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
        analysisSettingsStore.setModel(selectedOpenAIModel)
    }

    func saveOpenAIAPIKey() async {
        guard !isSavingOpenAIAPIKey else { return }
        let normalized = openAIAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            lastError = localized(AnalysisError.missingAPIKey)
            return
        }

        isSavingOpenAIAPIKey = true
        defer { isSavingOpenAIAPIKey = false }
        do {
            try await apiKeyStore.save(normalized)
            openAIAPIKeyInput = ""
            hasOpenAIAPIKey = true
            lastError = nil
        } catch {
            lastError = localized(.openAIKeySave(localized(error)))
        }
    }

    func deleteOpenAIAPIKey() async {
        do {
            try await apiKeyStore.delete()
            openAIAPIKeyInput = ""
            hasOpenAIAPIKey = false
            aiAnalysisEnabled = false
            persistAnalysisSettings()
            lastError = nil
        } catch {
            lastError = localized(.openAIKeyRemove(localized(error)))
        }
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

    func persistApplicationSettings() async {
        applicationSettingsStore.setAppLanguage(selectedAppLanguage)
        applicationSettingsStore.setOutputLanguage(selectedOutputLanguage)
        applicationSettingsStore.setMarkdownFileNameTemplate(markdownFileNameTemplate)
        applicationSettingsStore.setMinimumStorageBytes(minimumStorageBytes)
        await sessionManager.setMinimumStorageBytes(minimumStorageBytes)
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
        useEventTitle: Bool,
        shareParticipantNamesWithAnalysis: Bool,
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
            shareParticipantNamesWithAnalysis: shareParticipantNamesWithAnalysis
                && !participants.isEmpty
        )
        let approvedTitle = useEventTitle ? candidate.title : nil

        do {
            if currentSession != nil {
                let updated = try await sessionManager.updateActiveSessionCalendarEvent(
                    snapshot,
                    title: approvedTitle
                )
                currentSession = updated
                if useEventTitle { meetingTitle = updated.metadata.title }
            } else {
                pendingCalendarEvent = snapshot
                if let approvedTitle { meetingTitle = approvedTitle }
            }
            calendarEventCandidates = []
            lastError = nil
            return true
        } catch {
            lastError = localized(error)
            return false
        }
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

    var fluidAudioDiarizationDescriptor: FluidAudioModelDescriptor {
        .speakerDiarization
    }

    func refreshFluidAudioModelStatuses() async {
        fluidAudioASRModelStatus = localizedFluidAudioStatus(
            await fluidAudioModelManager.status(for: fluidAudioASRDescriptor)
        )
        fluidAudioDiarizationModelStatus = localizedFluidAudioStatus(
            await fluidAudioModelManager.status(for: fluidAudioDiarizationDescriptor)
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
        guard fluidAudioInstallTasks[kind] == nil else { return }
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
        guard fluidAudioInstallTasks[kind] == nil else { return }
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
    }

    func deleteFluidAudioModel(_ kind: FluidAudioModelKind) async {
        guard fluidAudioInstallTasks[kind] == nil else { return }
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
    }

    private func refreshFluidAudioModelStatus(_ kind: FluidAudioModelKind) async {
        let status = localizedFluidAudioStatus(
            await fluidAudioModelManager.status(for: descriptor(for: kind))
        )
        switch kind {
        case .transcription:
            fluidAudioASRModelStatus = status
        case .diarization:
            fluidAudioDiarizationModelStatus = status
        }
    }

    private func descriptor(
        for kind: FluidAudioModelKind
    ) -> FluidAudioModelDescriptor {
        switch kind {
        case .transcription: return fluidAudioASRDescriptor
        case .diarization: return fluidAudioDiarizationDescriptor
        }
    }

    private func setFluidAudioInstalling(
        _ installing: Bool,
        kind: FluidAudioModelKind
    ) {
        switch kind {
        case .transcription:
            isInstallingFluidAudioASRModel = installing
        case .diarization:
            isInstallingFluidAudioDiarizationModel = installing
        }
    }

    private func setFluidAudioProgress(
        _ progress: FluidAudioModelDownloadProgress?,
        kind: FluidAudioModelKind
    ) {
        switch kind {
        case .transcription:
            fluidAudioASRDownloadProgress = progress
        case .diarization:
            fluidAudioDiarizationDownloadProgress = progress
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

    private func processStoppedSession(
        session: RecordingSession,
        diagnostics: CaptureSessionDiagnostics,
        recordingEndedAt: Date
    ) async {
        let finalization: AudioFinalizationMetadata
        setProcessingStep(.preparingAudio, to: .active)
        do {
            try? await processingLogger.log(.finalizationStarted, for: session)
            finalization = try await audioFinalizer.finalize(
                session: session,
                diagnostics: diagnostics
            )
            try? await processingLogger.log(
                .finalizationCompleted,
                for: session,
                attributes: [.durationSeconds(finalization.system.durationSeconds)]
            )
            setProcessingStep(.preparingAudio, to: .completed)
        } catch {
            setProcessingStep(.preparingAudio, to: .failed)
            let failedSession = try? await sessionManager.failSession(
                reason: error.localizedDescription,
                now: recordingEndedAt,
                systemAudio: diagnostics.systemAudio.sessionMetadata,
                microphoneAudio: diagnostics.microphone.sessionMetadata
            )
            currentSession = nil
            lastCompletedSession = failedSession
            try? await processingLogger.log(
                .processingFailed,
                for: failedSession ?? session,
                attributes: processingErrorAttributes(error)
            )
            setFailure(error)
            return
        }

        try? await processingLogger.log(
            .transcriptionStarted,
            for: session,
            attributes: [.model(FluidAudioModelDescriptor.parakeetV3.repository)]
        )
        let transcription = await transcribeIfPossible(
            session: session,
            finalization: finalization
        )
        await completeProcessedSession(
            session: session,
            diagnostics: diagnostics,
            recordingEndedAt: recordingEndedAt,
            finalization: finalization,
            transcription: transcription
        )
    }

    private func completeProcessedSession(
        session: RecordingSession,
        diagnostics: CaptureSessionDiagnostics,
        recordingEndedAt: Date,
        finalization: AudioFinalizationMetadata?,
        transcription: TranscriptionOutcome,
        recoveredAnalysis: AnalysisOutcome? = nil
    ) async {
        do {
            setProcessingStep(
                .transcribing,
                to: transcription.metadata.status == .completed ? .completed : .failed
            )
            if transcription.metadata.status == .completed {
                var attributes: [ProcessingLogAttribute] = [
                    .model(transcription.metadata.model),
                    .segmentCount(transcription.metadata.mergedSegmentCount ?? 0),
                ]
                if let performance = transcription.metadata.systemPerformance {
                    attributes += [
                        .systemAudioDurationSeconds(performance.audioDurationSeconds),
                        .systemActiveDurationSeconds(performance.activeDurationSeconds),
                        .systemSkippedDurationSeconds(performance.skippedDurationSeconds),
                        .systemInferenceInputDurationSeconds(performance.inferenceInputDurationSeconds),
                        .systemTranscriptionWallTimeSeconds(performance.wallTimeSeconds),
                        .systemChunkCount(performance.chunkCount),
                    ]
                }
                if let performance = transcription.metadata.microphonePerformance {
                    attributes += [
                        .microphoneAudioDurationSeconds(performance.audioDurationSeconds),
                        .microphoneActiveDurationSeconds(performance.activeDurationSeconds),
                        .microphoneSkippedDurationSeconds(performance.skippedDurationSeconds),
                        .microphoneInferenceInputDurationSeconds(performance.inferenceInputDurationSeconds),
                        .microphoneTranscriptionWallTimeSeconds(performance.wallTimeSeconds),
                        .microphoneChunkCount(performance.chunkCount),
                    ]
                }
                try? await processingLogger.log(
                    .transcriptionCompleted,
                    for: session,
                    attributes: attributes
                )
            } else {
                try? await processingLogger.log(
                    .transcriptionFailed,
                    for: session,
                    attributes: [
                        .model(transcription.metadata.model),
                    ]
                )
            }

            if let diarization = transcription.diarizationMetadata {
                try? await processingLogger.log(
                    diarization.status == .completed
                        ? .diarizationCompleted
                        : .diarizationFailed,
                    for: session,
                    attributes: [
                        .model(diarization.model),
                        .segmentCount(diarization.segmentCount ?? 0),
                    ]
                )
            }

            let analysis: AnalysisOutcome
            if let recoveredAnalysis {
                analysis = recoveredAnalysis
            } else {
                let analysisTranscript: MergedTranscript?
                if let raw = transcription.mergedTranscript,
                   let resolved = transcription.resolvedTranscript {
                    analysisTranscript = resolved.asMergedTranscript(basedOn: raw)
                } else {
                    analysisTranscript = transcription.mergedTranscript
                }
                analysis = await analyzeIfPossible(
                    session: session,
                    transcript: analysisTranscript
                )
            }
            if let metadata = analysis.metadata {
                setProcessingStep(
                    .analyzing,
                    to: metadata.status == .completed ? .completed : .failed
                )
                try? await processingLogger.log(
                    metadata.status == .completed ? .analysisCompleted : .analysisFailed,
                    for: session,
                    attributes: [
                        .model(metadata.model),
                    ]
                )
            }
            if analysis.metadata == nil {
                setProcessingStep(.analyzing, to: .skipped)
            }
            try transition(to: .exporting)
            setProcessingStep(.exporting, to: .active)

            var exportSession = session
            exportSession.metadata.endedAt = recordingEndedAt
            let output = await exportMarkdownIfPossible(
                session: exportSession,
                transcript: transcription.mergedTranscript,
                utteranceTranscript: transcription.utteranceTranscript,
                resolvedTranscript: transcription.resolvedTranscript,
                analysis: analysis.analysis
            )
            if let output {
                setProcessingStep(
                    .exporting,
                    to: output.status == .completed ? .completed : .failed
                )
                try? await processingLogger.log(
                    output.status == .completed ? .exportCompleted : .exportFailed,
                    for: session
                )
            } else {
                setProcessingStep(.exporting, to: .skipped)
            }

            var completedSession = try await sessionManager.stopSession(
                now: recordingEndedAt,
                systemAudio: diagnostics.systemAudio.sessionMetadata,
                microphoneAudio: diagnostics.microphone.sessionMetadata,
                audioFinalization: finalization,
                transcription: transcription.metadata,
                diarization: transcription.diarizationMetadata,
                analysis: analysis.metadata,
                output: output
            )
            completedSession = await cleanupSourceAudioIfEnabled(
                for: completedSession
            )
            currentSession = nil
            lastCompletedSession = completedSession
            meetingTitle = ""
            pendingCalendarEvent = nil
            calendarEventCandidates = []
            if completedSession.metadata.recovery?.status == .completed {
                try? await processingLogger.log(.recoveryCompleted, for: completedSession)
            }
            try transition(to: .completed)
            await refreshRecoveryCandidates()
        } catch {
            if await sessionManager.currentSession() != nil {
                let failed = try? await sessionManager.failSession(
                    reason: error.localizedDescription,
                    now: recordingEndedAt,
                    systemAudio: diagnostics.systemAudio.sessionMetadata,
                    microphoneAudio: diagnostics.microphone.sessionMetadata
                )
                lastCompletedSession = failed
            }
            currentSession = nil
            try? await processingLogger.log(
                .processingFailed,
                for: lastCompletedSession ?? session,
                attributes: processingErrorAttributes(error)
            )
            setFailure(error)
        }
    }

    private func cleanupSourceAudioIfEnabled(
        for session: RecordingSession
    ) async -> RecordingSession {
        guard automaticallyDeleteSourceCAF else { return session }
        let cleaner = audioSourceCleaner
        do {
            let cleanupTask = Task.detached(priority: .utility) {
                try cleaner.cleanupSourceCAFIfEligible(session: session)
            }
            guard let cleanup = try await cleanupTask.value else {
                return session
            }
            let updated = try await sessionManager.recordAudioSourceCleanup(
                cleanup,
                for: session
            )
            try? await processingLogger.log(
                .sourceAudioCleanupCompleted,
                for: updated
            )
            return updated
        } catch {
            let cleanup = AudioSourceCleanupMetadata(
                status: .failed,
                completedAt: Date(),
                deletedFiles: [],
                failureReason: error.localizedDescription
            )
            let updated = (try? await sessionManager.recordAudioSourceCleanup(
                cleanup,
                for: session
            )) ?? session
            try? await processingLogger.log(
                .sourceAudioCleanupFailed,
                for: updated,
                attributes: processingErrorAttributes(error)
            )
            if lastError == nil {
                lastError = localized(.sourceCAFPreserved(localized(error)))
            }
            return updated
        }
    }

    private func recoveredTranscriptionOutcome(
        session: RecordingSession,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        diarizationMetadata: SessionDiarizationMetadata?,
        resolvedTranscript: ResolvedTranscript?
    ) -> TranscriptionOutcome {
        let metadata = session.metadata.transcription.flatMap {
            $0.status == .completed ? $0 : nil
        } ?? SessionTranscriptionMetadata(
            status: .completed,
            model: "recovered-transcript",
            startedAt: nil,
            completedAt: transcript.completedAt,
            systemSegmentCount: transcript.segments.filter { $0.source == .system }.count,
            microphoneSegmentCount: transcript.segments.filter { $0.source == .microphone }.count,
            mergedSegmentCount: transcript.segments.count,
            warnings: ["Reused a merged transcript found during session recovery."],
            failureReason: nil
        )
        return TranscriptionOutcome(
            metadata: metadata,
            mergedTranscript: transcript,
            utteranceTranscript: utteranceTranscript,
            diarizationMetadata: diarizationMetadata,
            resolvedTranscript: resolvedTranscript
        )
    }

    private func recoveredAnalysisOutcome(
        session: RecordingSession,
        analysis: MeetingAnalysis?
    ) -> AnalysisOutcome? {
        guard let analysis else { return nil }
        let metadata = session.metadata.analysis.flatMap {
            $0.status == .completed ? $0 : nil
        } ?? SessionAnalysisMetadata(
            status: .completed,
            provider: "recovered",
            model: "recovered-analysis",
            startedAt: nil,
            completedAt: Date(),
            transcriptChunkCount: nil,
            requestCount: 0,
            failureReason: nil
        )
        return AnalysisOutcome(metadata: metadata, analysis: analysis)
    }

    private func recoveredMetadataDiagnostics(for session: RecordingSession) -> CaptureSessionDiagnostics {
        CaptureSessionDiagnostics(
            systemAudio: recoveredDiagnostics(
                metadata: session.metadata.systemAudio,
                fileName: session.metadata.audioFiles.system
            ),
            microphone: recoveredDiagnostics(
                metadata: session.metadata.microphoneAudio,
                fileName: session.metadata.audioFiles.microphone
            )
        )
    }

    private func recoveredDiagnostics(
        metadata: AudioTrackMetadata?,
        fileName: String
    ) -> AudioCaptureDiagnostics {
        guard let metadata else {
            var empty = AudioCaptureDiagnostics.empty
            empty.fileName = fileName
            return empty
        }
        return AudioCaptureDiagnostics(
            fileName: metadata.fileName,
            startedAt: nil,
            lastBufferReceivedAt: nil,
            bufferCount: metadata.bufferCount,
            totalFrames: metadata.totalFrames,
            sampleRate: metadata.sampleRate,
            channelCount: metadata.channelCount,
            firstPresentationTimestamp: metadata.firstPresentationTimestamp,
            lastPresentationTimestamp: metadata.lastPresentationTimestamp,
            lastBufferDurationSeconds: nil,
            failureReason: metadata.failureReason
        )
    }

    private func transition(to nextStatus: AppStatus) throws {
        try stateMachine.transition(to: nextStatus)
        status = stateMachine.status
    }

    private func transcribeIfPossible(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata
    ) async -> TranscriptionOutcome {
        setProcessingStep(.transcribing, to: .active)
        let descriptor = FluidAudioModelDescriptor.parakeetV3
        let provenance = TranscriptionProvenance.fluidAudioParakeetV3(
            descriptor: descriptor
        )
        let modelStatus = await fluidAudioModelManager.status(for: descriptor)
        fluidAudioASRModelStatus = modelStatus

        guard case let .ready(bundleURL, _) = modelStatus else {
            let reason: String
            switch modelStatus {
            case .missing:
                reason = "Download or import the verified Parakeet v3 model bundle to transcribe this recording."
                lastError = localized(.fluidAudioTranscriptionModelRequired)
            case let .invalid(invalidReason):
                reason = invalidReason
                lastError = localized(.recordingSaved(localized(.fluidAudioModelInvalid)))
            case .ready:
                preconditionFailure("The ready model status was handled by the guard.")
            }
            return TranscriptionOutcome(
                metadata: SessionTranscriptionMetadata(
                    status: .modelMissing,
                    model: descriptor.repository,
                    startedAt: nil,
                    completedAt: Date(),
                    systemSegmentCount: nil,
                    microphoneSegmentCount: nil,
                    warnings: [],
                    failureReason: reason,
                    provenance: provenance
                ),
                mergedTranscript: nil
            )
        }

        do {
            try transition(to: .transcribing)
            let diarizationModelBundleURL = await availableDiarizationBundleURL()
            let result = try await sessionTranscriber.transcribe(
                session: session,
                finalization: finalization,
                model: .fluidAudioParakeetV3(
                    bundleURL: bundleURL,
                    descriptor: descriptor
                ),
                language: session.metadata.language,
                diarizationModelBundleURL: diarizationModelBundleURL
            )
            return TranscriptionOutcome(
                metadata: result.metadata,
                mergedTranscript: result.mergedTranscript,
                utteranceTranscript: result.utteranceTranscript,
                diarizationMetadata: result.diarizationMetadata,
                resolvedTranscript: result.resolvedTranscript
            )
        } catch {
            lastError = localized(.recordingSavedTranscription(localized(error)))
            return TranscriptionOutcome(
                metadata: SessionTranscriptionMetadata(
                    status: .failed,
                    model: descriptor.repository,
                    startedAt: nil,
                    completedAt: Date(),
                    systemSegmentCount: nil,
                    microphoneSegmentCount: nil,
                    warnings: [],
                    failureReason: error.localizedDescription,
                    provenance: provenance
                ),
                mergedTranscript: nil
            )
        }
    }

    private func exportMarkdownIfPossible(
        session: RecordingSession,
        transcript: MergedTranscript?,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        resolvedTranscript: ResolvedTranscript?,
        analysis: MeetingAnalysis?
    ) async -> SessionOutputMetadata? {
        guard let transcript else { return nil }

        let destination = outputFolderURL ?? session.directoryURL
        do {
            let processingFileService = processingFileService
            let result = try await outputFolderStore.withAccess(to: destination) {
                try await processingFileService.exportMarkdown(
                    session: session.metadata,
                    transcript: transcript,
                    utteranceTranscript: utteranceTranscript,
                    resolvedTranscript: resolvedTranscript,
                    analysis: analysis,
                    to: destination
                )
            }
            lastMarkdownURL = result.fileURL
            return SessionOutputMetadata(
                status: .completed,
                markdownFileName: result.fileURL.lastPathComponent,
                markdownPath: result.fileURL.path,
                exportedAt: result.exportedAt,
                failureReason: nil
            )
        } catch {
            lastError = localized(.transcriptSavedMarkdown(localized(error)))
            return SessionOutputMetadata(
                status: .failed,
                markdownFileName: nil,
                markdownPath: nil,
                exportedAt: Date(),
                failureReason: error.localizedDescription
            )
        }
    }

    private func analyzeIfPossible(
        session: RecordingSession,
        transcript: MergedTranscript?
    ) async -> AnalysisOutcome {
        guard aiAnalysisEnabled, let transcript else {
            setProcessingStep(.analyzing, to: .skipped)
            return .none
        }

        setProcessingStep(.analyzing, to: .active)

        let startedAt = Date()
        do {
            try transition(to: .analyzing)
            guard let apiKey = try await apiKeyStore.load(), !apiKey.isEmpty else {
                let error = AnalysisError.missingAPIKey
                lastError = localized(.transcriptSavedAnalysisSkipped(localized(error)))
                return AnalysisOutcome(
                    metadata: SessionAnalysisMetadata(
                        status: .missingAPIKey,
                        provider: "openai",
                        model: selectedOpenAIModel,
                        startedAt: startedAt,
                        completedAt: Date(),
                        transcriptChunkCount: nil,
                        requestCount: nil,
                        failureReason: error.localizedDescription
                    ),
                    analysis: nil
                )
            }

            let provider = OpenAIAnalysisProvider(
                apiKey: apiKey,
                model: selectedOpenAIModel
            )
            let run = try await MeetingAnalyzer(provider: provider).analyze(
                session: session.metadata,
                transcript: transcript,
                preferredLanguage: session.metadata.resolvedOutputLanguage.rawValue
            )
            try await processingFileService.persistAnalysis(
                run.analysis,
                to: session.analysisURL
            )
            return AnalysisOutcome(
                metadata: SessionAnalysisMetadata(
                    status: .completed,
                    provider: "openai",
                    model: selectedOpenAIModel,
                    startedAt: startedAt,
                    completedAt: Date(),
                    transcriptChunkCount: run.transcriptChunkCount,
                    requestCount: run.requestCount,
                    failureReason: nil
                ),
                analysis: run.analysis
            )
        } catch {
            lastError = localized(.transcriptSavedAnalysisFailed(localized(error)))
            return AnalysisOutcome(
                metadata: SessionAnalysisMetadata(
                    status: .failed,
                    provider: "openai",
                    model: selectedOpenAIModel,
                    startedAt: startedAt,
                    completedAt: Date(),
                    transcriptChunkCount: nil,
                    requestCount: nil,
                    failureReason: error.localizedDescription
                ),
                analysis: nil
            )
        }
    }

    private func availableDiarizationBundleURL() async -> URL? {
        let descriptor = FluidAudioModelDescriptor.speakerDiarization
        let status = await fluidAudioModelManager.status(for: descriptor)
        fluidAudioDiarizationModelStatus = localizedFluidAudioStatus(status)
        guard case let .ready(bundleURL, _) = status else { return nil }
        return bundleURL
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

    private func localized(_ message: AppUserMessage) -> String {
        AppLocalization.message(message, language: selectedAppLanguage)
    }

    private func localized(_ error: Error) -> String {
        AppLocalization.error(error, language: selectedAppLanguage)
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
                self.captureDiagnostics = await self.captureCoordinator.diagnostics()
                let systemAudioHealth = self.captureDiagnostics.systemAudio.health()

                if systemAudioHealth == .stalled {
                    self.stalledSystemAudioCheckTick += 1
                } else {
                    self.stalledSystemAudioCheckTick = 0
                }

                if systemAudioHealth == .failed {
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
                if systemAudioHealth == .stalled,
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
}

private struct TranscriptionOutcome: Sendable {
    let metadata: SessionTranscriptionMetadata
    let mergedTranscript: MergedTranscript?
    let utteranceTranscript: ContinuousUtteranceTranscript?
    let diarizationMetadata: SessionDiarizationMetadata?
    let resolvedTranscript: ResolvedTranscript?

    init(
        metadata: SessionTranscriptionMetadata,
        mergedTranscript: MergedTranscript?,
        utteranceTranscript: ContinuousUtteranceTranscript? = nil,
        diarizationMetadata: SessionDiarizationMetadata? = nil,
        resolvedTranscript: ResolvedTranscript? = nil
    ) {
        self.metadata = metadata
        self.mergedTranscript = mergedTranscript
        self.utteranceTranscript = utteranceTranscript
        self.diarizationMetadata = diarizationMetadata
        self.resolvedTranscript = resolvedTranscript
    }
}

private struct AnalysisOutcome: Sendable {
    let metadata: SessionAnalysisMetadata?
    let analysis: MeetingAnalysis?

    static let none = AnalysisOutcome(metadata: nil, analysis: nil)
}
