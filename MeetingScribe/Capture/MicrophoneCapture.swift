import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct MicrophoneRecoveryConfiguration: Equatable, Sendable {
    let delay: TimeInterval
    let maximumAttempts: Int
    let minimumBufferCount: Int
    let maximumStartupAttempts: Int
    let startupVerificationDelay: TimeInterval

    init(
        delay: TimeInterval = 0.5,
        maximumAttempts: Int = 8,
        minimumBufferCount: Int = 3,
        maximumStartupAttempts: Int = 2,
        startupVerificationDelay: TimeInterval = 1.0
    ) {
        self.delay = max(0, delay)
        self.maximumAttempts = max(1, maximumAttempts)
        self.minimumBufferCount = max(1, minimumBufferCount)
        self.maximumStartupAttempts = max(1, maximumStartupAttempts)
        self.startupVerificationDelay = max(0.05, startupVerificationDelay)
    }

    var verificationDelay: TimeInterval {
        max(delay, 1.0)
    }

    func hasEnoughRecoveredBuffers(baseline: Int, current: Int) -> Bool {
        current - baseline >= minimumBufferCount
    }

    func shouldRetry(after attempts: Int) -> Bool {
        attempts < maximumAttempts
    }
}

protocol MicrophoneAudioEngine: AnyObject {
    var notificationObject: AnyObject { get }
    func inputFormat() -> AVAudioFormat
    func installTap(
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    func reset()
}

private final class AVAudioEngineAdapter: MicrophoneAudioEngine {
    private let engine: AVAudioEngine

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    var notificationObject: AnyObject { engine }

    func inputFormat() -> AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    func installTap(
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format,
            block: handler
        )
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
    func reset() { engine.reset() }
}

final class MicrophoneCapture: AudioCaptureService, @unchecked Sendable {
    private static let tapFrameCapacity: AVAudioFrameCount = 8_192
    private static let tapBufferPoolSize = 8

    private final class PCMBufferPool: @unchecked Sendable {
        private let lock = NSLock()
        private var available: [AVAudioPCMBuffer]
        private var droppedBufferCount = 0

        init?(
            format: AVAudioFormat,
            frameCapacity: AVAudioFrameCount,
            count: Int
        ) {
            var buffers: [AVAudioPCMBuffer] = []
            for _ in 0..<count {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCapacity
                ) else {
                    return nil
                }
                buffers.append(buffer)
            }
            available = buffers
        }

        func take() -> AVAudioPCMBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return available.popLast()
        }

        func recycle(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            available.append(buffer)
            lock.unlock()
        }

        func registerDroppedBuffer() {
            lock.lock()
            droppedBufferCount += 1
            lock.unlock()
        }

        func takeDroppedBufferCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let count = droppedBufferCount
            droppedBufferCount = 0
            return count
        }
    }

    private struct TransferredPCMBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
        let pool: PCMBufferPool
    }

    private struct State {
        var isCapturing = false
        var writer: AudioFileWriter?
        var diagnostics = AudioCaptureDiagnostics.empty
        var tapInstalled = false
        var configurationRecoveryScheduled = false
        var configurationRecoveryAttempts = 0
        var bufferPools: [PCMBufferPool] = []
        var captureGeneration: UUID?
        var startupVerificationInProgress = false
        var configurationChangePendingDuringStartup = false
    }

    private var engine: any MicrophoneAudioEngine
    private let engineFactory: () -> any MicrophoneAudioEngine
    private let notificationCenter: NotificationCenter
    private let recoveryConfiguration: MicrophoneRecoveryConfiguration
    private let permissionRequester: () async throws -> Void
    private let writerQueue = DispatchQueue(
        label: "com.martinhostak.MeetingScribe.microphone-audio",
        qos: .userInitiated
    )
    private let writerQueueKey = DispatchSpecificKey<Void>()
    private var state = State()
    private var configurationObserver: NSObjectProtocol?

    convenience init(
        engine: AVAudioEngine = AVAudioEngine(),
        notificationCenter: NotificationCenter = .default,
        recoveryConfiguration: MicrophoneRecoveryConfiguration = MicrophoneRecoveryConfiguration()
    ) {
        self.init(
            engine: AVAudioEngineAdapter(engine: engine),
            engineFactory: { AVAudioEngineAdapter() },
            notificationCenter: notificationCenter,
            recoveryConfiguration: recoveryConfiguration,
            permissionRequester: { try await Self.requestPermissionIfNeeded() }
        )
    }

    init(
        engine: any MicrophoneAudioEngine,
        engineFactory: @escaping () -> any MicrophoneAudioEngine,
        notificationCenter: NotificationCenter,
        recoveryConfiguration: MicrophoneRecoveryConfiguration,
        permissionRequester: @escaping () async throws -> Void
    ) {
        self.engine = engine
        self.engineFactory = engineFactory
        self.notificationCenter = notificationCenter
        self.recoveryConfiguration = recoveryConfiguration
        self.permissionRequester = permissionRequester
        writerQueue.setSpecific(key: writerQueueKey, value: ())
        writerQueue.sync {
            observeConfigurationChanges(for: engine)
        }
    }

    private func observeConfigurationChanges(for engine: any MicrophoneAudioEngine) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.notificationObject,
            queue: nil
        ) { [weak self] _ in
            // Apple posts this callback on an internal queue and warns against
            // synchronous teardown there. Defer all engine work to our queue.
            self?.scheduleConfigurationRecovery()
        }
    }

    deinit {
        let removeObserver: () -> NSObjectProtocol? = {
            defer { self.configurationObserver = nil }
            return self.configurationObserver
        }
        let configurationObserver: NSObjectProtocol?
        if DispatchQueue.getSpecific(key: writerQueueKey) != nil {
            configurationObserver = removeObserver()
        } else {
            configurationObserver = writerQueue.sync(execute: removeObserver)
        }
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
    }

    func start(outputURL: URL) async throws {
        do {
            try await permissionRequester()
        } catch {
            setStartupFailure(error, outputURL: outputURL)
            throw error
        }

        let generation = try writerQueue.sync {
            guard !state.isCapturing else {
                throw AudioCaptureServiceError.alreadyCapturing
            }

            let generation = UUID()
            state = State(
                isCapturing: true,
                writer: AudioFileWriter(outputURL: outputURL),
                diagnostics: AudioCaptureDiagnostics(
                    fileName: outputURL.lastPathComponent,
                    startedAt: Date()
                ),
                captureGeneration: generation,
                startupVerificationInProgress: true
            )
            return generation
        }

        do {
            try await startAndVerify(generation: generation)
        } catch {
            failStartup(error, generation: generation)
            throw error
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        writerQueue.sync {
            flushDroppedBufferDiagnostics()
            guard state.isCapturing else { return state.diagnostics }

            state.isCapturing = false
            state.configurationRecoveryScheduled = false
            state.captureGeneration = nil
            let currentEngine = engine
            if state.tapInstalled {
                currentEngine.removeTap()
            }
            currentEngine.stop()

            finishWriter()
            state.tapInstalled = false
            return state.diagnostics
        }
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        writerQueue.sync {
            flushDroppedBufferDiagnostics()
            return state.diagnostics
        }
    }

    private func startAndVerify(generation: UUID) async throws {
        var attempt = 0
        while attempt < recoveryConfiguration.maximumStartupAttempts {
            try Task.checkCancellation()
            attempt += 1
            let baselineBufferCount: Int
            do {
                baselineBufferCount = try writerQueue.sync {
                    try startCurrentEngine(generation: generation)
                }
            } catch {
                guard attempt < recoveryConfiguration.maximumStartupAttempts,
                      Self.isRecoverableStartupError(error) else {
                    throw error
                }
                // Core Audio can report 'stop' while the input hardware is not ready.
                // Let it settle, then create a new engine using the current default
                // input instead of retrying an engine attached to a stale route.
                try await Task.sleep(for: .seconds(recoveryConfiguration.delay))
                try writerQueue.sync {
                    try replaceEngineForStartup(generation: generation)
                }
                continue
            }

            if try await waitForInitialBuffers(
                after: baselineBufferCount,
                generation: generation
            ) {
                let shouldRecoverConfiguration: Bool = writerQueue.sync {
                    guard state.captureGeneration == generation else { return false }
                    state.startupVerificationInProgress = false
                    state.configurationRecoveryAttempts = 0
                    state.diagnostics.failureReason = nil
                    let pending = state.configurationChangePendingDuringStartup
                    state.configurationChangePendingDuringStartup = false
                    return pending
                }
                if shouldRecoverConfiguration {
                    scheduleConfigurationRecovery()
                }
                return
            }

            guard attempt < recoveryConfiguration.maximumStartupAttempts else {
                throw AudioCaptureServiceError.microphoneProducedNoData
            }
            try writerQueue.sync {
                try replaceEngineForStartup(generation: generation)
            }
        }

        throw AudioCaptureServiceError.microphoneProducedNoData
    }

    private func startCurrentEngine(generation: UUID) throws -> Int {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        guard state.isCapturing, state.captureGeneration == generation else {
            throw CancellationError()
        }

        let currentEngine = engine
        let format = currentEngine.inputFormat()
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureServiceError.microphoneUnavailable
        }

        let baselineBufferCount = state.diagnostics.bufferCount
        installTap(on: currentEngine, format: format)
        state.tapInstalled = true
        currentEngine.prepare()
        do {
            try currentEngine.start()
            return baselineBufferCount
        } catch {
            currentEngine.removeTap()
            currentEngine.stop()
            currentEngine.reset()
            state.tapInstalled = false
            throw error
        }
    }

    private func replaceEngineForStartup(generation: UUID) throws {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        guard state.isCapturing, state.captureGeneration == generation else {
            throw CancellationError()
        }

        let previousEngine = engine
        if state.tapInstalled {
            previousEngine.removeTap()
            state.tapInstalled = false
        }
        previousEngine.stop()
        previousEngine.reset()

        let replacementEngine = engineFactory()
        engine = replacementEngine
        observeConfigurationChanges(for: replacementEngine)
    }

    private func waitForInitialBuffers(
        after baselineBufferCount: Int,
        generation: UUID
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .milliseconds(Int64(recoveryConfiguration.startupVerificationDelay * 1_000))
        )

        while clock.now < deadline {
            try Task.checkCancellation()
            let status = writerQueue.sync {
                (
                    isCurrent: state.isCapturing && state.captureGeneration == generation,
                    bufferCount: state.diagnostics.bufferCount,
                    failureReason: state.diagnostics.failureReason
                )
            }
            guard status.isCurrent else { throw CancellationError() }
            if status.failureReason != nil {
                throw AudioCaptureServiceError.microphoneUnavailable
            }
            if recoveryConfiguration.hasEnoughRecoveredBuffers(
                baseline: baselineBufferCount,
                current: status.bufferCount
            ) {
                return true
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let currentBufferCount = writerQueue.sync { state.diagnostics.bufferCount }
        return recoveryConfiguration.hasEnoughRecoveredBuffers(
            baseline: baselineBufferCount,
            current: currentBufferCount
        )
    }

    private func failStartup(_ error: Error, generation: UUID) {
        writerQueue.sync {
            guard state.captureGeneration == generation else { return }
            let currentEngine = engine
            if state.tapInstalled {
                currentEngine.removeTap()
            }
            currentEngine.stop()
            currentEngine.reset()
            state.tapInstalled = false
            state.startupVerificationInProgress = false
            state.configurationChangePendingDuringStartup = false
            state.configurationRecoveryScheduled = false
            state.diagnostics.registerFailureReason(error.localizedDescription)
            finishWriter()
            state.isCapturing = false
            state.captureGeneration = nil
        }
    }

    private static func isRecoverableStartupError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSOSStatusErrorDomain || error.domain == "com.apple.coreaudio.avfaudio" else {
            return false
        }
        return error.code == Int(kAudioUnitErr_FormatNotSupported)
            || error.code == Int(kAudioHardwareNotRunningError)
    }

    private static func requestPermissionIfNeeded() async throws {
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
            state = failedState(error: error, outputURL: outputURL)
        }
    }

    private func finishWriter() {
        guard let writer = state.writer else { return }
        do {
            try writer.finish()
        } catch {
            state.diagnostics.registerFailureReason(error.localizedDescription)
        }
        state.writer = nil
    }

    private func failedState(error: Error, outputURL: URL) -> State {
        State(
            isCapturing: false,
            writer: nil,
            diagnostics: AudioCaptureDiagnostics(
                fileName: outputURL.lastPathComponent,
                startedAt: Date(),
                failureReason: error.localizedDescription
            )
        )
    }

    private func installTap(
        on engine: any MicrophoneAudioEngine,
        format: AVAudioFormat
    ) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        guard let pool = PCMBufferPool(
            format: format,
            frameCapacity: Self.tapFrameCapacity,
            count: Self.tapBufferPoolSize
        ) else {
            state.diagnostics.registerFailureReason(
                "Could not allocate microphone capture buffers."
            )
            return
        }
        state.bufferPools.append(pool)
        engine.installTap(format: format) { [weak self] buffer, time in
            guard let self else { return }
            guard let copiedBuffer = pool.take() else {
                pool.registerDroppedBuffer()
                return
            }
            guard Self.copy(buffer, into: copiedBuffer) else {
                pool.recycle(copiedBuffer)
                return
            }

            let timestamp = AudioClock.seconds(for: time)
            let transferredBuffer = TransferredPCMBuffer(value: copiedBuffer, pool: pool)
            self.writerQueue.async { [weak self] in
                defer { transferredBuffer.pool.recycle(transferredBuffer.value) }
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
            guard state.isCapturing else { return }
            if state.startupVerificationInProgress {
                state.configurationChangePendingDuringStartup = true
                return
            }
            guard
                  !state.configurationRecoveryScheduled,
                  let generation = state.captureGeneration else {
                return
            }
            state.configurationRecoveryScheduled = true
            writerQueue.asyncAfter(
                deadline: .now() + recoveryConfiguration.delay
            ) { [weak self] in
                self?.recoverFromConfigurationChange(generation: generation)
            }
        }
    }

    private func recoverFromConfigurationChange(generation: UUID) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        guard state.isCapturing, state.captureGeneration == generation else { return }
        state.configurationRecoveryScheduled = false

        let previousEngine = engine
        if state.tapInstalled {
            previousEngine.removeTap()
            state.tapInstalled = false
        }
        previousEngine.stop()
        previousEngine.reset()

        // Recreate the engine after a route change. A successfully restarted
        // instance can otherwise remain attached to the old hardware route and
        // report `isRunning` without ever delivering microphone buffers.
        let replacementEngine = engineFactory()
        engine = replacementEngine
        observeConfigurationChanges(for: replacementEngine)

        let format = replacementEngine.inputFormat()
        guard format.sampleRate > 0, format.channelCount > 0 else {
            retryConfigurationRecovery(
                reason: "The selected microphone is not ready.",
                generation: generation
            )
            return
        }

        let baselineBufferCount = state.diagnostics.bufferCount
        installTap(on: replacementEngine, format: format)
        state.tapInstalled = true
        replacementEngine.prepare()
        do {
            try replacementEngine.start()
            verifyConfigurationRecovery(after: baselineBufferCount, generation: generation)
        } catch {
            replacementEngine.removeTap()
            state.tapInstalled = false
            retryConfigurationRecovery(reason: error.localizedDescription, generation: generation)
        }
    }

    private func verifyConfigurationRecovery(after baselineBufferCount: Int, generation: UUID) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        state.configurationRecoveryScheduled = true
        writerQueue.asyncAfter(
            deadline: .now() + recoveryConfiguration.verificationDelay
        ) { [weak self] in
            guard let self else { return }
            state.configurationRecoveryScheduled = false
            guard state.isCapturing, state.captureGeneration == generation else { return }

            guard recoveryConfiguration.hasEnoughRecoveredBuffers(
                baseline: baselineBufferCount,
                current: state.diagnostics.bufferCount
            ) else {
                retryConfigurationRecovery(
                    reason: "The audio engine started but the microphone produced no buffers.",
                    generation: generation
                )
                return
            }

            state.configurationRecoveryAttempts = 0
            if state.writer != nil {
                state.diagnostics.failureReason = nil
            }
        }
    }

    private func retryConfigurationRecovery(reason: String, generation: UUID) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        guard state.captureGeneration == generation else { return }
        state.configurationRecoveryAttempts += 1
        guard recoveryConfiguration.shouldRetry(
            after: state.configurationRecoveryAttempts
        ) else {
            state.diagnostics.failureReason =
                "Microphone did not resume after the audio device changed: \(reason)"
            return
        }

        state.configurationRecoveryScheduled = true
        writerQueue.asyncAfter(
            deadline: .now() + recoveryConfiguration.delay
        ) { [weak self] in
            self?.recoverFromConfigurationChange(generation: generation)
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        presentationTimestamp: Double?
    ) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        flushDroppedBufferDiagnostics()
        guard state.isCapturing, let writer = state.writer else { return }

        do {
            let result = try writer.write(buffer)
            guard result.frameCount > 0 else { return }
            state.diagnostics.registerBuffer(
                frameCount: result.frameCount,
                sampleRate: result.sampleRate,
                channelCount: result.channelCount,
                presentationTimestamp: presentationTimestamp,
                audioLevel: result.audioLevel
            )
        } catch {
            state.diagnostics.registerFailureReason(error.localizedDescription)
            finishWriter()
            state.isCapturing = false
            state.configurationRecoveryScheduled = false
            state.captureGeneration = nil
            if state.tapInstalled {
                engine.removeTap()
            }
            engine.stop()
            state.tapInstalled = false
        }
    }

    private func flushDroppedBufferDiagnostics() {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        for pool in state.bufferPools {
            state.diagnostics.registerDroppedBuffers(pool.takeDroppedBufferCount())
        }
    }

    private static func copy(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        guard source.frameLength > 0,
              source.frameLength <= destination.frameCapacity else {
            return false
        }

        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)

        guard sourceBuffers.count == destinationBuffers.count else { return false }

        for index in sourceBuffers.indices {
            guard
                let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else {
                return false
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return true
    }
}
