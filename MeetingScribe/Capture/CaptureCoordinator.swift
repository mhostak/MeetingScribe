import Foundation

actor CaptureCoordinator {
    private enum Lifecycle: Equatable {
        case idle
        case starting
        case capturing
        case stopping
    }

    private let systemAudioCapture: any AudioCaptureService
    private let microphoneCapture: any AudioCaptureService
    private var lifecycle = Lifecycle.idle
    private var startTask: Task<CaptureSessionDiagnostics, Error>?
    private var stopTask: Task<CaptureSessionDiagnostics, Never>?

    init(
        systemAudioCapture: any AudioCaptureService = SystemAudioCapture(),
        microphoneCapture: any AudioCaptureService = MicrophoneCapture()
    ) {
        self.systemAudioCapture = systemAudioCapture
        self.microphoneCapture = microphoneCapture
    }

    func start(for session: RecordingSession) async throws -> CaptureSessionDiagnostics {
        guard lifecycle == .idle else {
            throw AudioCaptureServiceError.alreadyCapturing
        }
        lifecycle = .starting

        let systemAudioCapture = systemAudioCapture
        let microphoneCapture = microphoneCapture
        let task = Task<CaptureSessionDiagnostics, Error> {
            do {
                try Task.checkCancellation()
                try await systemAudioCapture.start(outputURL: session.systemAudioURL)
                try Task.checkCancellation()

                do {
                    try await microphoneCapture.start(outputURL: session.microphoneAudioURL)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Microphone capture is optional. Its service persists the reason in
                    // diagnostics while the required system audio stream keeps running.
                }
                try Task.checkCancellation()

                async let systemDiagnostics = systemAudioCapture.diagnostics()
                async let microphoneDiagnostics = microphoneCapture.diagnostics()
                return await CaptureSessionDiagnostics(
                    systemAudio: systemDiagnostics,
                    microphone: microphoneDiagnostics
                )
            } catch {
                // A service can fail after allocating capture resources, so rollback
                // both tracks even when its start call did not return successfully.
                async let systemStop = systemAudioCapture.stop()
                async let microphoneStop = microphoneCapture.stop()
                _ = await (systemStop, microphoneStop)
                throw error
            }
        }
        startTask = task

        do {
            let diagnostics = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            startTask = nil
            guard lifecycle == .starting else {
                throw CancellationError()
            }
            lifecycle = .capturing
            return diagnostics
        } catch {
            startTask = nil
            if lifecycle == .starting {
                lifecycle = .idle
            }
            throw error
        }
    }

    func stop() async -> CaptureSessionDiagnostics {
        if lifecycle == .stopping, let stopTask {
            return await stopTask.value
        }
        guard lifecycle != .idle else {
            return await diagnostics()
        }

        lifecycle = .stopping
        let pendingStartTask = startTask
        pendingStartTask?.cancel()
        let systemAudioCapture = systemAudioCapture
        let microphoneCapture = microphoneCapture
        let task = Task<CaptureSessionDiagnostics, Never> {
            _ = try? await pendingStartTask?.value
            async let systemDiagnostics = systemAudioCapture.stop()
            async let microphoneDiagnostics = microphoneCapture.stop()
            return await CaptureSessionDiagnostics(
                systemAudio: systemDiagnostics,
                microphone: microphoneDiagnostics
            )
        }
        stopTask = task
        let diagnostics = await task.value
        stopTask = nil
        lifecycle = .idle
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
