import Foundation
import XCTest
@testable import MeetingScribe

final class ProcessingFileServiceTests: XCTestCase {
    func testConvenienceExportDelegatesToCanonicalRequirementOnce() async throws {
        let service = CanonicalProcessingFileService()
        let metadata = SessionMetadata(
            id: "canonical",
            title: "Canonical",
            status: .recorded,
            createdAt: Date()
        )
        let transcript = MergedTranscript(
            sessionID: metadata.id,
            title: metadata.title,
            completedAt: Date(),
            tracks: [],
            segments: []
        )

        _ = try await service.exportMarkdown(
            session: metadata,
            transcript: transcript,
            analysis: nil,
            to: FileManager.default.temporaryDirectory
        )

        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)
    }

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
        let analysis = AIAnalysisArtifact(
            markdown: "## Vlastná analýza\n\nBackground I/O summary",
            tool: .codex,
            model: nil,
            toolVersion: "codex-test",
            prompt: "Test prompt"
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

    func testExportMarkdownPassesNotesToRenderer() async throws {
        let metadata = SessionMetadata(
            id: "processing-notes",
            title: "Processing notes",
            status: .recorded,
            createdAt: Date(),
            outputLanguage: .english
        )
        let transcript = MergedTranscript(
            sessionID: metadata.id,
            title: metadata.title,
            completedAt: Date(),
            tracks: [],
            segments: []
        )
        let service = ProcessingFileService()

        let export = try await service.exportMarkdown(
            session: metadata,
            transcript: transcript,
            utteranceTranscript: nil,
            analysis: nil,
            notes: "First note",
            to: FileManager.default.temporaryDirectory
        )

        let markdown = try String(contentsOf: export.fileURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains(MarkdownRenderer.userNotesStartMarker))
        XCTAssertTrue(markdown.contains("## Notes\nFirst note"))
        XCTAssertTrue(markdown.contains(MarkdownRenderer.userNotesEndMarker))
    }
}

private actor CanonicalProcessingFileService: ProcessingFileServicing {
    private var exportCalls = 0

    func loadRecoveredArtifacts(from session: RecordingSession) async -> RecoveredProcessingArtifacts? {
        nil
    }

    func loadUserNotes(from session: RecordingSession) async -> String? { nil }

    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws {}

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        analysis: AIAnalysisArtifact?,
        notes: String?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        exportCalls += 1
        return MarkdownExportResult(
            fileURL: directoryURL.appendingPathComponent("canonical.md"),
            exportedAt: Date()
        )
    }

    func callCount() -> Int { exportCalls }
}
