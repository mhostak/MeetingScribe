import AVFoundation
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
    }

    func testRecoveryConfigurationNormalizesUnsafeValues() {
        let configuration = MicrophoneRecoveryConfiguration(
            delay: -1,
            maximumAttempts: 0,
            minimumBufferCount: 0
        )

        XCTAssertEqual(configuration.delay, 0)
        XCTAssertEqual(configuration.maximumAttempts, 1)
        XCTAssertEqual(configuration.minimumBufferCount, 1)
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
    private var shouldReleaseStart = false
    private var recordedOperations: [String] = []

    init(blockOnStart: Bool = false) {
        self.blockOnStart = blockOnStart
    }

    var didEnterStart: Bool {
        condition.withLock { recordedOperations.contains("start-enter") }
    }

    var operations: [String] {
        condition.withLock { recordedOperations }
    }

    func inputFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }

    func installTap(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        record("install-tap")
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
        condition.unlock()
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
