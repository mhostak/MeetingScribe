import Foundation
import XCTest
@testable import MeetingScribe

final class MarkdownRendererTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let startedAt = ISO8601DateFormatter().date(from: "2026-07-10T10:30:00Z")!
    private let endedAt = ISO8601DateFormatter().date(from: "2026-07-10T11:24:00Z")!

    func testRenderCreatesFrontmatterSectionsAndTimestampedTranscript() {
        let session = SessionMetadata(
            id: "recording-1",
            title: "SOFA weekly",
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let transcript = makeTranscript(segments: [
            segment(
                id: "segment-000000",
                source: .system,
                speaker: "Other",
                start: 4,
                end: 12,
                language: "cs",
                text: "Máme dokončenou první část."
            ),
            segment(
                id: "segment-000001",
                source: .microphone,
                speaker: "Martin",
                start: 10,
                end: 15,
                language: "sk",
                text: "Začnime dnešným stavom."
            ),
        ])

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: transcript
        )

        XCTAssertTrue(markdown.hasPrefix("---\ntype: meeting\n"))
        XCTAssertTrue(markdown.contains("title: \"SOFA weekly\""))
        XCTAssertTrue(markdown.contains("date: 2026-07-10"))
        XCTAssertTrue(markdown.contains("started: 10:30"))
        XCTAssertTrue(markdown.contains("ended: 11:24"))
        XCTAssertTrue(markdown.contains("duration_minutes: 54"))
        XCTAssertTrue(markdown.contains("  - \"cs\"\n  - \"sk\""))
        XCTAssertTrue(markdown.contains("  - \"Other\"\n  - \"Martin\""))
        XCTAssertTrue(markdown.contains("## Súhrn"))
        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertTrue(markdown.contains("### 00:00:04 — Other *(prekrytie reči)*"))
        XCTAssertTrue(markdown.contains("### 00:00:10 — Martin *(prekrytie reči)*"))
        XCTAssertTrue(markdown.hasSuffix("Začnime dnešným stavom.\n"))
    }

    func testRenderEscapesYAMLAndHandlesEmptyTranscript() {
        let session = SessionMetadata(
            id: "id:1",
            title: "Line \"one\"\nLine two",
            status: .recorded,
            createdAt: startedAt
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: makeTranscript(segments: [])
        )

        XCTAssertTrue(markdown.contains("title: \"Line \\\"one\\\"\\nLine two\""))
        XCTAssertTrue(markdown.contains("languages:"))
        XCTAssertTrue(markdown.contains("participants: []"))
        XCTAssertTrue(markdown.contains("_Transcript neobsahuje žiadne rozpoznané segmenty._"))
        XCTAssertFalse(markdown.contains("# Line \"one\"\nLine two"))
    }

    func testRenderFillsAnalysisSectionsWithEvidenceAndUnknownTaskFields() {
        let session = SessionMetadata(
            id: "recording-1",
            title: "SOFA weekly",
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let analysis = MeetingAnalysis(
            summary: "Tím sa dohodol na ďalšom postupe.",
            decisions: [
                AnalysisReference(
                    text: "Použije sa nové API.",
                    timestampSeconds: 12,
                    segmentID: "segment-000001"
                ),
            ],
            actionItems: [
                AnalysisActionItem(
                    text: "Pripraviť návrh.",
                    owner: nil,
                    dueDate: nil,
                    timestampSeconds: 18,
                    segmentID: "segment-000002"
                ),
            ],
            openQuestions: [],
            risksAndBlockers: [],
            nextMeetingTopics: [
                AnalysisReference(
                    text: "Stav implementácie",
                    timestampSeconds: nil,
                    segmentID: nil
                ),
            ]
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: makeTranscript(segments: []),
            analysis: analysis
        )

        XCTAssertTrue(markdown.contains("Tím sa dohodol na ďalšom postupe."))
        XCTAssertTrue(markdown.contains("- Použije sa nové API. — 00:00:12 · `segment-000001`"))
        XCTAssertTrue(
            markdown.contains(
                "- [ ] Neurčené — Pripraviť návrh. — termín: neurčený — 00:00:18 · `segment-000002`"
            )
        )
        XCTAssertTrue(markdown.contains("## Témy na ďalší meeting\n\n- Stav implementácie"))
        XCTAssertFalse(markdown.contains("<!-- AI analýza zatiaľ nebola vytvorená. -->"))
    }

    func testRendersExistingSessionWhenPathIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MEETINGSCRIBE_SESSION_PATH"],
              !path.isEmpty else {
            throw XCTSkip("Set MEETINGSCRIBE_SESSION_PATH for a real Markdown integration test.")
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let metadata = try decode(
            SessionMetadata.self,
            at: directory.appendingPathComponent("session.json"),
            decoder: SessionJSONCoder.makeDecoder()
        )
        let system = try decode(
            TrackTranscript.self,
            at: directory.appendingPathComponent("system-transcript.json"),
            decoder: TranscriptJSONCoder.makeDecoder()
        )
        let microphoneURL = directory.appendingPathComponent("microphone-transcript.json")
        let microphone = FileManager.default.fileExists(atPath: microphoneURL.path)
            ? try decode(
                TrackTranscript.self,
                at: microphoneURL,
                decoder: TranscriptJSONCoder.makeDecoder()
            )
            : nil
        let merged = try TranscriptMerger().merge(
            sessionID: metadata.id,
            title: metadata.title,
            systemTranscript: system,
            microphoneTranscript: microphone,
            completedAt: endedAt
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: metadata,
            transcript: merged
        )

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeRealMarkdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let exportDate = endedAt
        let result = try OutputExporter(
            renderer: MarkdownRenderer(timeZone: utc),
            filenameSanitizer: FilenameSanitizer(timeZone: utc),
            now: { exportDate }
        ).export(
            session: metadata,
            transcript: merged,
            to: outputDirectory
        )

        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertFalse(markdown.contains("[BLANK_AUDIO]"))
        XCTAssertTrue(merged.segments.allSatisfy { markdown.contains($0.text) })
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), markdown)
    }

    private func makeTranscript(segments: [TranscriptSegment]) -> MergedTranscript {
        MergedTranscript(
            sessionID: "recording-1",
            title: "SOFA weekly",
            completedAt: endedAt,
            tracks: [
                MergedTranscriptTrack(
                    source: .system,
                    model: "ggml-test.bin",
                    requestedLanguage: .automatic,
                    detectedLanguage: "cs",
                    segmentCount: segments.filter { $0.source == .system }.count
                ),
            ],
            segments: segments
        )
    }

    private func segment(
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

    private func decode<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        decoder: JSONDecoder
    ) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }
}
