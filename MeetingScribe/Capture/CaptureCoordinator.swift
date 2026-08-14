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
    private var activeCaptureMode: CaptureMode?
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
        activeCaptureMode = session.metadata.resolvedCaptureMode

        let systemAudioCapture = systemAudioCapture
        let microphoneCapture = microphoneCapture
        let captureMode = session.metadata.resolvedCaptureMode
        let task = Task<CaptureSessionDiagnostics, Error> {
            do {
                try Task.checkCancellation()
                switch captureMode {
                case .systemAndMicrophone:
                    try await systemAudioCapture.start(outputURL: session.systemAudioURL)
                    try Task.checkCancellation()

                    do {
                        try await microphoneCapture.start(outputURL: session.microphoneAudioURL)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // The microphone is optional in online/hybrid mode. Its
                        // service persists the reason while system audio continues.
                    }
                case .microphoneOnly:
                    // An offline recording has no fallback source. A microphone
                    // startup failure therefore fails the complete transaction.
                    try await microphoneCapture.start(outputURL: session.microphoneAudioURL)
                }
                try Task.checkCancellation()

                async let systemDiagnostics = systemAudioCapture.diagnostics()
                async let microphoneDiagnostics = microphoneCapture.diagnostics()
                return await CaptureSessionDiagnostics(
                    systemAudio: captureMode == .microphoneOnly ? .empty : systemDiagnostics,
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
            activeCaptureMode = nil
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
        let captureMode = activeCaptureMode ?? .systemAndMicrophone
        let task = Task<CaptureSessionDiagnostics, Never> {
            _ = try? await pendingStartTask?.value
            async let systemDiagnostics = systemAudioCapture.stop()
            async let microphoneDiagnostics = microphoneCapture.stop()
            return await CaptureSessionDiagnostics(
                systemAudio: captureMode == .microphoneOnly ? .empty : systemDiagnostics,
                microphone: microphoneDiagnostics
            )
        }
        stopTask = task
        let diagnostics = await task.value
        stopTask = nil
        lifecycle = .idle
        activeCaptureMode = nil
        return diagnostics
    }

    func diagnostics() async -> CaptureSessionDiagnostics {
        let captureMode = activeCaptureMode ?? .systemAndMicrophone
        async let systemDiagnostics = systemAudioCapture.diagnostics()
        async let microphoneDiagnostics = microphoneCapture.diagnostics()
        return await CaptureSessionDiagnostics(
            systemAudio: captureMode == .microphoneOnly ? .empty : systemDiagnostics,
            microphone: microphoneDiagnostics
        )
    }
}
