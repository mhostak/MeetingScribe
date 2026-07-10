import Foundation
import XCTest
@testable import MeetingScribe

final class SessionManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testStartCreatesSessionDirectoryAndManifest() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let startedAt = Date(timeIntervalSince1970: 1_725_876_600)

        let session = try await manager.startSession(title: "SOFA weekly", now: startedAt)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.manifestURL.path))

        let metadata = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(metadata.id, session.metadata.id)
        XCTAssertEqual(metadata.title, "SOFA weekly")
        XCTAssertEqual(metadata.status, .recording)
        XCTAssertEqual(metadata.startedAt, startedAt)
        XCTAssertEqual(metadata.audioFiles.system, "system.caf")
        XCTAssertEqual(metadata.audioFiles.microphone, "microphone.caf")
    }

    func testStopFinalizesManifestWithoutDeletingSession() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        let startedAt = Date(timeIntervalSince1970: 1_725_876_600)
        let endedAt = startedAt.addingTimeInterval(90)

        let started = try await manager.startSession(title: "", now: startedAt)
        let stopped = try await manager.stopSession(now: endedAt)
        let activeSession = await manager.currentSession()

        XCTAssertEqual(stopped.metadata.status, .recorded)
        XCTAssertEqual(stopped.metadata.endedAt, endedAt)
        XCTAssertNil(activeSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.directoryURL.path))

        let metadata = try decodeMetadata(at: stopped.manifestURL)
        XCTAssertEqual(metadata.status, .recorded)
        XCTAssertEqual(metadata.endedAt, endedAt)
        XCTAssertTrue(metadata.title.hasPrefix("Meeting "))
    }

    func testCannotStartSecondSession() async throws {
        let manager = SessionManager(recordingsRoot: temporaryRoot)
        _ = try await manager.startSession(title: "First")

        do {
            _ = try await manager.startSession(title: "Second")
            XCTFail("Expected a second active session to be rejected.")
        } catch {
            XCTAssertEqual(error as? SessionManagerError, .sessionAlreadyActive)
        }
    }

    private func decodeMetadata(at url: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: url)
        return try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: data)
    }
}
