import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var lastCompletedSession: RecordingSession?
    @Published private(set) var lastError: String?
    @Published private(set) var captureDiagnostics = CaptureSessionDiagnostics.empty
    @Published private(set) var whisperModelStatus: WhisperModelStatus = .missing
    @Published private(set) var isDownloadingWhisperModel = false
    @Published private(set) var outputFolderURL: URL?
    @Published private(set) var lastMarkdownURL: URL?
    @Published private(set) var hasOpenAIAPIKey = false
    @Published private(set) var isSavingOpenAIAPIKey = false
    @Published var selectedWhisperModelID = WhisperModelDescriptor.largeV3Turbo.id
    @Published var aiAnalysisEnabled = false
    @Published var selectedOpenAIModel = OpenAIAnalysisProvider.defaultModel
    @Published var openAIAPIKeyInput = ""
    @Published var meetingTitle = ""

    private var stateMachine = AppStateMachine()
    private let sessionManager: SessionManager
    private let captureCoordinator: CaptureCoordinator
    private let audioFinalizer: any AudioFinalizing
    private let modelManager: WhisperModelManager
    private let sessionTranscriber: any SessionTranscribing
    private let outputExporter: OutputExporter
    private let outputFolderStore: OutputFolderStore
    private let obsidianService: ObsidianService
    private let apiKeyStore: any APIKeyStoring
    private let analysisSettingsStore: AnalysisSettingsStore
    private var captureMonitorTask: Task<Void, Never>?

    init(
        sessionManager: SessionManager = SessionManager(),
        captureCoordinator: CaptureCoordinator = CaptureCoordinator(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        modelManager: WhisperModelManager = WhisperModelManager(),
        sessionTranscriber: any SessionTranscribing = SessionTranscriber(),
        outputExporter: OutputExporter = OutputExporter(),
        outputFolderStore: OutputFolderStore? = nil,
        obsidianService: ObsidianService = ObsidianService(),
        apiKeyStore: (any APIKeyStoring)? = nil,
        analysisSettingsStore: AnalysisSettingsStore? = nil
    ) {
        self.sessionManager = sessionManager
        self.captureCoordinator = captureCoordinator
        self.audioFinalizer = audioFinalizer
        self.modelManager = modelManager
        self.sessionTranscriber = sessionTranscriber
        self.outputExporter = outputExporter
        self.outputFolderStore = outputFolderStore ?? OutputFolderStore()
        self.obsidianService = obsidianService
        self.apiKeyStore = apiKeyStore ?? KeychainAPIKeyStore()
        self.analysisSettingsStore = analysisSettingsStore ?? AnalysisSettingsStore()
    }

    func prepareStorage() async {
        do {
            try await sessionManager.prepareStorage()
            try await modelManager.prepareStorage()
            outputFolderURL = outputFolderStore.restoreFolder()
            aiAnalysisEnabled = analysisSettingsStore.isEnabled
            let storedModel = analysisSettingsStore.model
            selectedOpenAIModel = OpenAIModelDescriptor.supported.contains { $0.id == storedModel }
                ? storedModel
                : OpenAIAnalysisProvider.defaultModel
            hasOpenAIAPIKey = try await apiKeyStore.load() != nil
            await refreshWhisperModelStatus()
        } catch {
            setFailure(error)
        }
    }

    func startRecording() async {
        do {
            try transition(to: .preparing)
            lastError = nil
            lastMarkdownURL = nil

            let session = try await sessionManager.startSession(title: meetingTitle)
            currentSession = session

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
                throw error
            }

            try transition(to: .recording)
            startCaptureMonitoring()
        } catch {
            setFailure(error)
        }
    }

    func stopRecording() async {
        do {
            try transition(to: .stopping)
            let stoppedAt = Date()
            stopCaptureMonitoring()

            let diagnostics = await captureCoordinator.stop()
            captureDiagnostics = diagnostics

            guard let session = currentSession else {
                throw SessionManagerError.noActiveSession
            }
            let recordingEndedAt = max(stoppedAt, session.metadata.startedAt ?? stoppedAt)

            let finalization: AudioFinalizationMetadata
            do {
                finalization = try await audioFinalizer.finalize(
                    session: session,
                    diagnostics: diagnostics
                )
            } catch {
                let failedSession = try await sessionManager.failSession(
                    reason: error.localizedDescription,
                    now: recordingEndedAt,
                    systemAudio: diagnostics.systemAudio.sessionMetadata,
                    microphoneAudio: diagnostics.microphone.sessionMetadata
                )
                currentSession = nil
                lastCompletedSession = failedSession
                setFailure(error)
                return
            }

            let transcription = await transcribeIfPossible(
                session: session,
                finalization: finalization
            )
            let analysis = await analyzeIfPossible(
                session: session,
                transcript: transcription.mergedTranscript
            )
            try transition(to: .exporting)

            var exportSession = session
            exportSession.metadata.endedAt = recordingEndedAt
            let output = exportMarkdownIfPossible(
                session: exportSession,
                transcript: transcription.mergedTranscript,
                analysis: analysis.analysis
            )

            let completedSession = try await sessionManager.stopSession(
                now: recordingEndedAt,
                systemAudio: diagnostics.systemAudio.sessionMetadata,
                microphoneAudio: diagnostics.microphone.sessionMetadata,
                audioFinalization: finalization,
                transcription: transcription.metadata,
                analysis: analysis.metadata,
                output: output
            )
            currentSession = nil
            lastCompletedSession = completedSession
            try transition(to: .completed)
        } catch {
            setFailure(error)
        }
    }

    func reset() {
        guard status == .completed || status == .failed else { return }

        do {
            try transition(to: .idle)
            lastError = nil
            captureDiagnostics = .empty
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
        lastError = nil
        do {
            _ = try await modelManager.download(selectedWhisperModel)
            await refreshWhisperModelStatus()
        } catch {
            lastError = error.localizedDescription
            await refreshWhisperModelStatus()
        }
        isDownloadingWhisperModel = false
    }

    private func transition(to nextStatus: AppStatus) throws {
        try stateMachine.transition(to: nextStatus)
        status = stateMachine.status
    }

    private func transcribeIfPossible(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata
    ) async -> TranscriptionOutcome {
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
    ) -> SessionOutputMetadata? {
        guard let transcript else { return nil }

        let destination = outputFolderURL ?? session.directoryURL
        do {
            let result = try outputFolderStore.withAccess(to: destination) {
                try outputExporter.export(
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
        guard aiAnalysisEnabled, let transcript else { return .none }

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
                preferredLanguage: "sk"
            )
            let data = try JSONEncoder().encode(run.analysis)
            try data.write(to: session.analysisURL, options: .atomic)
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

        if status != .failed {
            do {
                try stateMachine.transition(to: .failed)
                status = stateMachine.status
            } catch {
                lastError = "\(lastError ?? "Unknown error") \(error.localizedDescription)"
            }
        }
    }

    private func startCaptureMonitoring() {
        stopCaptureMonitoring()

        captureMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }

                guard let self else { break }
                self.captureDiagnostics = await self.captureCoordinator.diagnostics()
            }
        }
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
