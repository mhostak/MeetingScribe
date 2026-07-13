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
        MockModelURLProtocol.handler = nil
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

    func testRemoveModelDeletesInstalledAndPartialFiles() async throws {
        let manager = WhisperModelManager(modelsRoot: temporaryRoot)
        let descriptor = descriptor(expectedSHA1: String(repeating: "0", count: 40))
        try await manager.prepareStorage()
        let modelURL = manager.modelURL(for: descriptor)
        let partialURL = manager.downloadPartialURL(for: descriptor)
        try Data(repeating: 0x42, count: 4_096).write(to: modelURL)
        try Data(repeating: 0x24, count: 256).write(to: partialURL)

        try await manager.removeModel(descriptor)

        let status = try await manager.status(for: descriptor)
        XCTAssertEqual(status, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testDownloadUsesChecksumValidatedCachedModelWithoutNetworkRequest() async throws {
        let data = Data(repeating: 0x5a, count: 4_096)
        let descriptor = descriptor(expectedSHA1: sha1(of: data))
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let cachedURL = temporaryRoot.appendingPathComponent(descriptor.fileName)
        try data.write(to: cachedURL)
        MockModelURLProtocol.handler = { _ in
            XCTFail("A checksum-valid cached model must not make a network request.")
            throw URLError(.badServerResponse)
        }
        let progress = ProgressRecorder()
        let manager = WhisperModelManager(
            modelsRoot: temporaryRoot,
            urlSession: makeSession()
        )

        let result = try await manager.download(descriptor) { progress.record($0) }

        XCTAssertEqual(result, cachedURL)
        XCTAssertEqual(progress.last, 1)
    }

    func testDownloadResumesPartialFileWithRangeRequest() async throws {
        let completeData = Data((0..<8_192).map { UInt8($0 % 251) })
        let prefixCount = 3_000
        let descriptor = descriptor(
            expectedSHA1: sha1(of: completeData),
            approximateSizeBytes: Int64(completeData.count)
        )
        let manager = WhisperModelManager(
            modelsRoot: temporaryRoot,
            urlSession: makeSession()
        )
        try await manager.prepareStorage()
        try completeData.prefix(prefixCount).write(
            to: manager.downloadPartialURL(for: descriptor)
        )
        MockModelURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(prefixCount)-")
            return (
                206,
                [
                    "Content-Range": "bytes \(prefixCount)-\(completeData.count - 1)/\(completeData.count)",
                    "Content-Length": "\(completeData.count - prefixCount)",
                ],
                Data(completeData.dropFirst(prefixCount))
            )
        }

        let result = try await manager.download(descriptor)

        XCTAssertEqual(try Data(contentsOf: result), completeData)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: manager.downloadPartialURL(for: descriptor).path
        ))
    }

    func testDownloadRestartsPartialFileWhenServerDoesNotSupportRange() async throws {
        let completeData = Data(repeating: 0x7c, count: 4_096)
        let descriptor = descriptor(expectedSHA1: sha1(of: completeData))
        let manager = WhisperModelManager(
            modelsRoot: temporaryRoot,
            urlSession: makeSession()
        )
        try await manager.prepareStorage()
        try Data(repeating: 0x11, count: 1_000).write(
            to: manager.downloadPartialURL(for: descriptor)
        )
        MockModelURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1000-")
            return (200, ["Content-Length": "\(completeData.count)"], completeData)
        }

        let result = try await manager.download(descriptor)

        XCTAssertEqual(try Data(contentsOf: result), completeData)
    }

    func testDownloadRemovesPartialFileAfterChecksumMismatch() async throws {
        let data = Data(repeating: 0xa4, count: 4_096)
        let descriptor = descriptor(expectedSHA1: String(repeating: "0", count: 40))
        let manager = WhisperModelManager(
            modelsRoot: temporaryRoot,
            urlSession: makeSession()
        )
        MockModelURLProtocol.handler = { _ in
            (200, ["Content-Length": "\(data.count)"], data)
        }

        do {
            _ = try await manager.download(descriptor)
            XCTFail("Expected checksum validation to fail.")
        } catch {
            guard case WhisperModelManagerError.checksumMismatch = error else {
                return XCTFail("Expected checksumMismatch, received \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: manager.downloadPartialURL(for: descriptor).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: manager.modelURL(for: descriptor).path
        ))
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

    @MainActor
    func testTranscriptionLanguageSelectionPersistsAndDefaultsSafely() throws {
        let suiteName = "MeetingScribeWhisperLanguage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WhisperSettingsStore(defaults: defaults)

        XCTAssertEqual(store.selectedLanguage, .automatic)
        store.setSelectedLanguage(.czech)
        XCTAssertEqual(
            WhisperSettingsStore(defaults: defaults).selectedLanguage,
            .czech
        )

        defaults.set("unsupported", forKey: "selectedTranscriptionLanguage")
        XCTAssertEqual(
            WhisperSettingsStore(defaults: defaults).selectedLanguage,
            .automatic
        )
    }

    private func descriptor(
        expectedSHA1: String,
        approximateSizeBytes: Int64 = 4_096
    ) -> WhisperModelDescriptor {
        WhisperModelDescriptor(
            id: "test",
            fileName: "ggml-test.bin",
            downloadURL: URL(string: "https://example.invalid/ggml-test.bin")!,
            expectedSHA1: expectedSHA1,
            approximateSizeBytes: approximateSizeBytes
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockModelURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func sha1(of data: Data) -> String {
        Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    var last: Double? {
        lock.withLock { values.last }
    }

    func record(_ value: Double) {
        lock.withLock { values.append(value) }
    }
}

private final class MockModelURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (statusCode: Int, headers: [String: String], data: Data)
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.statusCode,
                httpVersion: nil,
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
