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
            ],
            performance: TrackTranscriptionPerformance(
                audioDurationSeconds: 60,
                activeDurationSeconds: 20,
                skippedDurationSeconds: 40,
                inferenceInputDurationSeconds: 21,
                chunkCount: 2,
                wallTimeSeconds: 4
            )
        )

        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        let decoded = try TranscriptJSONCoder.makeDecoder().decode(
            TrackTranscript.self,
            from: data
        )

        XCTAssertEqual(decoded, transcript)
    }

    func testHallucinationDetectorRecognizesDominantRepeatedPhrase() {
        let transcript = makeTranscript(
            texts: Array(repeating: "Titulky vytvořil Jirka Kováček.", count: 45)
        )

        XCTAssertTrue(WhisperHallucinationDetector.isStronglyRepetitive(transcript))
    }

    func testHallucinationDetectorIgnoresShortOrVariedTranscript() {
        let short = makeTranscript(texts: Array(repeating: "Áno.", count: 5))
        let varied = makeTranscript(texts: (0..<43).map { index in
            index < 2 ? "Ďakujem za pozornosť." : "Rozličná veta číslo \(index)."
        })

        XCTAssertFalse(WhisperHallucinationDetector.isStronglyRepetitive(short))
        XCTAssertFalse(WhisperHallucinationDetector.isStronglyRepetitive(varied))
    }

    func testHallucinationDetectorUsesOnlyImprovedAutomaticFallback() {
        let original = makeTranscript(texts: Array(repeating: "Opakovaná veta.", count: 12))
        let improved = makeTranscript(
            language: .automatic,
            detectedLanguage: "sk",
            texts: (0..<12).map { "Skutočná veta \($0)." }
        )
        let stillRepetitive = makeTranscript(
            language: .automatic,
            detectedLanguage: "sk",
            texts: Array(repeating: "Iná opakovaná veta.", count: 12)
        )
        let empty = makeTranscript(language: .automatic, detectedLanguage: "sk", texts: [])

        XCTAssertTrue(
            WhisperHallucinationDetector.shouldUseAutomaticFallback(
                original: original,
                fallback: improved
            )
        )
        XCTAssertFalse(
            WhisperHallucinationDetector.shouldUseAutomaticFallback(
                original: original,
                fallback: stillRepetitive
            )
        )
        XCTAssertFalse(
            WhisperHallucinationDetector.shouldUseAutomaticFallback(
                original: original,
                fallback: empty
            )
        )
    }

    func testMergedTranscriptJSONRoundTripPreservesTrackMetadata() throws {
        let transcript = MergedTranscript(
            sessionID: "session-1",
            title: "SOFA weekly",
            completedAt: Date(timeIntervalSince1970: 1_725_876_700),
            tracks: [
                MergedTranscriptTrack(
                    source: .system,
                    model: "ggml-test.bin",
                    requestedLanguage: .automatic,
                    detectedLanguage: "cs",
                    segmentCount: 0
                ),
            ],
            segments: []
        )

        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        let decoded = try TranscriptJSONCoder.makeDecoder().decode(
            MergedTranscript.self,
            from: data
        )

        XCTAssertEqual(decoded, transcript)
    }

    private func makeTranscript(
        language: TranscriptionLanguage = .czech,
        detectedLanguage: String = "cs",
        texts: [String]
    ) -> TrackTranscript {
        TrackTranscript(
            source: .system,
            model: "ggml-test.bin",
            requestedLanguage: language,
            detectedLanguage: detectedLanguage,
            completedAt: Date(timeIntervalSince1970: 1_725_876_700),
            segments: texts.enumerated().map { index, text in
                TranscriptSegment(
                    id: "system-\(index)",
                    source: .system,
                    speaker: "Other",
                    start: Double(index),
                    end: Double(index + 1),
                    language: detectedLanguage,
                    text: text,
                    confidence: nil
                )
            }
        )
    }
}
