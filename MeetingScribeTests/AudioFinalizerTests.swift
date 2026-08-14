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

    func testConverterRejectsMissingInputWithTypedError() {
        let inputURL = temporaryRoot.appendingPathComponent("missing.caf")
        let outputURL = temporaryRoot.appendingPathComponent("output.wav")

        XCTAssertThrowsError(
            try WorkingAudioConverter().convert(inputURL: inputURL, outputURL: outputURL)
        ) { error in
            guard case let AudioConversionError.unreadableInput(fileName, _) = error else {
                return XCTFail("Expected unreadableInput, received \(error)")
            }
            XCTAssertEqual(fileName, "missing.caf")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testConverterRejectsEmptyInputWithTypedError() throws {
        let inputURL = temporaryRoot.appendingPathComponent("empty.caf")
        let outputURL = temporaryRoot.appendingPathComponent("output.wav")
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        var emptyFile: AVAudioFile? = try AVAudioFile(
            forWriting: inputURL,
            settings: format.settings
        )
        emptyFile = nil
        XCTAssertNil(emptyFile)

        XCTAssertThrowsError(
            try WorkingAudioConverter().convert(inputURL: inputURL, outputURL: outputURL)
        ) { error in
            guard case let AudioConversionError.emptyInput(fileName) = error else {
                return XCTFail("Expected emptyInput, received \(error)")
            }
            XCTAssertEqual(fileName, "empty.caf")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testConverterDrainPolicyRequiresTwoEmptyCyclesAndResetsAfterOutput() {
        var policy = AudioConverterDrainPolicy()

        XCTAssertEqual(
            policy.action(for: .inputRanDry, producedFrameCount: 0, reachedInputEnd: true),
            .continueConversion
        )
        XCTAssertEqual(policy.consecutiveEmptyDrains, 1)
        XCTAssertEqual(
            policy.action(for: .haveData, producedFrameCount: 128, reachedInputEnd: true),
            .continueConversion
        )
        XCTAssertEqual(policy.consecutiveEmptyDrains, 0)
        XCTAssertEqual(
            policy.action(for: .inputRanDry, producedFrameCount: 0, reachedInputEnd: true),
            .continueConversion
        )
        XCTAssertEqual(
            policy.action(for: .inputRanDry, producedFrameCount: 0, reachedInputEnd: true),
            .finish
        )
    }

    func testConverterDrainPolicyHandlesTerminalStatuses() {
        var policy = AudioConverterDrainPolicy()

        XCTAssertEqual(
            policy.action(for: .endOfStream, producedFrameCount: 0, reachedInputEnd: true),
            .finish
        )
        XCTAssertEqual(
            policy.action(for: .error, producedFrameCount: 0, reachedInputEnd: false),
            .fail
        )
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
        let system = try XCTUnwrap(metadata.system)
        XCTAssertEqual(system.timelineOffsetSeconds, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(metadata.microphone?.timelineOffsetSeconds, 0)
        XCTAssertEqual(system.sampleRate, 16_000)
        XCTAssertEqual(metadata.microphone?.sampleRate, 16_000)
        XCTAssertTrue(metadata.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemWorkingAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneWorkingAudioURL.path))
    }

    func testFinalizerUsesDirectTranscriptionWAVWithoutCreatingDuplicateWorkingFile() async throws {
        let session = RecordingSession(
            metadata: SessionMetadata(
                id: "direct-pcm",
                title: "Direct PCM",
                status: .recording,
                createdAt: Date(),
                startedAt: Date()
            ),
            directoryURL: temporaryRoot
        )
        try writeTranscriptionWAV(to: session.systemAudioURL, duration: 1)

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: session.systemAudioURL.lastPathComponent,
                    channelCount: 1,
                    presentationTimestamp: 10
                ),
                microphone: .empty
            )
        )

        let system = try XCTUnwrap(metadata.system)
        XCTAssertEqual(system.fileName, "system-16k.wav")
        XCTAssertEqual(system.sampleRate, 16_000)
        XCTAssertEqual(system.channelCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
    }

    func testMicrophoneOnlyFinalizesRequiredMicrophoneWithoutSystemTrack() async throws {
        var session = makeSession()
        session.metadata.captureMode = .microphoneOnly
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 1)

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: .empty,
                microphone: diagnostics(
                    fileName: "microphone.caf",
                    channelCount: 1,
                    presentationTimestamp: 42
                )
            )
        )

        XCTAssertNil(metadata.system)
        let microphone = try XCTUnwrap(metadata.microphone)
        XCTAssertEqual(metadata.timelineOrigin, 42)
        XCTAssertEqual(microphone.timelineOffsetSeconds, 0)
        XCTAssertEqual(microphone.sampleRate, 16_000)
        XCTAssertTrue(metadata.warnings.isEmpty)
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

    func testFinalizerPreservesPartialRequiredSystemTrackAfterCaptureFailure() async throws {
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        var systemDiagnostics = diagnostics(
            fileName: "system.caf",
            channelCount: 2,
            presentationTimestamp: 400
        )
        systemDiagnostics.failureReason = "No displays were available."

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: systemDiagnostics,
                microphone: .empty
            )
        )

        XCTAssertEqual(try XCTUnwrap(metadata.system).sampleRate, 16_000)
        XCTAssertTrue(metadata.warnings.contains {
            $0.contains("System audio capture ended early")
                && $0.contains("No displays were available")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemWorkingAudioURL.path))
    }

    func testFinalizerRejectsFailedRequiredSystemTrackWithoutAudio() async throws {
        let session = makeSession()
        var systemDiagnostics = AudioCaptureDiagnostics.empty
        systemDiagnostics.failureReason = "No displays were available."

        do {
            _ = try await AudioFinalizer().finalize(
                session: session,
                diagnostics: CaptureSessionDiagnostics(
                    systemAudio: systemDiagnostics,
                    microphone: .empty
                )
            )
            XCTFail("Expected failed required capture without audio to be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No displays were available"))
        }
    }

    func testFinalizerSkipsMicrophoneWithImplausibleTimelineOrigin() async throws {
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 1)

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: "system.caf",
                    channelCount: 2,
                    presentationTimestamp: 100
                ),
                microphone: diagnostics(
                    fileName: "microphone.caf",
                    channelCount: 1,
                    presentationTimestamp: 10_000
                )
            )
        )

        XCTAssertNil(metadata.microphone)
        XCTAssertTrue(metadata.warnings.contains { $0.contains("plausible host-time origin") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.microphoneWorkingAudioURL.path))
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

    func testSourceCleanerDeletesLegacyCAFOnlyAfterAllArtifactsAreVerified() throws {
        let session = try makeCleanupSession(includeMicrophoneTranscript: true)
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let result = try XCTUnwrap(AudioSourceCleaner(now: { completedAt })
            .cleanupSourceCAFIfEligible(session: session))

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.completedAt, completedAt)
        XCTAssertEqual(result.deletedFiles, ["system.caf", "microphone.caf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.microphoneAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemWorkingAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneWorkingAudioURL.path))
    }

    func testSourceCleanerPreservesEveryCAFWhenMicrophoneTranscriptIsMissing() throws {
        let session = try makeCleanupSession(includeMicrophoneTranscript: false)

        XCTAssertThrowsError(
            try AudioSourceCleaner().cleanupSourceCAFIfEligible(session: session)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneAudioURL.path))
    }

    func testSourceCleanerDoesNothingWhenExportDidNotComplete() throws {
        var session = try makeCleanupSession(includeMicrophoneTranscript: true)
        session.metadata.output?.status = .failed

        let result = try AudioSourceCleaner().cleanupSourceCAFIfEligible(session: session)

        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneAudioURL.path))
    }

    private func makeSession() -> RecordingSession {
        RecordingSession(
            metadata: SessionMetadata(
                id: "test-session",
                title: "Test",
                status: .recording,
                createdAt: Date(),
                startedAt: Date(),
                audioFiles: SessionAudioFiles(
                    system: "system.caf",
                    microphone: "microphone.caf",
                    systemWorking: "system-16k.wav",
                    microphoneWorking: "microphone-16k.wav"
                )
            ),
            directoryURL: temporaryRoot
        )
    }

    private func makeCleanupSession(
        includeMicrophoneTranscript: Bool
    ) throws -> RecordingSession {
        var session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 1)
        let system = try WorkingAudioConverter().convert(
            inputURL: session.systemAudioURL,
            outputURL: session.systemWorkingAudioURL
        )
        let microphone = try WorkingAudioConverter().convert(
            inputURL: session.microphoneAudioURL,
            outputURL: session.microphoneWorkingAudioURL
        )
        try Data("system transcript".utf8).write(to: session.systemTrackTranscriptURL)
        if includeMicrophoneTranscript {
            try Data("microphone transcript".utf8).write(to: session.microphoneTrackTranscriptURL)
        }
        let markdownURL = session.directoryURL.appendingPathComponent("meeting.md")
        try Data("# Meeting".utf8).write(to: markdownURL)
        session.metadata.status = .recorded
        session.metadata.audioFinalization = AudioFinalizationMetadata(
            completedAt: Date(),
            timelineOrigin: 0,
            system: FinalizedAudioTrackMetadata(
                fileName: session.systemWorkingAudioURL.lastPathComponent,
                sampleRate: system.sampleRate,
                channelCount: system.channelCount,
                totalFrames: system.totalFrames,
                durationSeconds: system.durationSeconds,
                timelineOffsetSeconds: 0
            ),
            microphone: FinalizedAudioTrackMetadata(
                fileName: session.microphoneWorkingAudioURL.lastPathComponent,
                sampleRate: microphone.sampleRate,
                channelCount: microphone.channelCount,
                totalFrames: microphone.totalFrames,
                durationSeconds: microphone.durationSeconds,
                timelineOffsetSeconds: 0
            ),
            warnings: []
        )
        session.metadata.transcription = SessionTranscriptionMetadata(
            status: .completed,
            model: "test",
            systemSegmentCount: 1,
            microphoneSegmentCount: includeMicrophoneTranscript ? 1 : nil,
            warnings: [],
            failureReason: nil
        )
        session.metadata.output = SessionOutputMetadata(
            status: .completed,
            markdownFileName: markdownURL.lastPathComponent,
            markdownPath: markdownURL.path,
            exportedAt: Date(),
            failureReason: nil
        )
        return session
    }

    private func writeTranscriptionWAV(to url: URL, duration: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let frameCount = AVAudioFrameCount(48_000 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        buffer.floatChannelData?[0].initialize(repeating: 0.2, count: Int(frameCount))
        let writer = AudioFileWriter(outputURL: url)
        _ = try writer.write(buffer)
        try writer.finish()
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
