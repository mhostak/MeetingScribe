import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

struct CaptureMonitoringConfiguration: Sendable {
    var interval: Duration = .seconds(1)
    var storageCheckEveryTicks = 5
    var stalledSystemAudioCheckCount = 3
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var lastCompletedSession: RecordingSession?
    @Published private(set) var lastError: String?
    @Published private(set) var captureDiagnostics = CaptureSessionDiagnostics.empty
    @Published private(set) var whisperModelStatus: WhisperModelStatus = .missing
    @Published private(set) var isDownloadingWhisperModel = false
    @Published private(set) var whisperModelDownloadProgress: Double?
    @Published private(set) var outputFolderURL: URL?
    @Published private(set) var lastMarkdownURL: URL?
    @Published private(set) var hasOpenAIAPIKey = false
    @Published private(set) var isSavingOpenAIAPIKey = false
    @Published private(set) var recoveryCandidates: [SessionRecoveryCandidate] = []
    @Published private(set) var recoveryIssues: [SessionRecoveryIssue] = []
    @Published private(set) var isRecoveringSession = false
    @Published private(set) var processingSteps = ProcessingStep.initial
    @Published var selectedWhisperModelID = WhisperModelDescriptor.largeV3Turbo.id
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
    @Published var selectedSettingsSection = "general"
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

    private var stateMachine = AppStateMachine()
    private let sessionManager: SessionManager
    private let captureCoordinator: CaptureCoordinator
    private let audioFinalizer: any AudioFinalizing
    private let modelManager: WhisperModelManager
    private let sessionTranscriber: any SessionTranscribing
    private let processingFileService: any ProcessingFileServicing
    private let outputFolderStore: OutputFolderStore
    private let obsidianService: ObsidianService
    private let apiKeyStore: any APIKeyStoring
    private let analysisSettingsStore: AnalysisSettingsStore
    private let whisperSettingsStore: WhisperSettingsStore
    private let audioRetentionSettingsStore: AudioRetentionSettingsStore
    private let applicationSettingsStore: ApplicationSettingsStore
    private let audioSourceCleaner: any AudioSourceCleaning
    private let recoveredAudioInspector: RecoveredAudioInspector
    private let processingLogger: ProcessingLogger
    private let captureMonitoringConfiguration: CaptureMonitoringConfiguration
    private let storageStatusProvider: @Sendable () async throws -> StorageStatus
    private var captureMonitorTask: Task<Void, Never>?
    private var storageCheckTick = 0
    private var stalledSystemAudioCheckTick = 0
    private var isStoppingForLowStorage = false
    private var isStoppingForCaptureFailure = false
    private var hasPreparedStorage = false
    private var isPreparingStorage = false

    init(
        sessionManager: SessionManager = SessionManager(),
        captureCoordinator: CaptureCoordinator = CaptureCoordinator(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        modelManager: WhisperModelManager = WhisperModelManager(),
        sessionTranscriber: any SessionTranscribing = SessionTranscriber(),
        outputExporter: OutputExporter = OutputExporter(),
        processingFileService: (any ProcessingFileServicing)? = nil,
        outputFolderStore: OutputFolderStore? = nil,
        obsidianService: ObsidianService? = nil,
        apiKeyStore: (any APIKeyStoring)? = nil,
        analysisSettingsStore: AnalysisSettingsStore? = nil,
        whisperSettingsStore: WhisperSettingsStore? = nil,
        audioRetentionSettingsStore: AudioRetentionSettingsStore? = nil,
        applicationSettingsStore: ApplicationSettingsStore? = nil,
        audioSourceCleaner: any AudioSourceCleaning = AudioSourceCleaner(),
        recoveredAudioInspector: RecoveredAudioInspector = RecoveredAudioInspector(),
        processingLogger: ProcessingLogger = ProcessingLogger(),
        captureMonitoringConfiguration: CaptureMonitoringConfiguration = CaptureMonitoringConfiguration(),
        storageStatusProvider: (@Sendable () async throws -> StorageStatus)? = nil
    ) {
        self.sessionManager = sessionManager
        self.captureCoordinator = captureCoordinator
        self.audioFinalizer = audioFinalizer
        self.modelManager = modelManager
        self.sessionTranscriber = sessionTranscriber
        self.processingFileService = processingFileService
            ?? ProcessingFileService(outputExporter: outputExporter)
        self.outputFolderStore = outputFolderStore ?? OutputFolderStore()
        self.obsidianService = obsidianService ?? ObsidianService()
        self.apiKeyStore = apiKeyStore ?? KeychainAPIKeyStore()
        self.analysisSettingsStore = analysisSettingsStore ?? AnalysisSettingsStore()
        self.whisperSettingsStore = whisperSettingsStore ?? WhisperSettingsStore()
        self.audioRetentionSettingsStore = audioRetentionSettingsStore
            ?? AudioRetentionSettingsStore()
        self.applicationSettingsStore = applicationSettingsStore
            ?? ApplicationSettingsStore()
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
            try await modelManager.prepareStorage()
        } catch {
            setFailure(error)
            return
        }

        outputFolderURL = outputFolderStore.restoreFolder()
        let storedWhisperModelID = whisperSettingsStore.selectedModelID
        selectedWhisperModelID = WhisperModelDescriptor.supported.contains {
            $0.id == storedWhisperModelID
        } ? storedWhisperModelID : WhisperModelDescriptor.largeV3Turbo.id
        selectedTranscriptionLanguage = whisperSettingsStore.selectedLanguage
        selectedAppLanguage = applicationSettingsStore.appLanguage
        selectedOutputLanguage = applicationSettingsStore.outputLanguage
        markdownFileNameTemplate = applicationSettingsStore.markdownFileNameTemplate
        minimumStorageBytes = applicationSettingsStore.minimumStorageBytes
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
            lastError = "The OpenAI API key could not be loaded: \(error.localizedDescription)"
        }

        await refreshWhisperModelStatus()
        await refreshRecoveryCandidates()
        hasPreparedStorage = true
    }

    func startRecording() async {
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
            stalledSystemAudioCheckTick = 0

            let session = try await sessionManager.startSession(
                title: meetingTitle,
                language: selectedTranscriptionLanguage,
                outputLanguage: selectedOutputLanguage,
                outputFileNameTemplate: markdownFileNameTemplate
            )
            currentSession = session
            try? await processingLogger.log(.sessionCreated, for: session)

            do {
                captureDiagnostics = try await captureCoordinator.start(for: session)
            } catch {
                let diagnostics = await captureCoordinator.diagnostics()
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
                    attributes: [.reason(error.localizedDescription)]
                )
                throw error
            }

            try transition(to: .recording)
            try? await processingLogger.log(.captureStarted, for: session)
            startCaptureMonitoring()
        } catch {
            setFailure(error)
        }
    }

    func stopRecording() async {
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
                await completeProcessedSession(
                    session: session,
                    diagnostics: diagnostics,
                    recordingEndedAt: candidate.suggestedEndAt,
                    finalization: session.metadata.audioFinalization,
                    transcription: recoveredTranscriptionOutcome(
                        session: session,
                        transcript: recoveredArtifacts.transcript
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
            lastError = error.localizedDescription
        }
    }

    func revealRecovery(_ candidate: SessionRecoveryCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([candidate.session.manifestURL])
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
        panel.title = "Choose Markdown output folder"
        panel.prompt = "Choose"
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
            lastError = "The output folder could not be saved: \(error.localizedDescription)"
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
            lastError = AnalysisError.missingAPIKey.localizedDescription
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
            lastError = "The OpenAI API key could not be saved: \(error.localizedDescription)"
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
            lastError = "The OpenAI API key could not be removed: \(error.localizedDescription)"
        }
    }

    var selectedWhisperModel: WhisperModelDescriptor {
        WhisperModelDescriptor.supported.first { $0.id == selectedWhisperModelID }
            ?? .largeV3Turbo
    }

    var canEditSessionConfiguration: Bool {
        switch status {
        case .idle, .completed, .failed:
            return currentSession == nil
        case .preparing, .recording, .stopping, .transcribing, .analyzing, .exporting:
            return false
        }
    }

    func persistWhisperModelSelection() {
        whisperSettingsStore.setSelectedModelID(selectedWhisperModelID)
    }

    func persistTranscriptionLanguageSelection() {
        whisperSettingsStore.setSelectedLanguage(selectedTranscriptionLanguage)
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
            lastError = "Launch at login could not be updated: \(error.localizedDescription)"
        }
    }

    var markdownFileNameTemplateError: String? {
        let unsupported = MarkdownFileNameTemplate.unsupportedTokens(in: markdownFileNameTemplate)
        guard unsupported.isEmpty else {
            return "Unsupported token: \(unsupported.joined(separator: ", "))"
        }
        return nil
    }

    var whisperModelStatusText: String {
        switch whisperModelStatus {
        case .missing:
            return "Missing"
        case let .ready(_, sizeBytes):
            return "Ready (\(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)))"
        case let .invalid(reason):
            return "Invalid: \(reason)"
        }
    }

    func refreshWhisperModelStatus() async {
        do {
            whisperModelStatus = try await modelManager.status(for: selectedWhisperModel)
        } catch {
            whisperModelStatus = .invalid(reason: error.localizedDescription)
        }
    }

    func downloadSelectedWhisperModel() async {
        guard !isDownloadingWhisperModel else { return }
        isDownloadingWhisperModel = true
        whisperModelDownloadProgress = 0
        lastError = nil
        defer {
            isDownloadingWhisperModel = false
            whisperModelDownloadProgress = nil
        }
        do {
            _ = try await modelManager.download(selectedWhisperModel) { [weak self] progress in
                Task { @MainActor in
                    self?.whisperModelDownloadProgress = progress
                }
            }
            await refreshWhisperModelStatus()
        } catch {
            lastError = error.localizedDescription
            await refreshWhisperModelStatus()
        }
    }

    func importSelectedWhisperModel() async {
        let panel = NSOpenPanel()
        panel.title = "Import Whisper model"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            _ = try await modelManager.importModel(from: sourceURL, as: selectedWhisperModel)
            lastError = nil
            await refreshWhisperModelStatus()
        } catch {
            lastError = "The Whisper model could not be imported: \(error.localizedDescription)"
            await refreshWhisperModelStatus()
        }
    }

    func deleteSelectedWhisperModel() async {
        do {
            try await modelManager.removeModel(selectedWhisperModel)
            lastError = nil
            await refreshWhisperModelStatus()
        } catch {
            lastError = "The Whisper model could not be deleted: \(error.localizedDescription)"
            await refreshWhisperModelStatus()
        }
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
                lastError = "Some recording folders could not be recovered. Open the recordings folder for details."
            }
        } catch {
            recoveryCandidates = []
            recoveryIssues = []
            lastError = "Recovery scan failed: \(error.localizedDescription)"
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
                attributes: [.reason(error.localizedDescription)]
            )
            setFailure(error)
            return
        }

        try? await processingLogger.log(
            .transcriptionStarted,
            for: session,
            attributes: [.model(selectedWhisperModel.fileName)]
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
                        .reason(transcription.metadata.failureReason ?? "Transcription unavailable"),
                    ]
                )
            }

            let analysis: AnalysisOutcome
            if let recoveredAnalysis {
                analysis = recoveredAnalysis
            } else {
                analysis = await analyzeIfPossible(
                    session: session,
                    transcript: transcription.mergedTranscript
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
                        .reason(metadata.failureReason ?? "none"),
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
                analysis: analysis.analysis
            )
            if let output {
                setProcessingStep(
                    .exporting,
                    to: output.status == .completed ? .completed : .failed
                )
                try? await processingLogger.log(
                    output.status == .completed ? .exportCompleted : .exportFailed,
                    for: session,
                    attributes: output.failureReason.map { [.reason($0)] } ?? []
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
                analysis: analysis.metadata,
                output: output
            )
            completedSession = await cleanupSourceAudioIfEnabled(
                for: completedSession
            )
            currentSession = nil
            lastCompletedSession = completedSession
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
                attributes: [.reason(error.localizedDescription)]
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
                attributes: [.reason(error.localizedDescription)]
            )
            if lastError == nil {
                lastError = "Processing completed, but source CAF files were preserved: \(error.localizedDescription)"
            }
            return updated
        }
    }

    private func recoveredTranscriptionOutcome(
        session: RecordingSession,
        transcript: MergedTranscript
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
        return TranscriptionOutcome(metadata: metadata, mergedTranscript: transcript)
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
        let descriptor = selectedWhisperModel
        let modelStatus: WhisperModelStatus
        do {
            modelStatus = try await modelManager.status(for: descriptor)
            whisperModelStatus = modelStatus
        } catch {
            lastError = "Recording saved. Whisper model check failed: \(error.localizedDescription)"
            return TranscriptionOutcome(
                metadata: SessionTranscriptionMetadata(
                    status: .failed,
                    model: descriptor.fileName,
                    startedAt: nil,
                    completedAt: Date(),
                    systemSegmentCount: nil,
                    microphoneSegmentCount: nil,
                    warnings: [],
                    failureReason: error.localizedDescription
                ),
                mergedTranscript: nil
            )
        }

        guard case let .ready(modelURL, _) = modelStatus else {
            let reason: String
            if case let .invalid(invalidReason) = modelStatus {
                reason = invalidReason
            } else {
                reason = "Download or import the selected Whisper model to transcribe this recording."
            }
            lastError = "Recording saved. \(reason)"
            return TranscriptionOutcome(
                metadata: SessionTranscriptionMetadata(
                    status: .modelMissing,
                    model: descriptor.fileName,
                    startedAt: nil,
                    completedAt: Date(),
                    systemSegmentCount: nil,
                    microphoneSegmentCount: nil,
                    warnings: [],
                    failureReason: reason
                ),
                mergedTranscript: nil
            )
        }

        do {
            try transition(to: .transcribing)
            let result = try await sessionTranscriber.transcribe(
                session: session,
                finalization: finalization,
                modelURL: modelURL,
                language: session.metadata.language
            )
            return TranscriptionOutcome(
                metadata: result.metadata,
                mergedTranscript: result.mergedTranscript
            )
        } catch {
            lastError = "Recording saved. Transcription failed: \(error.localizedDescription)"
            return TranscriptionOutcome(
                metadata: SessionTranscriptionMetadata(
                    status: .failed,
                    model: descriptor.fileName,
                    startedAt: nil,
                    completedAt: Date(),
                    systemSegmentCount: nil,
                    microphoneSegmentCount: nil,
                    warnings: [],
                    failureReason: error.localizedDescription
                ),
                mergedTranscript: nil
            )
        }
    }

    private func exportMarkdownIfPossible(
        session: RecordingSession,
        transcript: MergedTranscript?,
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
            lastError = "Transcript saved. Markdown export failed: \(error.localizedDescription)"
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
                lastError = "Transcript saved. AI analysis skipped: \(error.localizedDescription)"
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
            lastError = "Transcript saved. AI analysis failed: \(error.localizedDescription)"
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

    private func setFailure(_ error: Error) {
        stopCaptureMonitoring()
        lastError = error.localizedDescription
        if let activeStep = processingSteps.first(where: { $0.state == .active })?.id {
            setProcessingStep(activeStep, to: .failed)
        }

        if status != .failed {
            do {
                try stateMachine.transition(to: .failed)
                status = stateMachine.status
            } catch {
                lastError = "\(lastError ?? "Unknown error") \(error.localizedDescription)"
            }
        }
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
                    let reason = self.captureDiagnostics.systemAudio.failureReason
                        ?? "System audio capture failed."
                    if await self.stopRecordingForCaptureFailure(
                        reason: reason,
                        message: "Recording was stopped safely because system audio capture failed: \(reason) Existing audio was preserved."
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
                    let reason = "System audio capture stopped producing buffers."
                    if await self.stopRecordingForCaptureFailure(
                        reason: reason,
                        message: "Recording was stopped safely because system audio capture stalled. Existing audio was preserved."
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
                      !self.isStoppingForLowStorage,
                      let storage = try? await self.storageStatusProvider(),
                      !storage.hasSufficientCapacity else {
                    continue
                }

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
                let message = "Recording was stopped safely because free disk space became critically low. Existing audio was preserved."
                self.lastError = message
                await self.stopRecording()
                self.lastError = message
                break
            }
        }
    }

    private func stopRecordingForCaptureFailure(
        reason: String,
        message: String
    ) async -> Bool {
        guard !isStoppingForCaptureFailure, status == .recording else {
            return false
        }

        isStoppingForCaptureFailure = true
        if let session = currentSession {
            try? await processingLogger.log(
                .captureFailed,
                for: session,
                attributes: [.reason(reason)]
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
}

private struct AnalysisOutcome: Sendable {
    let metadata: SessionAnalysisMetadata?
    let analysis: MeetingAnalysis?

    static let none = AnalysisOutcome(metadata: nil, analysis: nil)
}
