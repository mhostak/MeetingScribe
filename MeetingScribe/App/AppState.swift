import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var lastCompletedSession: RecordingSession?
    @Published private(set) var lastError: String?
    @Published private(set) var captureDiagnostics = CaptureSessionDiagnostics.empty
    @Published var meetingTitle = ""

    private var stateMachine = AppStateMachine()
    private let sessionManager: SessionManager
    private let captureCoordinator: CaptureCoordinator
    private let audioFinalizer: any AudioFinalizing
    private var captureMonitorTask: Task<Void, Never>?

    init(
        sessionManager: SessionManager = SessionManager(),
        captureCoordinator: CaptureCoordinator = CaptureCoordinator(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer()
    ) {
        self.sessionManager = sessionManager
        self.captureCoordinator = captureCoordinator
        self.audioFinalizer = audioFinalizer
    }

    func prepareStorage() async {
        do {
            try await sessionManager.prepareStorage()
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

            try transition(to: .exporting)

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

            let completedSession = try await sessionManager.stopSession(
                systemAudio: diagnostics.systemAudio.sessionMetadata,
                microphoneAudio: diagnostics.microphone.sessionMetadata,
                audioFinalization: finalization
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

    private func transition(to nextStatus: AppStatus) throws {
        try stateMachine.transition(to: nextStatus)
        status = stateMachine.status
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
