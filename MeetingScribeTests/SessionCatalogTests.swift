import Foundation
import XCTest
@testable import MeetingScribe

final class SessionCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeCatalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testLoadsSessionsChronologicallyAndDetectsArtifacts() async throws {
        let laterMarkdown = root.appendingPathComponent("later.md")
        let earlierMarkdown = root.appendingPathComponent("earlier.md")
        try Data("later".utf8).write(to: laterMarkdown)
        try Data("earlier".utf8).write(to: earlierMarkdown)

        try writeCompletedSession(
            id: "later",
            title: "Later meeting",
            startedAt: Date(timeIntervalSince1970: 200),
            markdownURL: laterMarkdown
        )
        try writeCompletedSession(
            id: "earlier",
            title: "Earlier meeting",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: earlierMarkdown
        )

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()

        XCTAssertEqual(snapshot.entries.map(\.session.metadata.title), ["Earlier meeting", "Later meeting"])
        XCTAssertTrue(snapshot.issues.isEmpty)
        for entry in snapshot.entries {
            XCTAssertEqual(entry.status, .completed)
            XCTAssertTrue(entry.audio.isAvailable)
            XCTAssertTrue(entry.transcript.isAvailable)
            XCTAssertTrue(entry.markdown.isAvailable)
            XCTAssertEqual(entry.duration, 90)
        }
    }

    func testKeepsSessionWhenExpectedMarkdownWasMovedOrDeleted() async throws {
        let missingMarkdown = root.appendingPathComponent("missing.md")
        try writeCompletedSession(
            id: "missing-markdown",
            title: "Missing Markdown",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: missingMarkdown
        )

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()
        let entry = try XCTUnwrap(snapshot.entries.first)

        XCTAssertEqual(entry.status, .incomplete)
        XCTAssertEqual(entry.message, "The exported Markdown file is missing or its location is unavailable.")
        XCTAssertEqual(entry.markdown, .missing(missingMarkdown))
        XCTAssertTrue(entry.audio.isAvailable)
        XCTAssertTrue(entry.transcript.isAvailable)
    }

    func testReportsUnreadableAndMissingManifestsWithoutDroppingValidSessions() async throws {
        let validMarkdown = root.appendingPathComponent("valid.md")
        try Data("valid".utf8).write(to: validMarkdown)
        try writeCompletedSession(
            id: "valid",
            title: "Valid",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: validMarkdown
        )

        let unreadable = root.appendingPathComponent("unreadable", isDirectory: true)
        let withoutManifest = root.appendingPathComponent("without-manifest", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: withoutManifest, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: unreadable.appendingPathComponent("session.json"))

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()

        XCTAssertEqual(snapshot.entries.map(\.id), ["valid"])
        XCTAssertEqual(snapshot.issues.map(\.directoryName), ["unreadable", "without-manifest"])
    }

    func testClosedRecoveryIssuesStayDismissedInCatalog() async throws {
        let unreadable = root.appendingPathComponent("unreadable", isDirectory: true)
        let withoutManifest = root.appendingPathComponent("without-manifest", isDirectory: true)
        for directory in [unreadable, withoutManifest] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("closed".utf8).write(
                to: directory.appendingPathComponent(
                    SessionRecoveryScanner.closedIssueMarkerFileName
                )
            )
        }
        try Data("not json".utf8).write(to: unreadable.appendingPathComponent("session.json"))

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()

        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testClassifiesStaleRecordingManifestAsInterrupted() async throws {
        let metadata = SessionMetadata(
            id: "interrupted",
            title: "Interrupted",
            status: .recording,
            createdAt: Date(timeIntervalSince1970: 100),
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try write(metadata: metadata)

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()
        let entry = try XCTUnwrap(snapshot.entries.first)

        XCTAssertEqual(entry.status, .interrupted)
        XCTAssertEqual(entry.audio, .notProduced)
        XCTAssertEqual(entry.transcript, .notProduced)
        XCTAssertEqual(entry.markdown, .notProduced)
    }

    func testDetectsPersistedWorkingAudioWhenLegacySourceIsMissing() async throws {
        let metadata = SessionMetadata(
            id: "legacy-working-audio",
            title: "Legacy working audio",
            status: .recorded,
            createdAt: Date(timeIntervalSince1970: 100),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 190),
            audioFiles: SessionAudioFiles(
                system: "system.caf",
                microphone: "microphone.caf",
                systemWorking: "system-working.wav",
                microphoneWorking: nil,
                mixed: "mixed.wav"
            )
        )
        let directory = try write(metadata: metadata)
        let workingAudioURL = directory.appendingPathComponent("system-working.wav")
        try Data([1]).write(to: workingAudioURL)

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()
        let entry = try XCTUnwrap(snapshot.entries.first)

        XCTAssertTrue(entry.audio.isAvailable)
        XCTAssertEqual(
            entry.audio.url?.resolvingSymlinksInPath(),
            workingAudioURL.resolvingSymlinksInPath()
        )
    }

    func testDetectsWhetherAnAIAnalysisArtifactExists() async throws {
        let markdownURL = root.appendingPathComponent("analysis.md")
        try Data("markdown".utf8).write(to: markdownURL)
        let directory = try writeCompletedSession(
            id: "with-analysis",
            title: "Analyzed",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: markdownURL
        )
        try Data("analysis".utf8).write(to: directory.appendingPathComponent("analysis.json"))

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()

        XCTAssertTrue(try XCTUnwrap(snapshot.entries.first).hasAnalysis)
    }

    func testDetectsWhetherNotesFileExists() async throws {
        let withNotes = try writeCompletedSession(
            id: "with-notes",
            title: "With notes",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: root.appendingPathComponent("with-notes.md")
        )
        let withEmptyNotes = try writeCompletedSession(
            id: "empty-notes",
            title: "Empty notes",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: root.appendingPathComponent("empty-notes.md")
        )
        try writeCompletedSession(
            id: "without-notes",
            title: "Without notes",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: root.appendingPathComponent("without-notes.md")
        )
        try Data("meeting notes".utf8).write(to: withNotes.appendingPathComponent("notes.md"))
        try Data().write(to: withEmptyNotes.appendingPathComponent("notes.md"))

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()
        let entries = snapshot.entries

        XCTAssertTrue(try XCTUnwrap(entries.first { $0.id == "with-notes" }).hasNotes)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.id == "empty-notes" }).hasNotes)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.id == "without-notes" }).hasNotes)
    }

    func testCatalogMarksIntentionallyPurgedAudioAsRemoved() async throws {
        let markdownURL = root.appendingPathComponent("purged.md")
        try Data("markdown".utf8).write(to: markdownURL)
        let directory = try writeCompletedSession(
            id: "purged",
            title: "Purged audio",
            startedAt: Date(timeIntervalSince1970: 100),
            markdownURL: markdownURL
        )
        let manifestURL = directory.appendingPathComponent("session.json")
        var metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: Data(contentsOf: manifestURL)
        )
        metadata.recordingAudioRetention = RecordingAudioRetentionMetadata(
            cleanupStatus: .purged,
            cleanupTrigger: .manual,
            cleanupStartedAt: Date(timeIntervalSince1970: 200),
            cleanupCompletedAt: Date(timeIntervalSince1970: 201),
            candidateFiles: ["system-16k.wav"],
            deletedFiles: ["system-16k.wav"],
            reclaimedBytes: 1
        )
        try SessionJSONCoder.makeEncoder().encode(metadata).write(to: manifestURL)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("system-16k.wav")
        )

        let snapshot = try await SessionCatalog(recordingsRoot: root).load()
        let entry = try XCTUnwrap(snapshot.entries.first)

        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.audio, .removed)
        XCTAssertFalse(entry.audio.isAvailable)
        XCTAssertTrue(entry.audio.isRemoved)
    }

    @discardableResult
    private func writeCompletedSession(
        id: String,
        title: String,
        startedAt: Date,
        markdownURL: URL
    ) throws -> URL {
        let metadata = SessionMetadata(
            id: id,
            title: title,
            status: .recorded,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            audioFinalization: AudioFinalizationMetadata(
                completedAt: startedAt.addingTimeInterval(90),
                timelineOrigin: 0,
                system: FinalizedAudioTrackMetadata(
                    fileName: "system-16k.wav",
                    sampleRate: 16_000,
                    channelCount: 1,
                    totalFrames: 1_440_000,
                    durationSeconds: 90,
                    timelineOffsetSeconds: 0
                ),
                microphone: nil,
                warnings: []
            ),
            transcription: SessionTranscriptionMetadata(
                status: .completed,
                model: "ggml-test.bin",
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
        let directory = try write(metadata: metadata)
        try Data([1]).write(to: directory.appendingPathComponent("system-16k.wav"))
        try Data("transcript".utf8).write(to: directory.appendingPathComponent("transcript.json"))
        return directory
    }

    @discardableResult
    private func write(metadata: SessionMetadata) throws -> URL {
        let directory = root.appendingPathComponent(metadata.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SessionJSONCoder.makeEncoder().encode(metadata)
        try data.write(to: directory.appendingPathComponent("session.json"))
        return directory
    }
}
