import Darwin
import Foundation
import XCTest
@testable import MeetingScribe

final class WhisperCppIntegrationTests: XCTestCase {
    func testReportsActivityPlanForExistingSessionWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sessionPath = environment["MEETINGSCRIBE_BENCHMARK_SESSION"] else {
            throw XCTSkip("Set MEETINGSCRIBE_BENCHMARK_SESSION for activity-plan diagnostics.")
        }

        let sessionURL = URL(fileURLWithPath: sessionPath, isDirectory: true)
        for source in TranscriptSource.allCases {
            let samples = try WhisperAudioReader().readSamples(
                from: sessionURL.appendingPathComponent("\(source.rawValue)-16k.wav")
            )
            let plan = WhisperAudioActivityDetector().activityPlan(for: samples)
            let batches = WhisperInferenceBatchPlanner().batches(for: plan.chunks)
            print(
                "WHISPER_ACTIVITY_PLAN "
                    + "source=\(source.rawValue) "
                    + "audio_seconds=\(plan.totalDurationSeconds) "
                    + "active_seconds=\(plan.activeDurationSeconds) "
                    + "skipped_seconds=\(plan.skippedDurationSeconds) "
                    + "inference_input_seconds=\(plan.inferenceDurationSeconds) "
                    + "activity_chunks=\(plan.chunks.count) "
                    + "inference_batches=\(batches.count) "
                    + "batched_input_seconds=\(Double(batches.reduce(0) { $0 + $1.inferenceSampleCount }) / WhisperAudioActivityDetector.sampleRate)"
            )
        }
    }

    func testBenchmarksExistingDualTrackSessionWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let modelPath = environment["MEETINGSCRIBE_WHISPER_MODEL"],
            let sessionPath = environment["MEETINGSCRIBE_BENCHMARK_SESSION"]
        else {
            throw XCTSkip(
                "Set MEETINGSCRIBE_WHISPER_MODEL and MEETINGSCRIBE_BENCHMARK_SESSION for a dual-track benchmark."
            )
        }

        let service = WhisperCppService()
        let sessionURL = URL(fileURLWithPath: sessionPath, isDirectory: true)
        let modelURL = URL(fileURLWithPath: modelPath)
        let language = environment["MEETINGSCRIBE_WHISPER_LANGUAGE"]
            .flatMap(TranscriptionLanguage.init(rawValue:))
            ?? .automatic

        let requestedSources = environment["MEETINGSCRIBE_BENCHMARK_SOURCE"]
            .flatMap(TranscriptSource.init(rawValue:))
            .map { [$0] }
            ?? TranscriptSource.allCases
        var transcripts: [TrackTranscript] = []
        for source in requestedSources {
            transcripts.append(try await service.transcribe(
                audioURL: sessionURL.appendingPathComponent("\(source.rawValue)-16k.wav"),
                modelURL: modelURL,
                options: TranscriptionOptions(
                    language: language,
                    source: source,
                    speaker: source == .system ? "Other" : "Martin"
                )
            ))
        }
        await service.releaseResources()

        for transcript in transcripts {
            printBenchmarkSummary(transcript)
            XCTAssertNotNil(transcript.performance)
            XCTAssertTrue(transcript.segments.allSatisfy {
                $0.start >= 0 && $0.end >= $0.start
            })
            XCTAssertTrue(zip(
                transcript.segments,
                transcript.segments.dropFirst()
            ).allSatisfy { $0.start <= $1.start })
        }
    }

    func testSuppressesLowEnergyHallucinationsWhenModelAndSilentSampleAreProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let modelPath = environment["MEETINGSCRIBE_WHISPER_MODEL"],
            let audioPath = environment["MEETINGSCRIBE_WHISPER_SILENT_AUDIO"]
        else {
            throw XCTSkip(
                "Set MEETINGSCRIBE_WHISPER_MODEL and MEETINGSCRIBE_WHISPER_SILENT_AUDIO for silence filtering."
            )
        }

        let transcript = try await WhisperCppService().transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            modelURL: URL(fileURLWithPath: modelPath),
            options: TranscriptionOptions(
                language: .czech,
                source: .microphone,
                speaker: "Martin"
            )
        )

        XCTAssertEqual(transcript.requestedLanguage, .czech)
        XCTAssertEqual(transcript.detectedLanguage, "cs")
        XCTAssertTrue(transcript.segments.isEmpty)
    }

    func testTranscribesRealAudioWhenModelAndSampleAreProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let modelPath = environment["MEETINGSCRIBE_WHISPER_MODEL"],
            let audioPath = environment["MEETINGSCRIBE_WHISPER_AUDIO"]
        else {
            throw XCTSkip("Set MEETINGSCRIBE_WHISPER_MODEL and MEETINGSCRIBE_WHISPER_AUDIO for inference testing.")
        }
        let language = environment["MEETINGSCRIBE_WHISPER_LANGUAGE"]
            .flatMap(TranscriptionLanguage.init(rawValue:))
            ?? .automatic

        let transcript = try await WhisperCppService().transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            modelURL: URL(fileURLWithPath: modelPath),
            options: TranscriptionOptions(
                language: language,
                source: .system,
                speaker: "Other",
                timelineOffsetSeconds: 1.25
            )
        )

        XCTAssertFalse(transcript.detectedLanguage.isEmpty)
        XCTAssertFalse(transcript.segments.isEmpty)
        if language != .automatic {
            XCTAssertEqual(transcript.detectedLanguage, language.rawValue)
        }
        if let expectedLanguage = environment["MEETINGSCRIBE_EXPECTED_LANGUAGE"] {
            XCTAssertEqual(transcript.detectedLanguage, expectedLanguage)
        }
        let textRepeatCounts = Dictionary(grouping: transcript.segments, by: \.text)
            .values
            .map(\.count)
        print(
            "WHISPER_TRANSCRIPT_SUMMARY "
                + "segments=\(transcript.segments.count) "
                + "unique=\(textRepeatCounts.count) "
                + "max_repeat=\(textRepeatCounts.max() ?? 0)"
        )
        XCTAssertTrue(transcript.segments.allSatisfy { segment in
            segment.source == .system
                && segment.speaker == "Other"
                && segment.start >= 1.25
                && segment.end >= segment.start
                && !segment.text.isEmpty
        })
    }

    func testReleasesModelContextAndReportsResidentMemoryWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEETINGSCRIBE_MEMORY_TEST"] == "1",
              let modelPath = environment["MEETINGSCRIBE_WHISPER_MODEL"],
              let audioPath = environment["MEETINGSCRIBE_WHISPER_AUDIO"] else {
            throw XCTSkip(
                "Set MEETINGSCRIBE_MEMORY_TEST=1 plus model and audio paths for the RSS lifecycle test."
            )
        }

        let service = WhisperCppService()
        let baselineBytes = try residentMemoryBytes()
        _ = try await service.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            modelURL: URL(fileURLWithPath: modelPath),
            options: TranscriptionOptions(
                language: .automatic,
                source: .system,
                speaker: "Other"
            )
        )
        let loadedBytes = try residentMemoryBytes()
        let contextWasLoaded = await service.hasLoadedContext()
        XCTAssertTrue(contextWasLoaded)

        await service.releaseResources()
        try await Task.sleep(for: .milliseconds(200))
        let releasedBytes = try residentMemoryBytes()
        let contextWasReleased = await service.hasLoadedContext()
        XCTAssertFalse(contextWasReleased)

        print(
            "WHISPER_MEMORY_BYTES baseline=\(baselineBytes) loaded=\(loadedBytes) released=\(releasedBytes)"
        )
    }

    private func residentMemoryBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(status))
        }
        return UInt64(info.resident_size)
    }

    private func printBenchmarkSummary(_ transcript: TrackTranscript) {
        let repetition = Dictionary(grouping: transcript.segments, by: \.text)
            .values
            .map(\.count)
            .max() ?? 0
        let performance = transcript.performance
        print(
            "WHISPER_BENCHMARK "
                + "source=\(transcript.source.rawValue) "
                + "segments=\(transcript.segments.count) "
                + "unique=\(Set(transcript.segments.map(\.text)).count) "
                + "max_repeat=\(repetition) "
                + "audio_seconds=\(performance?.audioDurationSeconds ?? 0) "
                + "active_seconds=\(performance?.activeDurationSeconds ?? 0) "
                + "skipped_seconds=\(performance?.skippedDurationSeconds ?? 0) "
                + "inference_input_seconds=\(performance?.inferenceInputDurationSeconds ?? 0) "
                + "chunks=\(performance?.chunkCount ?? 0) "
                + "wall_seconds=\(performance?.wallTimeSeconds ?? 0)"
        )
    }
}
