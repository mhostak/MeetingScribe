import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import MeetingScribe

final class MicrophoneCaptureRecoveryTests: XCTestCase {
    func testRecoveryConfigurationPreservesProductionDefaults() {
        let configuration = MicrophoneRecoveryConfiguration()

        XCTAssertEqual(configuration.delay, 0.5)
        XCTAssertEqual(configuration.verificationDelay, 1.0)
        XCTAssertEqual(configuration.maximumAttempts, 8)
        XCTAssertEqual(configuration.minimumBufferCount, 3)
        XCTAssertEqual(configuration.maximumStartupAttempts, 2)
        XCTAssertEqual(configuration.startupVerificationDelay, 1)
    }

    func testRecoveryConfigurationNormalizesUnsafeValues() {
        let configuration = MicrophoneRecoveryConfiguration(
            delay: -1,
            maximumAttempts: 0,
            minimumBufferCount: 0,
            maximumStartupAttempts: 0,
            startupVerificationDelay: -1
        )

        XCTAssertEqual(configuration.delay, 0)
        XCTAssertEqual(configuration.maximumAttempts, 1)
        XCTAssertEqual(configuration.minimumBufferCount, 1)
        XCTAssertEqual(configuration.maximumStartupAttempts, 1)
        XCTAssertEqual(configuration.startupVerificationDelay, 0.05)
    }

    func testRecoveryPolicyUsesInjectedAttemptAndBufferLimits() {
        let configuration = MicrophoneRecoveryConfiguration(
            delay: 0.01,
            maximumAttempts: 2,
            minimumBufferCount: 4
        )

        XCTAssertTrue(configuration.shouldRetry(after: 1))
        XCTAssertFalse(configuration.shouldRetry(after: 2))
        XCTAssertFalse(configuration.hasEnoughRecoveredBuffers(baseline: 10, current: 13))
        XCTAssertTrue(configuration.hasEnoughRecoveredBuffers(baseline: 10, current: 14))
    }

    func testRouteRecoveryWaitsForStartAndStopWaitsForRecovery() async throws {
        let notificationCenter = NotificationCenter()
        let initialEngine = FakeMicrophoneAudioEngine(blockOnStart: true)
        let replacementEngine = FakeMicrophoneAudioEngine(blockOnStart: true)
        let capture = MicrophoneCapture(
            engine: initialEngine,
            engineFactory: { replacementEngine },
            notificationCenter: notificationCenter,
            recoveryConfiguration: MicrophoneRecoveryConfiguration(
                delay: 0,
                maximumAttempts: 2,
                minimumBufferCount: 1
            ),
            permissionRequester: {}
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneCaptureRecoveryTests-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let startTask = Task.detached {
            try await capture.start(outputURL: outputURL)
        }
        try await waitUntil { initialEngine.didEnterStart }

        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: initialEngine.notificationObject
        )
        initialEngine.releaseStart()
        try await startTask.value
        try await waitUntil { replacementEngine.didEnterStart }

        let completion = CompletionProbe()
        let stopTask = Task.detached {
            let diagnostics = await capture.stop()
            await completion.markFinished()
            return diagnostics
        }
        try await Task.sleep(for: .milliseconds(20))
        let stoppedWhileRecoveryWasBlocked = await completion.isFinished
        XCTAssertFalse(stoppedWhileRecoveryWasBlocked)

        replacementEngine.releaseStart()
        _ = await stopTask.value

        let operations = replacementEngine.operations
        let startExit = try XCTUnwrap(operations.firstIndex(of: "start-exit"))
        let stop = try XCTUnwrap(operations.firstIndex(of: "stop"))
        XCTAssertLessThan(startExit, stop)
    }

    func testStartupInstallsTapWithHardwareInputFormat() async throws {
        let engine = FakeMicrophoneAudioEngine(inputSampleRate: 48_000)
        let capture = MicrophoneCapture(
            engine: engine,
            engineFactory: { FakeMicrophoneAudioEngine() },
            notificationCenter: NotificationCenter(),
            recoveryConfiguration: MicrophoneRecoveryConfiguration(
                delay: 0,
                minimumBufferCount: 1,
                maximumStartupAttempts: 1,
                startupVerificationDelay: 0.05
            ),
            permissionRequester: {}
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneCaptureFormatTests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await capture.start(outputURL: outputURL)

        XCTAssertEqual(engine.installedTapSampleRates, [48_000])
        _ = await capture.stop()
    }

    func testRecoverableStartupErrorRecreatesEngineAndUsesFreshInputFormat() async throws {
        let errors = [
            NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported)),
            NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareNotRunningError)),
            NSError(domain: "com.apple.coreaudio.avfaudio", code: Int(kAudioHardwareNotRunningError))
        ]

        for error in errors {
            let initialEngine = FakeMicrophoneAudioEngine(startError: error)
            let replacementEngine = FakeMicrophoneAudioEngine(inputSampleRate: 32_000)
            let capture = makeStartupCapture(initialEngine, replacement: replacementEngine)
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MicrophoneCaptureRetryTests-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: outputURL) }

            try await capture.start(outputURL: outputURL)

            XCTAssertTrue(initialEngine.operations.contains("reset"))
            XCTAssertEqual(replacementEngine.installedTapSampleRates, [32_000])
            let diagnostics = await capture.diagnostics()
            XCTAssertGreaterThan(diagnostics.bufferCount, 0)
            XCTAssertNil(diagnostics.failureReason)
            _ = await capture.stop()
        }
    }

    func testStartupRetriesOnlyRecognizedAudioErrorsAndRespectsAttemptLimit() async throws {
        let cases: [(error: NSError, expectedRetries: Int)] = [
            (NSError(domain: "com.apple.coreaudio.avfaudio", code: Int(kAudioHardwareNotRunningError)), 1),
            (NSError(domain: "OtherErrorDomain", code: Int(kAudioHardwareNotRunningError)), 0),
            (NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareIllegalOperationError)), 0)
        ]

        for testCase in cases {
            let initialEngine = FakeMicrophoneAudioEngine(startError: testCase.error)
            let replacementEngine = FakeMicrophoneAudioEngine(startError: testCase.error)
            let factoryCalls = SynchronousCounter()
            let capture = makeStartupCapture(initialEngine, replacement: replacementEngine, factoryCalls: factoryCalls)
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MicrophoneCaptureFailureTests-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: outputURL) }

            do {
                try await capture.start(outputURL: outputURL)
                XCTFail("Startup must fail when the error persists or is not retryable.")
            } catch {
                XCTAssertEqual((error as NSError).domain, testCase.error.domain)
                XCTAssertEqual((error as NSError).code, testCase.error.code)
            }

            XCTAssertEqual(factoryCalls.value, testCase.expectedRetries)
            XCTAssertEqual(
                replacementEngine.operations.filter { $0 == "start-enter" }.count,
                testCase.expectedRetries
            )
            let diagnostics = await capture.stop()
            XCTAssertEqual(diagnostics.bufferCount, 0)
            XCTAssertEqual(diagnostics.failureReason, testCase.error.localizedDescription)
        }
    }

    func testCancellationDuringStartupRetryDoesNotStartReplacementEngine() async throws {
        let initialEngine = FakeMicrophoneAudioEngine(
            startError: NSError(domain: "com.apple.coreaudio.avfaudio", code: Int(kAudioHardwareNotRunningError))
        )
        let replacementEngine = FakeMicrophoneAudioEngine()
        let factoryCalls = SynchronousCounter()
        let capture = MicrophoneCapture(
            engine: initialEngine,
            engineFactory: {
                factoryCalls.increment()
                return replacementEngine
            },
            notificationCenter: NotificationCenter(),
            recoveryConfiguration: MicrophoneRecoveryConfiguration(
                delay: 0.5,
                minimumBufferCount: 1,
                maximumStartupAttempts: 2,
                startupVerificationDelay: 0.05
            ),
            permissionRequester: {}
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneCaptureCancellationTests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let startTask = Task { try await capture.start(outputURL: outputURL) }
        try await waitUntil { initialEngine.operations.contains("reset") }
        startTask.cancel()

        do {
            try await startTask.value
            XCTFail("Cancellation must interrupt the startup retry delay.")
        } catch is CancellationError {
            // Expected: do not create or start another engine after cancellation.
        }

        XCTAssertEqual(factoryCalls.value, 0)
        XCTAssertFalse(replacementEngine.didEnterStart)
        _ = await capture.stop()
    }

    func testStartupFailsWhenFreshEngineAlsoProducesNoBuffers() async throws {
        let initialEngine = FakeMicrophoneAudioEngine(producesBuffers: false)
        let replacementEngine = FakeMicrophoneAudioEngine(producesBuffers: false)
        let capture = MicrophoneCapture(
            engine: initialEngine,
            engineFactory: { replacementEngine },
            notificationCenter: NotificationCenter(),
            recoveryConfiguration: MicrophoneRecoveryConfiguration(
                delay: 0,
                minimumBufferCount: 1,
                maximumStartupAttempts: 2,
                startupVerificationDelay: 0.05
            ),
            permissionRequester: {}
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneCaptureNoDataTests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            try await capture.start(outputURL: outputURL)
            XCTFail("A microphone with no buffers must fail startup.")
        } catch let error as AudioCaptureServiceError {
            XCTAssertEqual(error, .microphoneProducedNoData)
        }

        let diagnostics = await capture.diagnostics()
        XCTAssertEqual(diagnostics.bufferCount, 0)
        XCTAssertEqual(
            diagnostics.failureReason,
            AudioCaptureServiceError.microphoneProducedNoData.localizedDescription
        )
    }

    func testHardwareNotRunningRetryMustReceiveBuffersBeforeReportingSuccess() async throws {
        let initialEngine = FakeMicrophoneAudioEngine(
            startError: NSError(domain: "com.apple.coreaudio.avfaudio", code: Int(kAudioHardwareNotRunningError))
        )
        let replacementEngine = FakeMicrophoneAudioEngine(producesBuffers: false)
        let capture = makeStartupCapture(initialEngine, replacement: replacementEngine)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneCaptureRetryNoDataTests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            try await capture.start(outputURL: outputURL)
            XCTFail("A successful engine start without audio buffers is not a recovered microphone.")
        } catch let error as AudioCaptureServiceError {
            XCTAssertEqual(error, .microphoneProducedNoData)
        }

        let diagnostics = await capture.stop()
        XCTAssertEqual(diagnostics.bufferCount, 0)
        XCTAssertEqual(diagnostics.failureReason, AudioCaptureServiceError.microphoneProducedNoData.localizedDescription)
        XCTAssertTrue(replacementEngine.operations.contains("stop"))
    }

    func testDelayedRecoveryFromStoppedCaptureDoesNotAffectNextCapture() async throws {
        let notificationCenter = NotificationCenter()
        let initialEngine = FakeMicrophoneAudioEngine()
        let replacementEngine = FakeMicrophoneAudioEngine()
        let factoryCalls = SynchronousCounter()
        let capture = MicrophoneCapture(
            engine: initialEngine,
            engineFactory: {
                factoryCalls.increment()
                return replacementEngine
            },
            notificationCenter: notificationCenter,
            recoveryConfiguration: MicrophoneRecoveryConfiguration(
                delay: 0.05,
                maximumAttempts: 2,
                minimumBufferCount: 1
            ),
            permissionRequester: {}
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneCaptureRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await capture.start(outputURL: directory.appendingPathComponent("first.caf"))
        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: initialEngine.notificationObject
        )
        _ = await capture.stop()
        try await capture.start(outputURL: directory.appendingPathComponent("second.caf"))

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(factoryCalls.value, 0)
        _ = await capture.stop()
    }

    func testStaleRecoveryDoesNotClearRecoveryScheduledForNewCapture() async throws {
        let notificationCenter = NotificationCenter()
        let initialEngine = FakeMicrophoneAudioEngine()
        let replacementEngine = FakeMicrophoneAudioEngine()
        let factoryCalls = SynchronousCounter()
        let capture = MicrophoneCapture(
            engine: initialEngine,
            engineFactory: {
                factoryCalls.increment()
                return replacementEngine
            },
            notificationCenter: notificationCenter,
            recoveryConfiguration: MicrophoneRecoveryConfiguration(
                delay: 0.2,
                maximumAttempts: 2,
                minimumBufferCount: 1
            ),
            permissionRequester: {}
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneCaptureRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await capture.start(outputURL: directory.appendingPathComponent("first.caf"))
        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: initialEngine.notificationObject
        )
        _ = await capture.stop()
        try await capture.start(outputURL: directory.appendingPathComponent("second.caf"))

        try await Task.sleep(for: .milliseconds(100))
        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: initialEngine.notificationObject
        )
        try await Task.sleep(for: .milliseconds(150))
        notificationCenter.post(
            name: .AVAudioEngineConfigurationChange,
            object: initialEngine.notificationObject
        )
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(factoryCalls.value, 1)
        _ = await capture.stop()
    }

    private func makeStartupCapture(
        _ initialEngine: FakeMicrophoneAudioEngine,
        replacement: FakeMicrophoneAudioEngine,
        factoryCalls: SynchronousCounter = SynchronousCounter()
    ) -> MicrophoneCapture {
        MicrophoneCapture(
            engine: initialEngine,
            engineFactory: {
                factoryCalls.increment()
                return replacement
            },
            notificationCenter: NotificationCenter(),
            recoveryConfiguration: MicrophoneRecoveryConfiguration(
                delay: 0,
                minimumBufferCount: 1,
                maximumStartupAttempts: 2,
                startupVerificationDelay: 0.05
            ),
            permissionRequester: {}
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for microphone engine operation.")
    }
}

private final class SynchronousCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private actor CompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private final class FakeMicrophoneAudioEngine: MicrophoneAudioEngine, @unchecked Sendable {
    let notificationObject: AnyObject = NSObject()

    private let condition = NSCondition()
    private let blockOnStart: Bool
    private let inputSampleRate: Double
    private let startError: NSError?
    private let producesBuffers: Bool
    private var shouldReleaseStart = false
    private var recordedOperations: [String] = []
    private var tapHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var installedSampleRates: [Double] = []

    init(
        blockOnStart: Bool = false,
        inputSampleRate: Double = 48_000,
        startError: NSError? = nil,
        producesBuffers: Bool = true
    ) {
        self.blockOnStart = blockOnStart
        self.inputSampleRate = inputSampleRate
        self.startError = startError
        self.producesBuffers = producesBuffers
    }

    var didEnterStart: Bool {
        condition.withLock { recordedOperations.contains("start-enter") }
    }

    var operations: [String] {
        condition.withLock { recordedOperations }
    }

    var installedTapSampleRates: [Double] {
        condition.withLock { installedSampleRates }
    }

    func inputFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 1)!
    }

    func installTap(
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        condition.withLock {
            recordedOperations.append("install-tap")
            installedSampleRates.append(format.sampleRate)
            tapHandler = handler
        }
    }

    func removeTap() { record("remove-tap") }
    func prepare() { record("prepare") }

    func start() throws {
        condition.lock()
        recordedOperations.append("start-enter")
        condition.broadcast()
        while blockOnStart, !shouldReleaseStart {
            condition.wait()
        }
        recordedOperations.append("start-exit")
        let handler = tapHandler
        let startError = startError
        condition.unlock()

        if let startError { throw startError }
        guard producesBuffers else { return }

        guard let handler,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: inputSampleRate,
                channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 128
              ) else {
            return
        }
        buffer.frameLength = 128
        for index in 0..<3 {
            handler(
                buffer,
                AVAudioTime(
                    sampleTime: AVAudioFramePosition(index * 128),
                    atRate: inputSampleRate
                )
            )
        }
    }

    func stop() { record("stop") }
    func reset() { record("reset") }

    func releaseStart() {
        condition.withLock {
            shouldReleaseStart = true
            condition.broadcast()
        }
    }

    private func record(_ operation: String) {
        condition.withLock {
            recordedOperations.append(operation)
        }
    }
}
