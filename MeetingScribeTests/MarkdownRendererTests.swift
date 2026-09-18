import Foundation
import XCTest
@testable import MeetingScribe

final class MarkdownRendererTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let startedAt = ISO8601DateFormatter().date(from: "2026-07-10T10:30:00Z")!
    private let endedAt = ISO8601DateFormatter().date(from: "2026-07-10T11:24:00Z")!

    func testNotesAreRenderedBetweenMarkersWithLocalizedHeading() {
        let expectedHeadings = [
            (OutputLanguage.slovak, "Poznámky"),
            (OutputLanguage.czech, "Poznámky"),
            (OutputLanguage.english, "Notes"),
        ]

        for (language, heading) in expectedHeadings {
            let session = SessionMetadata(
                id: "recording-1",
                title: "Notes heading",
                status: .recorded,
                createdAt: startedAt,
                startedAt: startedAt,
                endedAt: endedAt,
                outputLanguage: language
            )

            let markdown = MarkdownRenderer(timeZone: utc).render(
                session: session,
                transcript: makeTranscript(segments: []),
                notes: "First note"
            )

            XCTAssertTrue(markdown.contains(
                "\(MarkdownRenderer.userNotesStartMarker)\n## \(heading)\nFirst note\n"
                    + MarkdownRenderer.userNotesEndMarker
            ))
            XCTAssertTrue(markdown.contains("notes: true"))
        }
    }

    func testWithoutNotesNoNotesSectionOrFrontmatterKeyIsRendered() {
        let session = SessionMetadata(
            id: "recording-1",
            title: "No notes",
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: endedAt
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: makeTranscript(segments: []),
            notes: nil
        )

        XCTAssertFalse(markdown.contains(MarkdownRenderer.userNotesStartMarker))
        XCTAssertFalse(markdown.contains(MarkdownRenderer.userNotesEndMarker))
        XCTAssertFalse(markdown.contains("## Poznámky"))
        XCTAssertFalse(markdown.contains("notes: true"))
    }

    func testRenderCreatesFrontmatterSectionsAndTimestampedTranscript() {
        let session = SessionMetadata(
            id: "recording-1",
            title: "Project Alpha weekly",
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
                speaker: "Speaker B",
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
        XCTAssertTrue(markdown.contains("title: \"Project Alpha weekly\""))
        XCTAssertTrue(markdown.contains("date: 2026-07-10"))
        XCTAssertTrue(markdown.contains("started: 10:30"))
        XCTAssertTrue(markdown.contains("ended: 11:24"))
        XCTAssertTrue(markdown.contains("duration_minutes: 54"))
        XCTAssertTrue(markdown.contains("  - \"cs\"\n  - \"sk\""))
        XCTAssertTrue(
            markdown.contains("  - \"Vzdialení účastníci\"\n  - \"Účastníci na mieste\"")
        )
        XCTAssertTrue(markdown.contains("<!-- meetingscribe:ai-analysis:start -->"))
        XCTAssertTrue(markdown.contains("<!-- AI analýza zatiaľ nebola vytvorená. -->"))
        XCTAssertTrue(markdown.contains("<!-- meetingscribe:ai-analysis:end -->"))
        XCTAssertTrue(markdown.contains("## Prepis"))
        XCTAssertTrue(
            markdown.contains("### 00:00:04 — Vzdialení účastníci *(prekrytie reči)*")
        )
        XCTAssertTrue(
            markdown.contains("### 00:00:10 — Účastníci na mieste *(prekrytie reči)*")
        )
        XCTAssertTrue(markdown.hasSuffix("Začnime dnešným stavom.\n"))
    }

    func testRenderUsesContinuousUtterancesWhenValidArtifactIsProvided() throws {
        let session = SessionMetadata(
            id: "recording-1",
            title: "Project Alpha weekly",
            status: .recorded,
            createdAt: startedAt
        )
        let transcript = makeTranscript(segments: [
            segment(
                id: "segment-000000",
                source: .system,
                speaker: "Other",
                start: 1,
                end: 2,
                language: "sk",
                text: "Toto je prvá časť."
            ),
            segment(
                id: "segment-000001",
                source: .system,
                speaker: "Other",
                start: 2.1,
                end: 3,
                language: "sk",
                text: "A toto jej pokračovanie."
            ),
        ])
        let utterances = try UtteranceArtifactStore().makeArtifact(transcript: transcript)

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: transcript,
            utteranceTranscript: utterances
        )

        XCTAssertTrue(markdown.contains("Toto je prvá časť. A toto jej pokračovanie."))
        XCTAssertEqual(markdown.components(separatedBy: "### 00:00:").count - 1, 1)
    }

    func testRenderGroupsConsecutiveSegmentsByAudioSourceAndIgnoresResolvedSpeakers() {
        let session = SessionMetadata(
            id: "recording-1",
            title: "Source-based output",
            status: .recorded,
            createdAt: startedAt
        )
        let transcript = makeTranscript(segments: [
            segment(
                id: "mic-0",
                source: .microphone,
                speaker: "Person A",
                start: 0,
                end: 1,
                language: "sk",
                text: "Prvá časť."
            ),
            segment(
                id: "mic-1",
                source: .microphone,
                speaker: "Person B",
                start: 1.1,
                end: 2,
                language: "sk",
                text: "Pokračovanie."
            ),
            segment(
                id: "system-0",
                source: .system,
                speaker: "Remote person",
                start: 2.1,
                end: 3,
                language: "cs",
                text: "Vzdialená odpoveď."
            ),
            segment(
                id: "mic-2",
                source: .microphone,
                speaker: "Person A",
                start: 3.1,
                end: 4,
                language: "sk",
                text: "Návrat k mikrofónu."
            ),
            segment(
                id: "mic-3",
                source: .microphone,
                speaker: "Person B",
                start: 4.1,
                end: 5,
                language: "sk",
                text: "Stále ten istý zdroj."
            ),
        ])
        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: transcript
        )

        XCTAssertTrue(markdown.contains("Prvá časť. Pokračovanie."))
        XCTAssertTrue(markdown.contains("Návrat k mikrofónu. Stále ten istý zdroj."))
        XCTAssertTrue(markdown.contains("Vzdialená odpoveď."))
        XCTAssertFalse(markdown.contains("Person A"))
        XCTAssertFalse(markdown.contains("Person B"))
        XCTAssertFalse(markdown.contains("Remote person"))
        XCTAssertEqual(markdown.components(separatedBy: "\n### ").count - 1, 3)
    }

    func testRenderEscapesYAMLAndHandlesEmptyTranscript() {
        let session = SessionMetadata(
            id: "id:1",
            title: "Line \"one\"\nLine\ttwo",
            status: .recorded,
            createdAt: startedAt
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: makeTranscript(segments: [])
        )

        XCTAssertTrue(markdown.contains("title: \"Line \\\"one\\\"\\nLine\\u0009two\""))
        XCTAssertTrue(markdown.contains("languages:"))
        XCTAssertTrue(markdown.contains("participants: []"))
        XCTAssertTrue(markdown.contains("_Prepis neobsahuje žiadne rozpoznané segmenty._"))
        XCTAssertFalse(markdown.contains("# Line \"one\"\nLine two"))
    }

    func testRenderUsesOnlyConfirmedCalendarParticipantsWhenSnapshotExists() {
        let session = SessionMetadata(
            id: "calendar-recording",
            title: "Planning",
            status: .recorded,
            createdAt: startedAt,
            calendarEvent: CalendarEventSnapshot(
                source: .appleCalendar,
                title: "Planning",
                startsAt: startedAt,
                endsAt: endedAt,
                selectedAt: startedAt,
                participants: [
                    ConfirmedParticipant(displayName: "Participant One"),
                    ConfirmedParticipant(displayName: "Participant Two"),
                ],
                shareParticipantNamesWithAnalysis: false,
                eventDescription: "Discuss roadmap.\nConfirm launch date."
            )
        )
        let transcript = makeTranscript(segments: [
            segment(
                id: "segment-000000",
                source: .system,
                speaker: "Other",
                start: 0,
                end: 2,
                language: "sk",
                text: "Dobrý deň."
            ),
        ])

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: transcript
        )

        XCTAssertTrue(markdown.contains("  - \"Participant One\"\n  - \"Participant Two\""))
        XCTAssertTrue(
            markdown.contains(
                "calendar_description: \"Discuss roadmap.\\nConfirm launch date.\""
            )
        )
        XCTAssertFalse(markdown.contains("participants:\n  - \"Other\""))
    }

    func testRenderInsertsFreeformAnalysisBetweenReservedMarkers() {
        let session = SessionMetadata(
            id: "recording-1",
            title: "Project Alpha weekly",
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let analysis = AIAnalysisArtifact(
            markdown: """
            ## Executive brief

            Tím sa dohodol na ďalšom postupe.

            | Úloha | Vlastník |
            | --- | --- |
            | Pripraviť návrh | neurčené |
            """,
            tool: .claude,
            model: "sonnet",
            toolVersion: "Claude Code test",
            prompt: "Create a custom table",
            generatedAt: startedAt
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: makeTranscript(segments: []),
            analysis: analysis
        )

        XCTAssertTrue(markdown.contains("Tím sa dohodol na ďalšom postupe."))
        XCTAssertTrue(markdown.contains("<!-- meetingscribe:ai-analysis:start -->"))
        XCTAssertTrue(markdown.contains("<!-- meetingscribe:ai-analysis:end -->"))
        XCTAssertTrue(markdown.contains("| Pripraviť návrh | neurčené |"))
        XCTAssertTrue(markdown.contains(#""ai analysis": "2026-07-10 – claude – sonnet""#))
        XCTAssertFalse(markdown.contains("<!-- AI analýza zatiaľ nebola vytvorená. -->"))
    }

    func testOverlapDetectorHandlesNestedSameSourceIntervalsAndTouchingBoundaries() {
        let segments = [
            segment(
                id: "system-long",
                source: .system,
                speaker: "Other",
                start: 0,
                end: 10,
                language: "sk",
                text: "Long"
            ),
            segment(
                id: "system-nested",
                source: .system,
                speaker: "Other",
                start: 2,
                end: 4,
                language: "sk",
                text: "Nested"
            ),
            segment(
                id: "microphone-overlap",
                source: .microphone,
                speaker: "Speaker B",
                start: 3,
                end: 3.5,
                language: "sk",
                text: "Overlap"
            ),
            segment(
                id: "microphone-boundary",
                source: .microphone,
                speaker: "Speaker B",
                start: 10,
                end: 12,
                language: "sk",
                text: "Boundary"
            ),
        ]

        XCTAssertEqual(
            TranscriptOverlapDetector().overlappingIndices(in: segments),
            Set([0, 1, 2])
        )
    }

    func testOverlapDetectorScalesToLargeTranscript() {
        let segments = (0..<50_000).map { index in
            let block = Double(index / 2) * 4
            let isSystem = index.isMultiple(of: 2)
            return segment(
                id: "segment-\(index)",
                source: isSystem ? .system : .microphone,
                speaker: isSystem ? "Other" : "Speaker B",
                start: block + (isSystem ? 0 : 2),
                end: block + (isSystem ? 1 : 3),
                language: "sk",
                text: "Text"
            )
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let overlaps = TranscriptOverlapDetector().overlappingIndices(in: segments)

        XCTAssertTrue(overlaps.isEmpty)
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(2))
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

        XCTAssertTrue(markdown.contains("## Prepis"))
        XCTAssertFalse(markdown.contains("[BLANK_AUDIO]"))
        XCTAssertTrue(merged.segments.allSatisfy { markdown.contains($0.text) })
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), markdown)
    }

    func testExportsContinuousUtterancePreviewForExistingSessionWhenPathsAreProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sessionPath = environment["MEETINGSCRIBE_SESSION_PATH"],
              !sessionPath.isEmpty,
              let outputPath = environment["MEETINGSCRIBE_MARKDOWN_OUTPUT_DIRECTORY"],
              !outputPath.isEmpty else {
            throw XCTSkip(
                "Set MEETINGSCRIBE_SESSION_PATH and MEETINGSCRIBE_MARKDOWN_OUTPUT_DIRECTORY "
                    + "for a real continuous-utterance export test."
            )
        }

        let sessionDirectory = URL(fileURLWithPath: sessionPath, isDirectory: true)
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        let metadata = try decode(
            SessionMetadata.self,
            at: sessionDirectory.appendingPathComponent("session.json"),
            decoder: SessionJSONCoder.makeDecoder()
        )
        let transcript = try decode(
            MergedTranscript.self,
            at: sessionDirectory.appendingPathComponent("transcript.json"),
            decoder: TranscriptJSONCoder.makeDecoder()
        )
        let utteranceTranscript = try UtteranceArtifactStore().makeArtifact(
            transcript: transcript
        )

        let mappedSegmentIDs = utteranceTranscript.utterances
            .flatMap(\.sourceSegmentIDs)
            .sorted()
        XCTAssertEqual(mappedSegmentIDs, transcript.segments.map(\.id).sorted())
        XCTAssertLessThan(utteranceTranscript.utterances.count, transcript.segments.count)
        XCTAssertNil(utteranceTranscript.turnDetectionEngine)
        XCTAssertNil(utteranceTranscript.turnDetectionModel)

        let result = try OutputExporter().export(
            session: metadata,
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            to: outputDirectory
        )
        let markdown = try String(contentsOf: result.fileURL, encoding: .utf8)
        XCTAssertTrue(
            ["## Prepis", "## Přepis", "## Transcript"].contains {
                markdown.contains($0)
            }
        )
        XCTAssertEqual(
            markdown.components(separatedBy: "\n### ").count - 1,
            utteranceTranscript.utterances.count
        )
        for segment in transcript.segments {
            XCTAssertTrue(
                markdown.contains(
                    segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                "Export is missing source segment \(segment.id)."
            )
        }
        XCTAssertNotEqual(result.fileURL.path, metadata.output?.markdownPath)

        print("MEETINGSCRIBE_S0_OUTPUT=\(result.fileURL.path)")
        print("MEETINGSCRIBE_S0_SEGMENTS=\(transcript.segments.count)")
        print("MEETINGSCRIBE_S0_UTTERANCES=\(utteranceTranscript.utterances.count)")
    }

    func testRenderUsesSelectedCzechOutputLanguage() {
        let session = SessionMetadata(
            id: "recording-cs",
            title: "Porada",
            status: .recorded,
            createdAt: startedAt,
            outputLanguage: .czech
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: makeTranscript(segments: [])
        )

        XCTAssertTrue(markdown.contains("<!-- AI analýza zatím nebyla vytvořena. -->"))
        XCTAssertTrue(markdown.contains("## Přepis"))
        XCTAssertTrue(markdown.contains("Přepis neobsahuje žádné rozpoznané segmenty."))
    }

    func testRenderUsesSelectedEnglishOutputLanguage() {
        let session = SessionMetadata(
            id: "recording-en",
            title: "Planning",
            status: .recorded,
            createdAt: startedAt,
            outputLanguage: .english
        )

        let markdown = MarkdownRenderer(timeZone: utc).render(
            session: session,
            transcript: makeTranscript(segments: [])
        )

        XCTAssertTrue(markdown.contains("<!-- AI analysis has not been created. -->"))
        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertTrue(markdown.contains("The transcript contains no recognized segments."))
    }

    func testAnalysisUpdaterReplacesOnlyAnalysisBlockAndFrontmatter() throws {
        let original = """
        ---
        type: meeting
        title: "Planning"
        ---

        # Planning

        Manual note outside the generated block.

        <!-- meetingscribe:ai-analysis:start -->
        <!-- AI analysis has not been created. -->
        <!-- meetingscribe:ai-analysis:end -->

        ## Transcript

        Original transcript text.
        """
        let analysis = AIAnalysisArtifact(
            markdown: "## Summary\n\nUpdated analysis.",
            tool: .codex,
            model: "gpt-test",
            toolVersion: "codex-test",
            prompt: "Test prompt",
            generatedAt: startedAt
        )

        let updated = try MarkdownAnalysisUpdater(timeZone: utc).updating(
            original,
            with: analysis
        )

        XCTAssertTrue(updated.contains(#""ai analysis": "2026-07-10 – codex – gpt-test""#))
        XCTAssertTrue(updated.contains("## Summary\n\nUpdated analysis."))
        XCTAssertFalse(updated.contains("AI analysis has not been created"))
        XCTAssertTrue(updated.contains("Manual note outside the generated block."))
        XCTAssertTrue(updated.contains("Original transcript text."))
        XCTAssertEqual(
            updated.components(separatedBy: MarkdownRenderer.analysisStartMarker).count - 1,
            1
        )
    }

    private func makeTranscript(segments: [TranscriptSegment]) -> MergedTranscript {
        MergedTranscript(
            sessionID: "recording-1",
            title: "Project Alpha weekly",
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
