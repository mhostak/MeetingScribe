import Foundation
import ScreenCaptureKit
import XCTest
@testable import MeetingScribe

final class AudioCaptureDiagnosticsTests: XCTestCase {
    func testHealthChangesFromWaitingToStalledWithoutBuffers() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let diagnostics = AudioCaptureDiagnostics(startedAt: startedAt)

        XCTAssertEqual(diagnostics.health(at: startedAt.addingTimeInterval(9)), .waitingForData)
        XCTAssertEqual(diagnostics.health(at: startedAt.addingTimeInterval(10)), .stalled)
    }

    func testRegisterBufferProducesActiveSessionMetadata() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let receivedAt = startedAt.addingTimeInterval(2)
        var diagnostics = AudioCaptureDiagnostics(
            fileName: "system.caf",
            startedAt: startedAt
        )

        diagnostics.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 2,
            presentationTimestamp: 20,
            receivedAt: receivedAt
        )
        diagnostics.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 2,
            presentationTimestamp: 20.1,
            receivedAt: receivedAt.addingTimeInterval(0.1)
        )

        XCTAssertEqual(diagnostics.health(at: receivedAt.addingTimeInterval(1)), .active)
        XCTAssertEqual(diagnostics.bufferCount, 2)
        XCTAssertEqual(diagnostics.totalFrames, 9_600)
        XCTAssertEqual(try XCTUnwrap(diagnostics.capturedDurationSeconds), 0.2, accuracy: 0.000_1)
        XCTAssertEqual(diagnostics.sessionMetadata.fileName, "system.caf")
    }

    func testFailureTakesPrecedenceOverBufferHealth() {
        var diagnostics = AudioCaptureDiagnostics(startedAt: Date())
        diagnostics.failureReason = "Writer failed"

        XCTAssertEqual(diagnostics.health(), .failed)
    }

    func testBufferWithoutCompatibleTimestampPreservesAudioStatistics() {
        var diagnostics = AudioCaptureDiagnostics(startedAt: Date())

        diagnostics.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 1,
            presentationTimestamp: nil
        )

        XCTAssertEqual(diagnostics.bufferCount, 1)
        XCTAssertEqual(diagnostics.totalFrames, 4_800)
        XCTAssertNil(diagnostics.firstPresentationTimestamp)
        XCTAssertNil(diagnostics.lastPresentationTimestamp)
    }

    func testAlreadyStoppedAndUserStoppedErrorsAreBenign() {
        let alreadyStopped = NSError(domain: SCStreamErrorDomain, code: -3_808)
        let userStopped = NSError(domain: SCStreamErrorDomain, code: -3_817)
        let audioFailure = NSError(domain: SCStreamErrorDomain, code: -3_819)

        XCTAssertTrue(SystemAudioCapture.isBenignStopError(alreadyStopped))
        XCTAssertTrue(SystemAudioCapture.isBenignStopError(userStopped))
        XCTAssertFalse(SystemAudioCapture.isBenignStopError(audioFailure))
    }
}
