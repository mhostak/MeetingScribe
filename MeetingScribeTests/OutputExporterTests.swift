import Foundation
import XCTest
@testable import MeetingScribe

final class OutputExporterTests: XCTestCase {
    private var temporaryRoot: URL!
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let startedAt = ISO8601DateFormatter().date(from: "2026-07-10T10:30:00Z")!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeOutput-\(UUID().uuidString)", isDirectory: true)
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

    func testFilenameSanitizerProducesSafeFallbackAndExpectedPattern() {
        let sanitizer = FilenameSanitizer(timeZone: utc)

        XCTAssertEqual(
            sanitizer.markdownFileName(title: "  SOFA: weekly / API?  ", startedAt: startedAt),
            "2026-07-10 10-30 - SOFA weekly API.md"
        )
        XCTAssertEqual(sanitizer.sanitizedTitle(" /:*? "), "Meeting")
        XCTAssertEqual(
            sanitizer.markdownFileName(
                title: "SOFA weekly",
                sessionID: "recording:1",
                startedAt: startedAt,
                template: "{title} - {id} - {date}"
            ),
            "SOFA weekly - recording 1 - 2026-07-10.md"
        )
    }

    func testExporterWritesUTF8MarkdownWithoutOverwritingExistingFile() throws {
        let exportedAt = ISO8601DateFormatter().date(from: "2026-07-10T11:00:00Z")!
        let exporter = OutputExporter(
            renderer: MarkdownRenderer(timeZone: utc),
            filenameSanitizer: FilenameSanitizer(timeZone: utc),
            now: { exportedAt }
        )
        let session = makeSession()
        let transcript = makeTranscript()

        let first = try exporter.export(
            session: session,
            transcript: transcript,
            to: temporaryRoot
        )
        let second = try exporter.export(
            session: session,
            transcript: transcript,
            to: temporaryRoot
        )

        XCTAssertEqual(first.fileURL.lastPathComponent, "2026-07-10 10-30 - SOFA weekly.md")
        XCTAssertEqual(second.fileURL.lastPathComponent, "2026-07-10 10-30 - SOFA weekly (2).md")
        XCTAssertEqual(first.exportedAt, exportedAt)
        XCTAssertTrue(try String(contentsOf: first.fileURL, encoding: .utf8).contains("Dobrý deň."))
    }

    func testExporterRejectsMissingDestination() {
        let missing = temporaryRoot.appendingPathComponent("missing", isDirectory: true)

        XCTAssertThrowsError(
            try OutputExporter().export(
                session: makeSession(),
                transcript: makeTranscript(),
                to: missing
            )
        ) { error in
            XCTAssertEqual(
                error as? OutputExportError,
                .destinationIsNotDirectory(path: missing.path)
            )
        }
    }

    func testExporterUsesSessionFileNameTemplate() throws {
        var session = makeSession()
        session.outputFileNameTemplate = "{title} ({id})"

        let result = try OutputExporter(
            filenameSanitizer: FilenameSanitizer(timeZone: utc)
        ).export(
            session: session,
            transcript: makeTranscript(),
            to: temporaryRoot
        )

        XCTAssertEqual(result.fileURL.lastPathComponent, "SOFA weekly (recording-1).md")
    }

    private func makeSession() -> SessionMetadata {
        SessionMetadata(
            id: "recording-1",
            title: "SOFA weekly",
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30 * 60)
        )
    }

    private func makeTranscript() -> MergedTranscript {
        MergedTranscript(
            sessionID: "recording-1",
            title: "SOFA weekly",
            completedAt: startedAt.addingTimeInterval(30 * 60),
            tracks: [],
            segments: [
                TranscriptSegment(
                    id: "segment-000000",
                    source: .microphone,
                    speaker: "Martin",
                    start: 1,
                    end: 2,
                    language: "sk",
                    text: "Dobrý deň.",
                    confidence: nil
                ),
            ]
        )
    }
}
