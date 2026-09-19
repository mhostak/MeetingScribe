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

    func testDroppedBuffersAreRecordedSeparatelyFromWrittenBuffers() {
        var diagnostics = AudioCaptureDiagnostics(startedAt: Date())

        diagnostics.registerBuffer(
            frameCount: 160,
            sampleRate: 16_000,
            channelCount: 1,
            presentationTimestamp: 0
        )
        diagnostics.registerDroppedBuffers(3)

        XCTAssertEqual(diagnostics.bufferCount, 1)
        XCTAssertEqual(diagnostics.droppedBufferCount, 3)
    }

    func testRegisterBufferKeepsBoundedLiveAudioLevelHistory() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        var diagnostics = AudioCaptureDiagnostics(startedAt: receivedAt)

        for index in 0..<70 {
            let normalizedLevel = Double(index) / 69
            let rmsDecibels = normalizedLevel * 60 - 60
            diagnostics.registerBuffer(
                frameCount: 160,
                sampleRate: 16_000,
                channelCount: 1,
                presentationTimestamp: Double(index) / 100,
                audioLevel: AudioLevelMeasurement(
                    rmsDecibels: rmsDecibels,
                    peakDecibels: rmsDecibels + 12
                ),
                receivedAt: receivedAt
            )
        }

        let levels = try XCTUnwrap(diagnostics.recentNormalizedAudioLevels)
        XCTAssertEqual(levels.count, 64)
        XCTAssertEqual(try XCTUnwrap(levels.last), 1, accuracy: 0.000_1)
        XCTAssertEqual(
            diagnostics.recentLiveAudioLevels(at: receivedAt.addingTimeInterval(0.5)).count,
            22
        )
        XCTAssertTrue(
            diagnostics.recentLiveAudioLevels(at: receivedAt.addingTimeInterval(2)).isEmpty
        )
    }

    func testCombinedLiveLevelsUseLouderAlignedSource() {
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        var system = AudioCaptureDiagnostics(startedAt: receivedAt)
        var microphone = AudioCaptureDiagnostics(startedAt: receivedAt)
        system.registerBuffer(
            frameCount: 160,
            sampleRate: 16_000,
            channelCount: 1,
            presentationTimestamp: 0,
            audioLevel: AudioLevelMeasurement(rmsDecibels: -48, peakDecibels: -36),
            receivedAt: receivedAt
        )
        microphone.registerBuffer(
            frameCount: 160,
            sampleRate: 16_000,
            channelCount: 1,
            presentationTimestamp: 0,
            audioLevel: AudioLevelMeasurement(rmsDecibels: -12, peakDecibels: 0),
            receivedAt: receivedAt
        )

        let levels = CaptureSessionDiagnostics(
            systemAudio: system,
            microphone: microphone
        ).combinedRecentAudioLevels(at: receivedAt)

        XCTAssertEqual(levels, [0.8])
    }

    func testAlreadyStoppedAndUserStoppedErrorsAreBenign() {
        let alreadyStopped = NSError(domain: SCStreamErrorDomain, code: -3_808)
        let userStopped = NSError(domain: SCStreamErrorDomain, code: -3_817)
        let audioFailure = NSError(domain: SCStreamErrorDomain, code: -3_819)

        XCTAssertTrue(SystemAudioCapture.isBenignStopError(alreadyStopped))
        XCTAssertTrue(SystemAudioCapture.isBenignStopError(userStopped))
        XCTAssertFalse(SystemAudioCapture.isBenignStopError(audioFailure))
    }

    func testUserDeclinedStartErrorMapsToScreenRecordingPermission() {
        let userDeclined = NSError(domain: SCStreamErrorDomain, code: -3_801)

        XCTAssertEqual(
            SystemAudioCapture.startError(for: userDeclined) as? AudioCaptureServiceError,
            .screenRecordingPermissionDenied
        )
    }

    func testUnrelatedStartErrorIsPreserved() {
        let streamFailure = NSError(domain: SCStreamErrorDomain, code: -3_819)

        XCTAssertTrue(SystemAudioCapture.startError(for: streamFailure) as NSError === streamFailure)
    }

    func testDropsAreVisibleBeforeAnyWriteCarriesThemIntoDiagnostics() {
        // A drop happens exactly when no pooled buffer is free, which is also
        // when nothing reaches the writer queue. Counting drops separately is
        // what makes an outage visible while it is happening rather than only
        // once it ends.
        let counter = DroppedBufferCounter()
        counter.increment()
        counter.increment()

        XCTAssertEqual(counter.pending, 2)
        XCTAssertEqual(counter.pending, 2, "reading must not consume the count")

        var reported = AudioCaptureDiagnostics.empty
        reported.registerDroppedBuffers(counter.pending)
        XCTAssertEqual(reported.droppedBufferCount, 2)

        XCTAssertEqual(counter.take(), 2)
        XCTAssertEqual(counter.pending, 0, "taking clears it so the next write cannot double count")
        XCTAssertEqual(counter.take(), 0)
    }

    func testPublishedDiagnosticsAreReadableWithoutTheCaptureQueue() {
        let box = AudioCaptureDiagnosticsBox()
        XCTAssertEqual(box.value, .empty)

        var diagnostics = AudioCaptureDiagnostics(fileName: "system-16k.wav", startedAt: Date())
        diagnostics.registerBuffer(
            frameCount: 1_024,
            sampleRate: 16_000,
            channelCount: 1,
            presentationTimestamp: 1
        )
        box.publish(diagnostics)

        XCTAssertEqual(box.value.bufferCount, 1)
        XCTAssertEqual(box.value.fileName, "system-16k.wav")
    }

    func testFirstFailureReasonSurvivesTheFailuresItCauses() {
        var diagnostics = AudioCaptureDiagnostics(fileName: "system-16k.wav", startedAt: Date())

        diagnostics.registerFailureReason("No space left on device")
        // What a caller sees after the first failure: no writer, then a stop
        // that reports capture was never running. Both arrive within
        // milliseconds and neither describes the cause.
        diagnostics.registerFailureReason(
            AudioCaptureServiceError.notCapturing.localizedDescription
        )
        diagnostics.registerFailureReason("The stream stopped.")

        XCTAssertEqual(diagnostics.failureReason, "No space left on device")
        XCTAssertEqual(diagnostics.health(), .failed)
        XCTAssertEqual(diagnostics.sessionMetadata.failureReason, "No space left on device")
    }

    func testAnEmptyFailureReasonDoesNotClaimTheSlot() {
        var diagnostics = AudioCaptureDiagnostics()

        diagnostics.registerFailureReason("   \n ")
        XCTAssertNil(diagnostics.failureReason)

        diagnostics.registerFailureReason("  No space left on device  ")
        XCTAssertEqual(diagnostics.failureReason, "No space left on device")
    }

    func testClearingLetsARecoveredTrackReportItsNextFailure() {
        // The microphone clears the reason once buffers flow again after a
        // route change, so keeping the first reason must not make a recovered
        // track permanently unable to report a new failure.
        var diagnostics = AudioCaptureDiagnostics()

        diagnostics.registerFailureReason("The audio engine stopped.")
        diagnostics.failureReason = nil
        diagnostics.registerFailureReason("No space left on device")

        XCTAssertEqual(diagnostics.failureReason, "No space left on device")
    }
}
