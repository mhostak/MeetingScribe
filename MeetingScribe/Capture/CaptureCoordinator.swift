import Foundation

actor CaptureCoordinator {
    private let systemAudioCapture: any AudioCaptureService
    private let microphoneCapture: any AudioCaptureService
    private var isCapturing = false

    init(
        systemAudioCapture: any AudioCaptureService = SystemAudioCapture(),
        microphoneCapture: any AudioCaptureService = MicrophoneCapture()
    ) {
        self.systemAudioCapture = systemAudioCapture
        self.microphoneCapture = microphoneCapture
    }

    func start(for session: RecordingSession) async throws -> CaptureSessionDiagnostics {
        guard !isCapturing else {
            throw AudioCaptureServiceError.alreadyCapturing
        }

        try await systemAudioCapture.start(outputURL: session.systemAudioURL)

        do {
            try await microphoneCapture.start(outputURL: session.microphoneAudioURL)
        } catch {
            // Microphone capture is optional. Its service persists the reason in
            // diagnostics while the required system audio stream keeps running.
        }

        isCapturing = true
        return await diagnostics()
    }

    func stop() async -> CaptureSessionDiagnostics {
        guard isCapturing else {
            return await diagnostics()
        }

        async let systemDiagnostics = systemAudioCapture.stop()
        async let microphoneDiagnostics = microphoneCapture.stop()
        let diagnostics = await CaptureSessionDiagnostics(
            systemAudio: systemDiagnostics,
            microphone: microphoneDiagnostics
        )
        isCapturing = false
        return diagnostics
    }

    func diagnostics() async -> CaptureSessionDiagnostics {
        async let systemDiagnostics = systemAudioCapture.diagnostics()
        async let microphoneDiagnostics = microphoneCapture.diagnostics()
        return await CaptureSessionDiagnostics(
            systemAudio: systemDiagnostics,
            microphone: microphoneDiagnostics
        )
    }
}
