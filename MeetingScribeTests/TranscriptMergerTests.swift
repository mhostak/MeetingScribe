import Foundation
import XCTest
@testable import MeetingScribe

final class TranscriptMergerTests: XCTestCase {
    private let completedAt = Date(timeIntervalSince1970: 1_725_876_700)

    func testMergeOrdersSegmentsDeterministicallyAndPreservesOverlap() throws {
        let system = makeTranscript(
            source: .system,
            detectedLanguage: "cs",
            segments: [
                makeSegment(
                    id: "system-later",
                    source: .system,
                    speaker: "Other",
                    start: 4,
                    end: 5,
                    language: "cs",
                    text: "Pozdější věta."
                ),
                makeSegment(
                    id: "system-overlap",
                    source: .system,
                    speaker: "Other",
                    start: 1.0004,
                    end: 3,
                    language: "cs",
                    text: "Nejdřív ověříme API."
                ),
            ]
        )
        let microphone = makeTranscript(
            source: .microphone,
            detectedLanguage: "sk",
            segments: [
                makeSegment(
                    id: "microphone-overlap",
                    source: .microphone,
                    speaker: "Martin",
                    start: 1.0004,
                    end: 2.5006,
                    language: "sk",
                    text: "Áno, súhlasím."
                ),
            ]
        )

        let merged = try TranscriptMerger().merge(
            sessionID: "session-1",
            title: "  CZ/SK sync  ",
            systemTranscript: system,
            microphoneTranscript: microphone,
            completedAt: completedAt
        )

        XCTAssertEqual(merged.sessionID, "session-1")
        XCTAssertEqual(merged.title, "CZ/SK sync")
        XCTAssertEqual(merged.tracks.map(\.source), [.system, .microphone])
        XCTAssertEqual(merged.tracks.map(\.detectedLanguage), ["cs", "sk"])
        XCTAssertEqual(merged.segments.map(\.id), [
            "segment-000000", "segment-000001", "segment-000002",
        ])
        XCTAssertEqual(merged.segments.map(\.source), [.system, .microphone, .system])
        XCTAssertEqual(merged.segments[0].start, 1)
        XCTAssertEqual(merged.segments[1].end, 2.501)
        XCTAssertLessThan(merged.segments[1].start, merged.segments[0].end)
    }

    func testMergeNormalizesTimestampsTextAndMissingSpeaker() throws {
        let system = makeTranscript(
            source: .system,
            segments: [
                makeSegment(
                    id: "empty",
                    source: .system,
                    speaker: "Other",
                    start: 0,
                    end: 1,
                    language: "en",
                    text: "  \n"
                ),
                makeSegment(
                    id: "blank-audio",
                    source: .system,
                    speaker: "Other",
                    start: 1,
                    end: 2,
                    language: "en",
                    text: "[BLANK_AUDIO]"
                ),
                makeSegment(
                    id: "normalized",
                    source: .system,
                    speaker: "  ",
                    start: -0.25,
                    end: -0.1,
                    language: " en ",
                    text: "  Hello. \n"
                ),
            ]
        )

        let merged = try TranscriptMerger().merge(
            sessionID: "session-2",
            title: "Test",
            systemTranscript: system,
            microphoneTranscript: nil,
            completedAt: completedAt
        )

        XCTAssertEqual(merged.segments.count, 1)
        XCTAssertEqual(merged.segments[0].start, 0)
        XCTAssertEqual(merged.segments[0].end, 0)
        XCTAssertEqual(merged.segments[0].speaker, "Other")
        XCTAssertEqual(merged.segments[0].language, "en")
        XCTAssertEqual(merged.segments[0].text, "Hello.")
    }

    func testMergeRejectsNonFiniteTimestamp() {
        let system = makeTranscript(
            source: .system,
            segments: [
                makeSegment(
                    id: "invalid",
                    source: .system,
                    speaker: "Other",
                    start: .infinity,
                    end: 1,
                    language: "en",
                    text: "Invalid"
                ),
            ]
        )

        XCTAssertThrowsError(
            try TranscriptMerger().merge(
                sessionID: "session-3",
                title: "Test",
                systemTranscript: system,
                microphoneTranscript: nil,
                completedAt: completedAt
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptMergeError, .invalidTimestamp(segmentID: "invalid"))
        }
    }

    func testMergeRejectsSegmentFromWrongTrack() {
        let system = makeTranscript(
            source: .system,
            segments: [
                makeSegment(
                    id: "wrong-source",
                    source: .microphone,
                    speaker: "Martin",
                    start: 0,
                    end: 1,
                    language: "sk",
                    text: "Test"
                ),
            ]
        )

        XCTAssertThrowsError(
            try TranscriptMerger().merge(
                sessionID: "session-4",
                title: "Test",
                systemTranscript: system,
                microphoneTranscript: nil,
                completedAt: completedAt
            )
        ) { error in
            XCTAssertEqual(
                error as? TranscriptMergeError,
                .segmentSourceMismatch(
                    segmentID: "wrong-source",
                    track: .system,
                    segment: .microphone
                )
            )
        }
    }

    func testMergesExistingSessionWhenPathIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MEETINGSCRIBE_SESSION_PATH"],
              !path.isEmpty else {
            throw XCTSkip("Set MEETINGSCRIBE_SESSION_PATH for a real-session merge test.")
        }

        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        let metadataData = try Data(
            contentsOf: directoryURL.appendingPathComponent("session.json")
        )
        let metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: metadataData
        )
        let system = try decodeTrack(
            at: directoryURL.appendingPathComponent(
                metadata.transcriptFiles?.systemTrack ?? "system-transcript.json"
            )
        )
        let microphoneURL = directoryURL.appendingPathComponent(
            metadata.transcriptFiles?.microphoneTrack ?? "microphone-transcript.json"
        )
        let microphone = FileManager.default.fileExists(atPath: microphoneURL.path)
            ? try decodeTrack(at: microphoneURL)
            : nil

        let merged = try TranscriptMerger().merge(
            sessionID: metadata.id,
            title: metadata.title,
            systemTranscript: system,
            microphoneTranscript: microphone,
            completedAt: completedAt
        )
        let roundTrip = try TranscriptJSONCoder.makeDecoder().decode(
            MergedTranscript.self,
            from: TranscriptJSONCoder.makeEncoder().encode(merged)
        )

        XCTAssertEqual(roundTrip, merged)
        XCTAssertFalse(merged.segments.contains { $0.text == "[BLANK_AUDIO]" })
        XCTAssertTrue(zip(merged.segments, merged.segments.dropFirst()).allSatisfy {
            $0.start <= $1.start
        })
    }

    private func makeTranscript(
        source: TranscriptSource,
        detectedLanguage: String = "en",
        segments: [TranscriptSegment]
    ) -> TrackTranscript {
        TrackTranscript(
            source: source,
            model: "ggml-test.bin",
            requestedLanguage: .automatic,
            detectedLanguage: detectedLanguage,
            completedAt: completedAt,
            segments: segments
        )
    }

    private func makeSegment(
        id: String,
        source: TranscriptSource,
        speaker: String,
        start: Double,
        end: Double,
        language: String,
        text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            source: source,
            speaker: speaker,
            start: start,
            end: end,
            language: language,
            text: text,
            confidence: nil
        )
    }

    private func decodeTrack(at url: URL) throws -> TrackTranscript {
        let data = try Data(contentsOf: url)
        return try TranscriptJSONCoder.makeDecoder().decode(TrackTranscript.self, from: data)
    }
}
