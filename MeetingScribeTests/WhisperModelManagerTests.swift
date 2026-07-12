import CryptoKit
import Foundation
import XCTest
@testable import MeetingScribe

final class WhisperModelManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeModels-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testMissingModelStatus() async throws {
        let manager = WhisperModelManager(modelsRoot: temporaryRoot)

        let status = try await manager.status(for: .tiny)

        XCTAssertEqual(status, .missing)
    }

    func testImportsChecksumValidatedModelAtomically() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeModelSource-\(UUID().uuidString).bin")
        let data = Data(repeating: 0x42, count: 4_096)
        try data.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let descriptor = descriptor(expectedSHA1: sha1(of: data))
        let manager = WhisperModelManager(modelsRoot: temporaryRoot)

        let importedURL = try await manager.importModel(from: sourceURL, as: descriptor)
        let status = try await manager.status(for: descriptor)

        XCTAssertEqual(importedURL.lastPathComponent, descriptor.fileName)
        XCTAssertEqual(status, .ready(url: importedURL, sizeBytes: 4_096))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: importedURL.appendingPathExtension("partial").path
        ))
    }

    func testRejectsModelWithWrongChecksum() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeModelSource-\(UUID().uuidString).bin")
        try Data(repeating: 0x13, count: 4_096).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let manager = WhisperModelManager(modelsRoot: temporaryRoot)

        do {
            _ = try await manager.importModel(
                from: sourceURL,
                as: descriptor(expectedSHA1: String(repeating: "0", count: 40))
            )
            XCTFail("Expected checksum validation to fail.")
        } catch {
            guard case WhisperModelManagerError.checksumMismatch = error else {
                return XCTFail("Expected checksumMismatch, received \(error)")
            }
        }
    }

    @MainActor
    func testWhisperModelSelectionPersists() throws {
        let suiteName = "MeetingScribeWhisperSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WhisperSettingsStore(defaults: defaults)

        XCTAssertEqual(store.selectedModelID, WhisperModelDescriptor.largeV3Turbo.id)
        store.setSelectedModelID(WhisperModelDescriptor.tiny.id)

        XCTAssertEqual(
            WhisperSettingsStore(defaults: defaults).selectedModelID,
            WhisperModelDescriptor.tiny.id
        )
    }

    private func descriptor(expectedSHA1: String) -> WhisperModelDescriptor {
        WhisperModelDescriptor(
            id: "test",
            fileName: "ggml-test.bin",
            downloadURL: URL(string: "https://example.invalid/ggml-test.bin")!,
            expectedSHA1: expectedSHA1,
            approximateSizeBytes: 4_096
        )
    }

    private func sha1(of data: Data) -> String {
        Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
