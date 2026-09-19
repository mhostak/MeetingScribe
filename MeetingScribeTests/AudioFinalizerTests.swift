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
        var microphoneDiagnostics = diagnostics(
            fileName: "microphone.caf",
            channelCount: 1,
            presentationTimestamp: 42
        )
        microphoneDiagnostics.registerDroppedBuffers(2)

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: .empty,
                microphone: microphoneDiagnostics
            )
        )

        XCTAssertNil(metadata.system)
        let microphone = try XCTUnwrap(metadata.microphone)
        XCTAssertEqual(metadata.timelineOrigin, 42)
        XCTAssertEqual(microphone.timelineOffsetSeconds, 0)
        XCTAssertEqual(microphone.sampleRate, 16_000)
        XCTAssertEqual(metadata.warnings.count, 1)
        XCTAssertTrue(metadata.warnings[0].contains("dropped 2 audio buffers"))
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

    func testASkewedMicrophoneStartDoesNotShiftTheRequiredSystemTrack() async throws {
        // Capture starts ScreenCaptureKit first and the microphone after it,
        // so a microphone timestamp 30 seconds earlier is clock skew. Taken
        // as the origin it gave the required system track a 30-second offset
        // and moved every system segment that far later in the transcript.
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 1)

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: "system.caf",
                    channelCount: 2,
                    presentationTimestamp: 1_000
                ),
                microphone: diagnostics(
                    fileName: "microphone.caf",
                    channelCount: 1,
                    presentationTimestamp: 970
                )
            )
        )

        XCTAssertEqual(metadata.timelineOrigin, 1_000)
        XCTAssertEqual(metadata.system?.timelineOffsetSeconds, 0)
        XCTAssertNotNil(metadata.microphone, "the track is still finalized, only its zero is not used")
        XCTAssertEqual(metadata.microphone?.timelineOffsetSeconds, 0)
        XCTAssertTrue(metadata.warnings.contains { $0.contains("earlier than system audio") })
    }

    func testAMicrophoneStartingShortlyBeforeSystemAudioStillSetsTheOrigin() async throws {
        // Two subsystems reporting the same moment differ by a little, and
        // the first ScreenCaptureKit buffer arrives on its own schedule. A
        // small lead is ordinary and must keep working as before.
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 1)

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: "system.caf",
                    channelCount: 2,
                    presentationTimestamp: 1_000
                ),
                microphone: diagnostics(
                    fileName: "microphone.caf",
                    channelCount: 1,
                    presentationTimestamp: 998
                )
            )
        )

        XCTAssertEqual(metadata.timelineOrigin, 998)
        XCTAssertEqual(metadata.system?.timelineOffsetSeconds, 2)
        XCTAssertEqual(metadata.microphone?.timelineOffsetSeconds, 0)
        XCTAssertFalse(metadata.warnings.contains { $0.contains("earlier than system audio") })
    }

    func testAGapInsideATrackIsReportedInsteadOfPassingAsClean() async throws {
        // Rebuilding the audio engine after a headset reconnects costs
        // seconds. No silence is inserted and only a start offset is applied,
        // so the file simply ends up shorter than the wall clock it covers
        // and everything after the gap sits early against the other track.
        let session = makeSession()
        try writeCAF(to: session.systemAudioURL, channelCount: 2, duration: 1)
        try writeCAF(to: session.microphoneAudioURL, channelCount: 1, duration: 1)

        var interrupted = AudioCaptureDiagnostics(fileName: "microphone.caf", startedAt: Date())
        interrupted.registerBuffer(
            frameCount: 48_000, sampleRate: 48_000, channelCount: 1, presentationTimestamp: 100
        )
        // The next buffer arrives ten seconds later: the engine was rebuilt.
        interrupted.registerBuffer(
            frameCount: 48_000, sampleRate: 48_000, channelCount: 1, presentationTimestamp: 110
        )

        let metadata = try await AudioFinalizer().finalize(
            session: session,
            diagnostics: CaptureSessionDiagnostics(
                systemAudio: diagnostics(
                    fileName: "system.caf",
                    channelCount: 2,
                    presentationTimestamp: 100
                ),
                microphone: interrupted
            )
        )

        XCTAssertNotNil(metadata.microphone, "the audio that was captured is still kept")
        let gap = try XCTUnwrap(metadata.warnings.first { $0.contains("were missed during capture") })
        XCTAssertTrue(gap.hasPrefix("Microphone covers 11.0 seconds"), gap)
        XCTAssertTrue(gap.contains("About 10.0 seconds"), gap)
        XCTAssertFalse(
            metadata.warnings.contains { $0.hasPrefix("System audio covers") },
            "an uninterrupted track must not be reported"
        )
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

    func testRecordingAudioCleanupDeletesOnlyReferencedAudioAndPersistsAudit() async throws {
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let session = try makeProcessedRecordingSession(
            id: "eligible",
            completedAt: completedAt
        )
        let unrelatedURL = session.directoryURL.appendingPathComponent("notes.wav")
        try Data(repeating: 3, count: 64).write(to: unrelatedURL)
        let service = RecordingAudioCleanupService(
            recordingsRoot: temporaryRoot,
            now: { completedAt.addingTimeInterval(60) }
        )

        let plan = try await service.scan()
        XCTAssertEqual(plan.candidates.map(\.id), ["eligible"])
        XCTAssertEqual(plan.candidates.first?.files.map(\.relativePath), [
            "microphone-16k.wav",
            "system-16k.wav",
        ])
        XCTAssertGreaterThan(plan.reclaimableBytes, 0)

        let report = try await service.execute(plan, trigger: .manual)

        XCTAssertEqual(report.cleanedSessionIDs, ["eligible"])
        XCTAssertEqual(report.deletedFileCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.microphoneAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.mergedTranscriptURL.path))
        let metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: Data(contentsOf: session.manifestURL)
        )
        XCTAssertEqual(metadata.recordingAudioRetention?.cleanupStatus, .purged)
        XCTAssertEqual(metadata.recordingAudioRetention?.cleanupTrigger, .manual)
        XCTAssertEqual(metadata.recordingAudioRetention?.deletedFiles.count, 2)
        XCTAssertGreaterThan(metadata.recordingAudioRetention?.reclaimedBytes ?? 0, 0)
    }

    func testRecordingAudioCleanupSkipsKeptIncompleteAndTooRecentSessions() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try makeProcessedRecordingSession(
            id: "kept",
            completedAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            keepAudio: true
        )
        var incomplete = try makeProcessedRecordingSession(
            id: "incomplete",
            completedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        incomplete.metadata.output?.status = .failed
        try persistCleanupSession(incomplete)
        _ = try makeProcessedRecordingSession(
            id: "recent",
            completedAt: now.addingTimeInterval(-60)
        )
        _ = try makeProcessedRecordingSession(
            id: "old",
            completedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let service = RecordingAudioCleanupService(
            recordingsRoot: temporaryRoot,
            now: { now }
        )

        let plan = try await service.scan(
            olderThan: AudioRetentionPolicy.sevenDays.cutoffDate(now: now)
        )

        XCTAssertEqual(plan.candidates.map(\.id), ["old"])
        XCTAssertEqual(plan.keptSessionCount, 1)
        XCTAssertEqual(plan.ineligibleSessionCount, 2)
    }

    func testRecordingAudioCleanupRejectsPathTraversalWithoutTouchingOutsideFile() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = try makeProcessedRecordingSession(id: "unsafe", completedAt: now)
        let outsideURL = temporaryRoot.appendingPathComponent("outside.wav")
        try Data(repeating: 9, count: 32).write(to: outsideURL)
        session.metadata.audioFiles.system = "../outside.wav"
        session.metadata.audioFiles.microphone = "missing.wav"
        session.metadata.audioFinalization = nil
        try persistCleanupSession(session)
        let service = RecordingAudioCleanupService(recordingsRoot: temporaryRoot)

        let plan = try await service.scan()

        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    func testRecordingAudioCleanupRejectsSymlinkOutsideSession() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = try makeProcessedRecordingSession(id: "symlink", completedAt: now)
        let outsideURL = temporaryRoot.appendingPathComponent("outside-target.wav")
        try Data(repeating: 8, count: 48).write(to: outsideURL)
        try FileManager.default.removeItem(at: session.systemAudioURL)
        try FileManager.default.createSymbolicLink(
            at: session.systemAudioURL,
            withDestinationURL: outsideURL
        )
        let service = RecordingAudioCleanupService(recordingsRoot: temporaryRoot)

        let plan = try await service.scan()

        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    func testRecordingAudioCleanupCanProtectAndUnprotectSession() async throws {
        let session = try makeProcessedRecordingSession(id: "pin", completedAt: Date())
        let service = RecordingAudioCleanupService(recordingsRoot: temporaryRoot)

        _ = try await service.setKeepAudio(true, sessionID: session.metadata.id)
        let keptPlan = try await service.scan()
        XCTAssertTrue(keptPlan.candidates.isEmpty)
        XCTAssertEqual(keptPlan.keptSessionCount, 1)

        _ = try await service.setKeepAudio(false, sessionID: session.metadata.id)
        let unprotectedPlan = try await service.scan()
        XCTAssertEqual(unprotectedPlan.candidates.map(\.id), ["pin"])
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

    private func makeProcessedRecordingSession(
        id: String,
        completedAt: Date,
        keepAudio: Bool = false
    ) throws -> RecordingSession {
        let directory = temporaryRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdownURL = directory.appendingPathComponent("meeting.md")
        try Data("# Meeting".utf8).write(to: markdownURL)
        var metadata = SessionMetadata(
            id: id,
            title: id,
            status: .recorded,
            createdAt: completedAt.addingTimeInterval(-60),
            startedAt: completedAt.addingTimeInterval(-60),
            endedAt: completedAt,
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "test",
                systemSegmentCount: 1,
                microphoneSegmentCount: 1,
                mergedSegmentCount: 2,
                warnings: [],
                failureReason: nil
            ),
            output: SessionOutputMetadata(
                status: .completed,
                markdownFileName: markdownURL.lastPathComponent,
                markdownPath: markdownURL.path,
                exportedAt: completedAt,
                failureReason: nil
            )
        )
        if keepAudio {
            metadata.recordingAudioRetention = RecordingAudioRetentionMetadata(keepAudio: true)
        }
        let session = RecordingSession(metadata: metadata, directoryURL: directory)
        try Data(repeating: 1, count: 128).write(to: session.systemAudioURL)
        try Data(repeating: 2, count: 96).write(to: session.microphoneAudioURL)
        let transcript = MergedTranscript(
            sessionID: id,
            title: id,
            completedAt: completedAt,
            tracks: [],
            segments: [
                TranscriptSegment(
                    id: "segment-1",
                    source: .system,
                    speaker: "Other",
                    start: 0,
                    end: 1,
                    language: "sk",
                    text: "Test",
                    confidence: nil
                ),
            ]
        )
        try TranscriptJSONCoder.makeEncoder().encode(transcript)
            .write(to: session.mergedTranscriptURL, options: .atomic)
        try persistCleanupSession(session)
        return session
    }

    private func persistCleanupSession(_ session: RecordingSession) throws {
        try SessionJSONCoder.makeEncoder().encode(session.metadata)
            .write(to: session.manifestURL, options: .atomic)
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
