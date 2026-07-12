import AVFoundation
import Foundation

final class MicrophoneCapture: AudioCaptureService, @unchecked Sendable {
    private struct TransferredPCMBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
    }

    private struct State {
        var isCapturing = false
        var writer: AudioFileWriter?
        var diagnostics = AudioCaptureDiagnostics.empty
        var tapInstalled = false
        var configurationRecoveryScheduled = false
        var configurationRecoveryAttempts = 0
    }

    private static let maximumConfigurationRecoveryAttempts = 8
    private static let minimumRecoveryBufferCount = 3
    private var engine: AVAudioEngine
    private let notificationCenter: NotificationCenter
    private let configurationRecoveryDelay: TimeInterval
    private let writerQueue = DispatchQueue(
        label: "com.martinhostak.MeetingScribe.microphone-audio",
        qos: .userInitiated
    )
    private var state = State()
    private var configurationObserver: NSObjectProtocol?

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        notificationCenter: NotificationCenter = .default,
        configurationRecoveryDelay: TimeInterval = 0.5
    ) {
        self.engine = engine
        self.notificationCenter = notificationCenter
        self.configurationRecoveryDelay = configurationRecoveryDelay
        observeConfigurationChanges(for: engine)
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Apple posts this callback on an internal queue and warns against
            // synchronous teardown there. Defer all engine work to our queue.
            self?.scheduleConfigurationRecovery()
        }
    }

    deinit {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
    }

    func start(outputURL: URL) async throws {
        let isAlreadyCapturing = writerQueue.sync { state.isCapturing }
        guard !isAlreadyCapturing else {
            throw AudioCaptureServiceError.alreadyCapturing
        }

        do {
            try await requestPermissionIfNeeded()
        } catch {
            setStartupFailure(error, outputURL: outputURL)
            throw error
        }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            let error = AudioCaptureServiceError.microphoneUnavailable
            setStartupFailure(error, outputURL: outputURL)
            throw error
        }

        writerQueue.sync {
            state = State(
                isCapturing: true,
                writer: AudioFileWriter(outputURL: outputURL),
                diagnostics: AudioCaptureDiagnostics(
                    fileName: outputURL.lastPathComponent,
                    startedAt: Date()
                )
            )
        }

        installTap(on: inputNode)
        writerQueue.sync { state.tapInstalled = true }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            writerQueue.sync {
                state.diagnostics.failureReason = error.localizedDescription
                state.writer?.finish()
                state.writer = nil
                state.isCapturing = false
                state.tapInstalled = false
            }
            throw error
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        let wasCapturing = writerQueue.sync { state.isCapturing }
        guard wasCapturing else {
            return writerQueue.sync { state.diagnostics }
        }

        let shouldRemoveTap = writerQueue.sync { () -> Bool in
            state.isCapturing = false
            state.configurationRecoveryScheduled = false
            return state.tapInstalled
        }
        if shouldRemoveTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()

        return writerQueue.sync {
            state.writer?.finish()
            state.writer = nil
            state.tapInstalled = false
            return state.diagnostics
        }
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        writerQueue.sync { state.diagnostics }
    }

    private func requestPermissionIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw AudioCaptureServiceError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw AudioCaptureServiceError.microphonePermissionDenied
        @unknown default:
            throw AudioCaptureServiceError.microphonePermissionDenied
        }
    }

    private func setStartupFailure(_ error: Error, outputURL: URL) {
        writerQueue.sync {
            state = State(
                isCapturing: false,
                writer: nil,
                diagnostics: AudioCaptureDiagnostics(
                    fileName: outputURL.lastPathComponent,
                    startedAt: Date(),
                    failureReason: error.localizedDescription
                )
            )
        }
    }

    private func installTap(on inputNode: AVAudioInputNode) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: nil
        ) { [weak self] buffer, time in
            guard
                let self,
                let copiedBuffer = Self.copy(buffer)
            else {
                return
            }

            let timestamp = AudioClock.seconds(for: time)
            let transferredBuffer = TransferredPCMBuffer(value: copiedBuffer)
            self.writerQueue.async { [weak self] in
                self?.write(
                    transferredBuffer.value,
                    presentationTimestamp: timestamp
                )
            }
        }
    }

    private func scheduleConfigurationRecovery() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard state.isCapturing, !state.configurationRecoveryScheduled else {
                return
            }
            state.configurationRecoveryScheduled = true
            writerQueue.asyncAfter(
                deadline: .now() + configurationRecoveryDelay
            ) { [weak self] in
                self?.recoverFromConfigurationChange()
            }
        }
    }

    private func recoverFromConfigurationChange() {
        state.configurationRecoveryScheduled = false
        guard state.isCapturing else { return }

        let previousEngine = engine
        let inputNode = previousEngine.inputNode
        if state.tapInstalled {
            inputNode.removeTap(onBus: 0)
            state.tapInstalled = false
        }
        previousEngine.stop()
        previousEngine.reset()

        // Recreate the engine after a route change. A successfully restarted
        // instance can otherwise remain attached to the old hardware route and
        // report `isRunning` without ever delivering microphone buffers.
        let replacementEngine = AVAudioEngine()
        engine = replacementEngine
        observeConfigurationChanges(for: replacementEngine)

        let replacementInputNode = replacementEngine.inputNode
        let format = replacementInputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            retryConfigurationRecovery(reason: "The selected microphone is not ready.")
            return
        }

        let baselineBufferCount = state.diagnostics.bufferCount
        installTap(on: replacementInputNode)
        state.tapInstalled = true
        replacementEngine.prepare()
        do {
            try replacementEngine.start()
            verifyConfigurationRecovery(after: baselineBufferCount)
        } catch {
            replacementInputNode.removeTap(onBus: 0)
            state.tapInstalled = false
            retryConfigurationRecovery(reason: error.localizedDescription)
        }
    }

    private func verifyConfigurationRecovery(after baselineBufferCount: Int) {
        state.configurationRecoveryScheduled = true
        writerQueue.asyncAfter(
            deadline: .now() + max(configurationRecoveryDelay, 1.0)
        ) { [weak self] in
            guard let self else { return }
            state.configurationRecoveryScheduled = false
            guard state.isCapturing else { return }

            let receivedBufferCount =
                state.diagnostics.bufferCount - baselineBufferCount
            guard receivedBufferCount >= Self.minimumRecoveryBufferCount else {
                retryConfigurationRecovery(
                    reason: "The audio engine started but the microphone produced no buffers."
                )
                return
            }

            state.configurationRecoveryAttempts = 0
            if state.writer != nil {
                state.diagnostics.failureReason = nil
            }
        }
    }

    private func retryConfigurationRecovery(reason: String) {
        state.configurationRecoveryAttempts += 1
        guard
            state.configurationRecoveryAttempts
                < Self.maximumConfigurationRecoveryAttempts
        else {
            state.diagnostics.failureReason =
                "Microphone did not resume after the audio device changed: \(reason)"
            return
        }

        state.configurationRecoveryScheduled = true
        writerQueue.asyncAfter(
            deadline: .now() + configurationRecoveryDelay
        ) { [weak self] in
            self?.recoverFromConfigurationChange()
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        presentationTimestamp: Double
    ) {
        guard state.isCapturing, let writer = state.writer else { return }

        do {
            let result = try writer.write(buffer)
            state.diagnostics.registerBuffer(
                frameCount: result.frameCount,
                sampleRate: result.sampleRate,
                channelCount: result.channelCount,
                presentationTimestamp: presentationTimestamp
            )
        } catch {
            state.diagnostics.failureReason = error.localizedDescription
            state.writer?.finish()
            state.writer = nil
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            guard
                let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else {
                return nil
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copy
    }
}
