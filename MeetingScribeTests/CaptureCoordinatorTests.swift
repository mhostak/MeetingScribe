import Foundation
import XCTest
@testable import MeetingScribe

final class CaptureCoordinatorTests: XCTestCase {
    func testMicrophoneFailureDoesNotStopRequiredSystemCapture() async throws {
        let systemAudio = MockAudioCaptureService(bufferCount: 1)
        let microphone = MockAudioCaptureService(
            startError: .microphonePermissionDenied
        )
        let coordinator = CaptureCoordinator(
            systemAudioCapture: systemAudio,
            microphoneCapture: microphone
        )
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeCoordinator-\(UUID().uuidString)")
        let session = RecordingSession(
            metadata: SessionMetadata(
                id: "test-session",
                title: "Test",
                status: .recording,
                createdAt: Date()
            ),
            directoryURL: directoryURL
        )

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
}

private actor MockAudioCaptureService: AudioCaptureService {
    private let startError: AudioCaptureServiceError?
    private var currentDiagnostics: AudioCaptureDiagnostics

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
        currentDiagnostics.fileName = outputURL.lastPathComponent
        currentDiagnostics.startedAt = Date()

        if let startError {
            currentDiagnostics.failureReason = startError.localizedDescription
            throw startError
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        currentDiagnostics
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        currentDiagnostics
    }
}
