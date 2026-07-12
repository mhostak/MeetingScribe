import AVFoundation
import XCTest
@testable import MeetingScribe

final class AudioFinalizerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeFinalizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testConverterCreatesSixteenKilohertzMonoWAV() throws {
        let inputURL = temporaryRoot.appendingPathComponent("input.caf")
        let outputURL = temporaryRoot.appendingPathComponent("output.wav")
        try writeCAF(to: inputURL, channelCount: 2, duration: 1)

        let result = try WorkingAudioConverter().convert(
            inputURL: inputURL,
            outputURL: outputURL
        )
        let outputFile = try AVAudioFile(forReading: outputURL)

        XCTAssertEqual(result.sampleRate, 16_000)
        XCTAssertEqual(result.channelCount, 1)
        XCTAssertEqual(result.durationSeconds, 1, accuracy: 0.01)
        XCTAssertEqual(outputFile.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(outputFile.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(outputFile.length, 0)
    }

    func testFinalizerCreatesBothWorkingTracksWithTimelineOffsets() async throws {
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 1)
        let completedAt = Date(timeIntervalSince1970: 1_725_876_700)
        let finalizer = AudioFinalizer(now: { completedAt })

        let metadata = try await finalizer.finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: "system.caf",
                    channelCount: 2,
                    presentationTimestamp: 100.25
                ),
                microphone: diagnostics(
                    fileName: "microphone.caf",
                    channelCount: 1,
                    presentationTimestamp: 100
                )
            )
        )

        XCTAssertEqual(metadata.completedAt, completedAt)
        XCTAssertEqual(metadata.timelineOrigin, 100)
        XCTAssertEqual(metadata.system.timelineOffsetSeconds, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(metadata.microphone?.timelineOffsetSeconds, 0)
        XCTAssertEqual(metadata.system.sampleRate, 16_000)
        XCTAssertEqual(metadata.microphone?.sampleRate, 16_000)
        XCTAssertTrue(metadata.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemWorkingAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneWorkingAudioURL.path))
    }

    func testFinalizerPreservesRequiredSystemTrackWhenMicrophoneIsUnavailable() async throws {
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 0.5)
        var microphoneDiagnostics = AudioCaptureDiagnostics(
            fileName: "microphone.caf",
            startedAt: Date()
        )
        microphoneDiagnostics.failureReason = "Permission denied"

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: "system.caf",
                    channelCount: 2,
                    presentationTimestamp: 200
                ),
                microphone: microphoneDiagnostics
            )
        )

        XCTAssertNotNil(metadata.system)
        XCTAssertNil(metadata.microphone)
        XCTAssertEqual(metadata.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemWorkingAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.microphoneWorkingAudioURL.path))
    }

    func testFinalizerPreservesPartialMicrophoneTrackAfterRouteFailure() async throws {
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 0.5)
        var microphoneDiagnostics = diagnostics(
            fileName: "microphone.caf",
            channelCount: 1,
            presentationTimestamp: 300.1
        )
        microphoneDiagnostics.failureReason = "Audio input route did not recover."

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: "system.caf",
                    channelCount: 2,
                    presentationTimestamp: 300
                ),
                microphone: microphoneDiagnostics
            )
        )

        XCTAssertNotNil(metadata.microphone)
        XCTAssertEqual(metadata.warnings.count, 1)
        XCTAssertTrue(metadata.warnings[0].contains("ended early"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneWorkingAudioURL.path))
    }

    func testFinalizerRejectsEmptyRequiredSystemTrack() async throws {
        let session = makeSession()

        do {
            _ = try await AudioFinalizer().finalize(
                session: session,
                diagnostics: .empty
            )
            XCTFail("Expected an empty required system track to fail finalization.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("System audio track is empty"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.systemWorkingAudioURL.path))
    }

    private func makeSession() -> RecordingSession {
        RecordingSession(
            metadata: SessionMetadata(
                id: "test-session",
                title: "Test",
                status: .recording,
                createdAt: Date(),
                startedAt: Date()
            ),
            directoryURL: temporaryRoot
        )
    }

    private func diagnostics(
        fileName: String,
        channelCount: Int,
        presentationTimestamp: Double
    ) -> AudioCaptureDiagnostics {
        var value = AudioCaptureDiagnostics(
            fileName: fileName,
            startedAt: Date()
        )
        value.registerBuffer(
            frameCount: 48_000,
            sampleRate: 48_000,
            channelCount: channelCount,
            presentationTimestamp: presentationTimestamp
        )
        return value
    }

    private func writeCAF(
        to url: URL,
        channelCount: AVAudioChannelCount,
        duration: Double
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: channelCount
        ))
        let frameCount = AVAudioFrameCount(48_000 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount

        for channelIndex in 0..<Int(channelCount) {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channelIndex])
            for frameIndex in 0..<Int(frameCount) {
                samples[frameIndex] = sin(Float(frameIndex) * 0.02) * 0.25
            }
        }

        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }
}
