import Foundation
import XCTest
@testable import MeetingScribe

/// The delete moves a whole directory tree, so the tests are mostly about what
/// it refuses to touch. Nothing here reaches the real Trash: the move is a
/// recorded closure that relocates the item into a scratch folder.
final class SessionDeletionServiceTests: XCTestCase {
    private var root: URL!
    private var trash: URL!
    private var outputFolder: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeDeletion-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Recordings", isDirectory: true)
        trash = base.appendingPathComponent("Trash", isDirectory: true)
        outputFolder = base.appendingPathComponent("Vault", isDirectory: true)
        for directory in [root!, trash!, outputFolder!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        let base = root.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
        root = nil
        trash = nil
        outputFolder = nil
    }

    func testPlanReportsTheFolderAndTheNoteExportedOutsideIt() async throws {
        let markdownURL = outputFolder.appendingPathComponent("Standup.md")
        try Data(String(repeating: "m", count: 32).utf8).write(to: markdownURL)
        let directory = try writeCompletedSession(id: "standup", title: "Standup", markdownURL: markdownURL)
        try Data(String(repeating: "a", count: 4_096).utf8)
            .write(to: directory.appendingPathComponent("system-16k.wav"))

        let plan = try await makeService().plan(for: "standup")

        XCTAssertEqual(plan.sessionID, "standup")
        XCTAssertEqual(plan.title, "Standup")
        XCTAssertEqual(plan.directoryURL, directory.standardizedFileURL)
        XCTAssertGreaterThan(plan.directoryBytes, 4_000)
        XCTAssertTrue(plan.hasExternalMarkdown)
        XCTAssertEqual(plan.exportedMarkdownURL, markdownURL.standardizedFileURL)
        XCTAssertGreaterThan(plan.exportedMarkdownBytes, 0)
    }

    func testDeleteMovesTheWholeSessionFolderAndTheExportedNote() async throws {
        let markdownURL = outputFolder.appendingPathComponent("Retro.md")
        try Data("note".utf8).write(to: markdownURL)
        let directory = try writeCompletedSession(id: "retro", title: "Retro", markdownURL: markdownURL)
        try writeCompletedSession(
            id: "keep",
            title: "Keep",
            markdownURL: outputFolder.appendingPathComponent("Keep.md")
        )

        let service = makeService()
        let plan = try await service.plan(for: "retro")
        let report = try await service.delete(plan, includingExportedMarkdown: true)

        XCTAssertTrue(report.trashedMarkdown)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertGreaterThan(report.reclaimedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markdownURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("keep").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: trash.appendingPathComponent("retro").appendingPathComponent("transcript.json").path
            ),
            "The folder has to reach the Trash whole, so Finder can put it back."
        )
    }

    func testDeleteKeepsTheExportedNoteWhenTheUserOptedOut() async throws {
        let markdownURL = outputFolder.appendingPathComponent("Kept.md")
        try Data("note".utf8).write(to: markdownURL)
        let directory = try writeCompletedSession(id: "kept", title: "Kept", markdownURL: markdownURL)

        let service = makeService()
        let plan = try await service.plan(for: "kept")
        let report = try await service.delete(plan, includingExportedMarkdown: false)

        XCTAssertFalse(report.trashedMarkdown)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
    }

    func testANoteExportedIntoTheSessionFolderIsNotASeparateItem() async throws {
        let directory = root.appendingPathComponent("inline", isDirectory: true)
        let markdownURL = directory.appendingPathComponent("Inline.md")
        try writeCompletedSession(id: "inline", title: "Inline", markdownURL: markdownURL)
        try Data("note".utf8).write(to: markdownURL)

        let service = makeService()
        let plan = try await service.plan(for: "inline")
        XCTAssertFalse(plan.hasExternalMarkdown)

        let report = try await service.delete(plan, includingExportedMarkdown: true)

        XCTAssertFalse(report.trashedMarkdown)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(trashedItems.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAMissingNoteIsNotAFailure() async throws {
        let markdownURL = outputFolder.appendingPathComponent("Gone.md")
        try writeCompletedSession(id: "gone", title: "Gone", markdownURL: markdownURL)

        let service = makeService()
        let plan = try await service.plan(for: "gone")
        XCTAssertFalse(plan.hasExternalMarkdown)

        let report = try await service.delete(plan, includingExportedMarkdown: true)

        XCTAssertFalse(report.trashedMarkdown)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    /// `markdownPath` lives in editable JSON, so a path that no longer looks
    /// like the session's own note must not direct a delete.
    func testRefusesANotePathThatIsNotThePlainExportedNote() async throws {
        let directoryDisguisedAsANote = outputFolder
            .appendingPathComponent("Folder.md", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryDisguisedAsANote,
            withIntermediateDirectories: true
        )
        try writeCompletedSession(
            id: "disguised",
            title: "Disguised",
            markdownURL: directoryDisguisedAsANote
        )

        let renamed = outputFolder.appendingPathComponent("Renamed.md")
        try Data("note".utf8).write(to: renamed)
        var metadata = try metadata(id: "renamed", title: "Renamed", markdownURL: renamed)
        metadata.output?.markdownFileName = "Original.md"
        try write(metadata: metadata)

        let notMarkdown = outputFolder.appendingPathComponent("Export.txt")
        try Data("note".utf8).write(to: notMarkdown)
        try writeCompletedSession(id: "not-markdown", title: "Not Markdown", markdownURL: notMarkdown)

        let service = makeService()
        for id in ["disguised", "renamed", "not-markdown"] {
            let plan = try await service.plan(for: id)
            XCTAssertFalse(plan.hasExternalMarkdown, "\(id) offered a note it should not delete")
            _ = try await service.delete(plan, includingExportedMarkdown: true)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directoryDisguisedAsANote.path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notMarkdown.path))
    }

    func testRefusesAnIdentifierThatWouldEscapeTheRecordingsFolder() async throws {
        let outsider = root.deletingLastPathComponent()
            .appendingPathComponent("outsider", isDirectory: true)
        try FileManager.default.createDirectory(at: outsider, withIntermediateDirectories: true)

        let service = makeService()
        for id in ["../outsider", "..", "/tmp", ""] {
            await XCTAssertThrowsErrorAsync(try await service.plan(for: id))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path))
        XCTAssertTrue(trashedItems.isEmpty)
    }

    func testRefusesASymlinkedSessionDirectory() async throws {
        let outsider = root.deletingLastPathComponent()
            .appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: outsider, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: outsider
        )

        await XCTAssertThrowsErrorAsync(try await makeService().plan(for: "linked"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path))
        XCTAssertTrue(trashedItems.isEmpty)
    }

    func testRefusesAFolderAnotherLiveProcessIsRecordingInto() async throws {
        let directory = try writeCompletedSession(
            id: "live",
            title: "Live",
            markdownURL: outputFolder.appendingPathComponent("Live.md")
        )
        let ownership = RecordingOwnership(
            processID: 42,
            clock: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true },
            bootSessionUUID: { "boot" }
        )
        try ownership.claim(in: directory)

        let service = makeService(
            ownership: RecordingOwnership(
                processID: 43,
                clock: { Date(timeIntervalSince1970: 1_000) },
                isProcessAlive: { _ in true },
                bootSessionUUID: { "boot" }
            )
        )

        await XCTAssertThrowsErrorAsync(try await service.plan(for: "live")) { error in
            XCTAssertEqual(error as? SessionDeletionError, .sessionIsInUse("live"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTheNoteIsKeptAsAWarningWhenOnlyItsMoveFails() async throws {
        let markdownURL = outputFolder.appendingPathComponent("Stuck.md")
        try Data("note".utf8).write(to: markdownURL)
        let directory = try writeCompletedSession(id: "stuck", title: "Stuck", markdownURL: markdownURL)

        let service = SessionDeletionService(
            recordingsRoot: root,
            moveToTrash: { [trash] url in
                guard url.pathExtension != "md" else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(
                    at: url,
                    to: trash!.appendingPathComponent(url.lastPathComponent)
                )
            }
        )
        let plan = try await service.plan(for: "stuck")
        let report = try await service.delete(plan, includingExportedMarkdown: true)

        XCTAssertFalse(report.trashedMarkdown)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(try XCTUnwrap(report.warnings.first).contains(markdownURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
    }

    func testNothingIsMovedWhenTheSessionFolderCannotBeTrashed() async throws {
        let markdownURL = outputFolder.appendingPathComponent("Blocked.md")
        try Data("note".utf8).write(to: markdownURL)
        try writeCompletedSession(id: "blocked", title: "Blocked", markdownURL: markdownURL)

        let service = SessionDeletionService(
            recordingsRoot: root,
            moveToTrash: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let plan = try await service.plan(for: "blocked")

        await XCTAssertThrowsErrorAsync(
            try await service.delete(plan, includingExportedMarkdown: true)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
    }

    // MARK: - Fixtures

    private var trashedItems: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private func makeService(
        ownership: RecordingOwnership = RecordingOwnership()
    ) -> SessionDeletionService {
        SessionDeletionService(
            recordingsRoot: root,
            ownership: ownership,
            moveToTrash: { [trash] url in
                try FileManager.default.moveItem(
                    at: url,
                    to: trash!.appendingPathComponent(url.lastPathComponent)
                )
            }
        )
    }

    private func metadata(id: String, title: String, markdownURL: URL) throws -> SessionMetadata {
        let startedAt = Date(timeIntervalSince1970: 100)
        return SessionMetadata(
            id: id,
            title: title,
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "parakeet",
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(90),
                systemSegmentCount: 1,
                microphoneSegmentCount: 0,
                warnings: [],
                failureReason: nil
            ),
            output: SessionOutputMetadata(
                status: .completed,
                markdownFileName: markdownURL.lastPathComponent,
                markdownPath: markdownURL.path,
                exportedAt: startedAt.addingTimeInterval(90),
                failureReason: nil
            )
        )
    }

    @discardableResult
    private func writeCompletedSession(
        id: String,
        title: String,
        markdownURL: URL
    ) throws -> URL {
        try write(metadata: try metadata(id: id, title: title, markdownURL: markdownURL))
    }

    @discardableResult
    private func write(metadata: SessionMetadata) throws -> URL {
        let directory = root.appendingPathComponent(metadata.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SessionJSONCoder.makeEncoder().encode(metadata).write(
            to: directory.appendingPathComponent("session.json")
        )
        try Data("transcript".utf8).write(to: directory.appendingPathComponent("transcript.json"))
        return directory.standardizedFileURL
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
