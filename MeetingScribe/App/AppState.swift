import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var lastCompletedSession: RecordingSession?
    @Published private(set) var lastError: String?
    @Published var meetingTitle = ""

    private var stateMachine = AppStateMachine()
    private let sessionManager: SessionManager

    init(sessionManager: SessionManager = SessionManager()) {
        self.sessionManager = sessionManager
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
            try transition(to: .recording)
        } catch {
            setFailure(error)
        }
    }

    func stopRecording() async {
        do {
            try transition(to: .stopping)
            let completedSession = try await sessionManager.stopSession()
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
}
