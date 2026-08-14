import Foundation
import XCTest
@testable import MeetingScribe

final class CaptureCoordinatorTests: XCTestCase {
    func testConcurrentStartsAreRejectedBeforeRequiredCaptureStartsTwice() async throws {
        let systemAudio = SuspendedAudioCaptureService()
        let coordinator = CaptureCoordinator(
            systemAudioCapture: systemAudio,
            microphoneCapture: MockAudioCaptureService()
        )
        let session = makeSession()

        let firstStart = Task { try await coordinator.start(for: session) }
        await systemAudio.waitUntilStarted()

        do {
            _ = try await coordinator.start(for: session)
            XCTFail("A second start must be rejected while the first start is suspended.")
        } catch let error as AudioCaptureServiceError {
            XCTAssertEqual(error, .alreadyCapturing)
        }

        await systemAudio.releaseStart()
        _ = try await firstStart.value
        let startCount = await systemAudio.startCount()
        XCTAssertEqual(startCount, 1)
        _ = await coordinator.stop()
    }

    func testStopDuringStartRollsBackAndAllowsAnotherRecording() async throws {
        let systemAudio = MockAudioCaptureService()
        let microphone = SuspendedAudioCaptureService()
        let coordinator = CaptureCoordinator(
            systemAudioCapture: systemAudio,
            microphoneCapture: microphone
        )
        let session = makeSession()

        let start = Task { try await coordinator.start(for: session) }
        await microphone.waitUntilStarted()
        let stop = Task { await coordinator.stop() }
        await microphone.releaseStart()

        do {
            _ = try await start.value
            XCTFail("Stopping during startup must cancel the in-flight start.")
        } catch is CancellationError {
            // Expected: the coordinator owns rollback of the partially started capture.
        }
        _ = await stop.value

        let requiredStopCount = await systemAudio.stopCount()
        XCTAssertGreaterThanOrEqual(requiredStopCount, 1)
        _ = try await coordinator.start(for: session)
        _ = await coordinator.stop()
        let requiredStartCount = await systemAudio.startCount()
        XCTAssertEqual(requiredStartCount, 2)
    }

    func testRequiredStartFailureRollsBackBothCaptureServices() async throws {
        let systemAudio = MockAudioCaptureService(
            startError: .screenRecordingPermissionDenied
        )
        let microphone = MockAudioCaptureService()
        let coordinator = CaptureCoordinator(
            systemAudioCapture: systemAudio,
            microphoneCapture: microphone
        )

        do {
            _ = try await coordinator.start(for: makeSession())
            XCTFail("A required system capture failure must fail the transaction.")
        } catch let error as AudioCaptureServiceError {
            XCTAssertEqual(error, .screenRecordingPermissionDenied)
        }

        let systemStopCount = await systemAudio.stopCount()
        let microphoneStopCount = await microphone.stopCount()
        XCTAssertEqual(systemStopCount, 1)
        XCTAssertEqual(microphoneStopCount, 1)

        do {
            _ = try await coordinator.start(for: makeSession())
        } catch let error as AudioCaptureServiceError {
            XCTAssertEqual(error, .screenRecordingPermissionDenied)
        }
        let systemStartCount = await systemAudio.startCount()
        XCTAssertEqual(systemStartCount, 2)
    }

    func testMicrophoneFailureDoesNotStopRequiredSystemCapture() async throws {
        let systemAudio = MockAudioCaptureService(bufferCount: 1)
        let microphone = MockAudioCaptureService(
            startError: .microphonePermissionDenied
        )
        let coordinator = CaptureCoordinator(
            systemAudioCapture: systemAudio,
            microphoneCapture: microphone
        )
        let session = makeSession()

        let started = try await coordinator.start(for: session)

        XCTAssertNil(started.systemAudio.failureReason)
        XCTAssertEqual(
            started.microphone.failureReason,
            AudioCaptureServiceError.microphonePermissionDenied.localizedDescription
        )

        let stopped = await coordinator.stop()
        XCTAssertEqual(stopped.systemAudio.bufferCount, 1)
        XCTAssertNotNil(stopped.microphone.failureReason)
    }

    func testMicrophoneOnlyStartsNoSystemCaptureAndRequiresMicrophone() async throws {
        let systemAudio = MockAudioCaptureService(
            startError: .screenRecordingPermissionDenied
        )
        let microphone = MockAudioCaptureService(bufferCount: 1)
        let coordinator = CaptureCoordinator(
            systemAudioCapture: systemAudio,
            microphoneCapture: microphone
        )

        let started = try await coordinator.start(
            for: makeSession(captureMode: .microphoneOnly)
        )

        let systemStartCount = await systemAudio.startCount()
        let microphoneStartCount = await microphone.startCount()
        XCTAssertEqual(systemStartCount, 0)
        XCTAssertEqual(microphoneStartCount, 1)
        XCTAssertEqual(started.systemAudio, .empty)
        XCTAssertEqual(started.microphone.bufferCount, 1)
        _ = await coordinator.stop()
    }

    func testMicrophoneOnlyFailureRollsBackAndFailsTransaction() async throws {
        let systemAudio = MockAudioCaptureService()
        let microphone = MockAudioCaptureService(
            startError: .microphonePermissionDenied
        )
        let coordinator = CaptureCoordinator(
            systemAudioCapture: systemAudio,
            microphoneCapture: microphone
        )

        do {
            _ = try await coordinator.start(
                for: makeSession(captureMode: .microphoneOnly)
            )
            XCTFail("Offline recording must not continue without a microphone.")
        } catch let error as AudioCaptureServiceError {
            XCTAssertEqual(error, .microphonePermissionDenied)
        }

        let systemStartCount = await systemAudio.startCount()
        let microphoneStartCount = await microphone.startCount()
        let microphoneStopCount = await microphone.stopCount()
        XCTAssertEqual(systemStartCount, 0)
        XCTAssertEqual(microphoneStartCount, 1)
        XCTAssertEqual(microphoneStopCount, 1)
    }

    private func makeSession(
        captureMode: CaptureMode = .systemAndMicrophone
    ) -> RecordingSession {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeCoordinator-\(UUID().uuidString)")
        return RecordingSession(
            metadata: SessionMetadata(
                id: "test-session",
                title: "Test",
                status: .recording,
                createdAt: Date(),
                captureMode: captureMode
            ),
            directoryURL: directoryURL
        )
    }
}

private actor MockAudioCaptureService: AudioCaptureService {
    private let startError: AudioCaptureServiceError?
    private var currentDiagnostics: AudioCaptureDiagnostics
    private var starts = 0
    private var stops = 0

    init(
        bufferCount: Int = 0,
        startError: AudioCaptureServiceError? = nil
    ) {
        self.startError = startError
        self.currentDiagnostics = AudioCaptureDiagnostics(
            bufferCount: bufferCount
        )
    }

    func start(outputURL: URL) async throws {
        starts += 1
        currentDiagnostics.fileName = outputURL.lastPathComponent
        currentDiagnostics.startedAt = Date()

        if let startError {
            currentDiagnostics.failureReason = startError.localizedDescription
            throw startError
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        stops += 1
        return currentDiagnostics
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        currentDiagnostics
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private actor SuspendedAudioCaptureService: AudioCaptureService {
    private var currentDiagnostics = AudioCaptureDiagnostics.empty
    private var starts = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func start(outputURL: URL) async throws {
        starts += 1
        if starts == 1 {
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        currentDiagnostics.fileName = outputURL.lastPathComponent
        currentDiagnostics.startedAt = Date()
    }

    func stop() async -> AudioCaptureDiagnostics { currentDiagnostics }
    func diagnostics() async -> AudioCaptureDiagnostics { currentDiagnostics }

    func waitUntilStarted() async {
        guard starts == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func startCount() -> Int { starts }
}
