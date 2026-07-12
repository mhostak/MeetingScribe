import Darwin
import Foundation
import XCTest
@testable import MeetingScribe

final class WhisperCppIntegrationTests: XCTestCase {
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
}
