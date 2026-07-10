import Foundation
import XCTest
@testable import MeetingScribe

final class TranscriptModelsTests: XCTestCase {
    func testWhisperTranscriptSanitizerRemovesEmptyAndNonSpeechMarkers() {
        XCTAssertNil(WhisperTranscriptSanitizer.meaningfulText(from: "  \n"))
        XCTAssertNil(WhisperTranscriptSanitizer.meaningfulText(from: "[BLANK_AUDIO]"))
        XCTAssertNil(WhisperTranscriptSanitizer.meaningfulText(from: " [Silence] "))
        XCTAssertNil(WhisperTranscriptSanitizer.meaningfulText(from: "(silence)"))
        XCTAssertEqual(
            WhisperTranscriptSanitizer.meaningfulText(from: "  Dobrý deň. \n"),
            "Dobrý deň."
        )
    }

    func testTrackTranscriptJSONRoundTripPreservesTimestampedSegment() throws {
        let transcript = TrackTranscript(
            source: .microphone,
            model: "ggml-large-v3-turbo.bin",
            requestedLanguage: .automatic,
            detectedLanguage: "sk",
            completedAt: Date(timeIntervalSince1970: 1_725_876_700),
            segments: [
                TranscriptSegment(
                    id: "microphone-000001",
                    source: .microphone,
                    speaker: "Martin",
                    start: 2.5,
                    end: 8.75,
                    language: "sk",
                    text: "Mali by sme to dokončiť do konca týždňa.",
                    confidence: nil
                )
            ]
        )

        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        let decoded = try TranscriptJSONCoder.makeDecoder().decode(
            TrackTranscript.self,
            from: data
        )

        XCTAssertEqual(decoded, transcript)
    }
}
