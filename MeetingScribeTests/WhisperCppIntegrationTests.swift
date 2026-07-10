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
}
