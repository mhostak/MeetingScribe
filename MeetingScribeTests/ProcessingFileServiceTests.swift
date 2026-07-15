import Foundation
import XCTest
@testable import MeetingScribe

final class ProcessingFileServiceTests: XCTestCase {
    func testPersistsAndLoadsRecoveryArtifactsThenExportsMarkdown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeProcessingIO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = SessionMetadata(
            id: "processing-io",
            title: "Processing I/O",
            status: .recording,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = RecordingSession(metadata: metadata, directoryURL: root)
        let transcript = MergedTranscript(
            sessionID: metadata.id,
            title: metadata.title,
            completedAt: Date(timeIntervalSince1970: 1_700_000_010),
            tracks: [],
            segments: [
                TranscriptSegment(
                    id: "segment-000000",
                    source: .system,
                    speaker: "Other",
                    start: 0,
                    end: 1,
                    language: "sk",
                    text: "Background I/O transcript",
                    confidence: nil
                ),
            ]
        )
        let analysis = MeetingAnalysis(
            summary: "Background I/O summary",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risksAndBlockers: [],
            nextMeetingTopics: []
        )
        try TranscriptJSONCoder.makeEncoder().encode(transcript)
            .write(to: session.mergedTranscriptURL, options: .atomic)
        let service = ProcessingFileService()

        try await service.persistAnalysis(analysis, to: session.analysisURL)
        let loaded = await service.loadRecoveredArtifacts(from: session)
        let recovered = try XCTUnwrap(loaded)
        let export = try await service.exportMarkdown(
            session: metadata,
            transcript: recovered.transcript,
            analysis: recovered.analysis,
            to: root
        )

        XCTAssertEqual(recovered.transcript, transcript)
        XCTAssertEqual(recovered.utteranceTranscript?.utterances.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.utteranceTranscriptURL.path))
        XCTAssertEqual(recovered.analysis, analysis)
        let markdown = try String(contentsOf: export.fileURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Background I/O transcript"))
        XCTAssertTrue(markdown.contains("Background I/O summary"))
    }
}
