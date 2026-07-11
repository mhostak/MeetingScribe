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
    @Published var selectedWhisperModelID = WhisperModelDescriptor.largeV3Turbo.id
    @Published var meetingTitle = ""

    private var stateMachine = AppStateMachine()
    private let sessionManager: SessionManager
    private let captureCoordinator: CaptureCoordinator
    private let audioFinalizer: any AudioFinalizing
    private let modelManager: WhisperModelManager
    private let sessionTranscriber: any SessionTranscribing
    private var captureMonitorTask: Task<Void, Never>?

    init(
        sessionManager: SessionManager = SessionManager(),
        captureCoordinator: CaptureCoordinator = CaptureCoordinator(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        modelManager: WhisperModelManager = WhisperModelManager(),
        sessionTranscriber: any SessionTranscribing = SessionTranscriber()
    ) {
        self.sessionManager = sessionManager
        self.captureCoordinator = captureCoordinator
        self.audioFinalizer = audioFinalizer
        self.modelManager = modelManager
        self.sessionTranscriber = sessionTranscriber
    }

    func prepareStorage() async {
        do {
            try await sessionManager.prepareStorage()
            try await modelManager.prepareStorage()
            await refreshWhisperModelStatus()
        } catch {
            setFailure(error)
        }
    }

    func startRecording() async {
        do {
            try transition(to: .preparing)
            lastError = nil

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
            stopCaptureMonitoring()

            let diagnostics = await captureCoordinator.stop()
            captureDiagnostics = diagnostics

            guard let session = currentSession else {
                throw SessionManagerError.noActiveSession
            }

            let finalization: AudioFinalizationMetadata
            do {
                finalization = try await audioFinalizer.finalize(
                    session: session,
                    diagnostics: diagnostics
                )
            } catch {
                let failedSession = try await sessionManager.failSession(
                    reason: error.localizedDescription,
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
            try transition(to: .exporting)

            let completedSession = try await sessionManager.stopSession(
                systemAudio: diagnostics.systemAudio.sessionMetadata,
                microphoneAudio: diagnostics.microphone.sessionMetadata,
                audioFinalization: finalization,
                transcription: transcription
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
    ) async -> SessionTranscriptionMetadata {
        let descriptor = selectedWhisperModel
        let modelStatus: WhisperModelStatus
        do {
            modelStatus = try await modelManager.status(for: descriptor)
            whisperModelStatus = modelStatus
        } catch {
            lastError = "Recording saved. Whisper model check failed: \(error.localizedDescription)"
            return SessionTranscriptionMetadata(
                status: .failed,
                model: descriptor.fileName,
                startedAt: nil,
                completedAt: Date(),
                systemSegmentCount: nil,
                microphoneSegmentCount: nil,
                warnings: [],
                failureReason: error.localizedDescription
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
            return SessionTranscriptionMetadata(
                status: .modelMissing,
                model: descriptor.fileName,
                startedAt: nil,
                completedAt: Date(),
                systemSegmentCount: nil,
                microphoneSegmentCount: nil,
                warnings: [],
                failureReason: reason
            )
        }

        do {
            try transition(to: .transcribing)
            return try await sessionTranscriber.transcribe(
                session: session,
                finalization: finalization,
                modelURL: modelURL,
                language: session.metadata.language
            ).metadata
        } catch {
            lastError = "Recording saved. Transcription failed: \(error.localizedDescription)"
            return SessionTranscriptionMetadata(
                status: .failed,
                model: descriptor.fileName,
                startedAt: nil,
                completedAt: Date(),
                systemSegmentCount: nil,
                microphoneSegmentCount: nil,
                warnings: [],
                failureReason: error.localizedDescription
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
