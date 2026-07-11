import Foundation
import XCTest
@testable import MeetingScribe

final class OutputFolderAndObsidianTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeVault-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    func testOutputFolderStorePersistsAndClearsSelection() throws {
        let suiteName = "MeetingScribeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OutputFolderStore(defaults: defaults)

        try store.selectFolder(temporaryRoot)
        let restored = store.restoreFolder()

        XCTAssertEqual(restored?.standardizedFileURL, temporaryRoot.standardizedFileURL)
        let value = store.withAccess(to: restored!) { "accessible" }
        XCTAssertEqual(value, "accessible")

        store.clearFolder()
        XCTAssertNil(store.restoreFolder())
    }

    func testObsidianServiceBuildsURIForFileInsideVault() throws {
        let marker = temporaryRoot.appendingPathComponent(".obsidian", isDirectory: true)
        let meetings = temporaryRoot
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let markdownURL = meetings.appendingPathComponent("SOFA weekly.md")

        let service = ObsidianService()
        let openURL = try XCTUnwrap(service.openURL(for: markdownURL))
        let components = try XCTUnwrap(URLComponents(url: openURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )

        XCTAssertEqual(openURL.scheme, "obsidian")
        XCTAssertEqual(openURL.host, "open")
        XCTAssertEqual(query["vault"]!, temporaryRoot.lastPathComponent)
        XCTAssertEqual(query["file"]!, "Meetings/2026/SOFA weekly.md")
    }

    func testObsidianServiceRejectsFileOutsideVault() {
        let markdownURL = temporaryRoot.appendingPathComponent("Meeting.md")
        XCTAssertNil(ObsidianService().openURL(for: markdownURL))
    }
}
