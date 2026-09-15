import CryptoKit
import Foundation
import XCTest
@testable import MeetingScribe

final class FluidAudioModelManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeFluidModels-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testProductionDescriptorsPinRevisionAndEveryFileHash() {
        let asr = FluidAudioModelDescriptor.parakeetV3

        XCTAssertEqual(asr.revision, "aed02740059203c4a87495924f685de3722ae9ce")
        XCTAssertEqual(asr.files.count, 21)
        XCTAssertTrue(asr.files.allSatisfy {
            $0.sizeBytes > 0 && $0.sha256.count == 64
        })
        XCTAssertTrue(asr.sourceURL.absoluteString.contains(asr.revision))
    }

    func testInstallVerifiesWritesManifestLoadsAndPromotesBundle() async throws {
        let fixture = makeFixture()
        let downloader = StubFluidAudioDownloader(files: fixture.files)
        let validator = RecordingFluidAudioLoadValidator()
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            downloader: downloader,
            loadValidator: validator
        )
        let progress = ProgressRecorder()

        let installedURL = try await manager.install(fixture.descriptor) { update in
            Task { await progress.append(update) }
        }

        XCTAssertEqual(installedURL, manager.bundleURL(for: fixture.descriptor))
        XCTAssertEqual(
            try Data(contentsOf: installedURL.appendingPathComponent("model/data.bin")),
            fixture.files["model/data.bin"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL
            .appendingPathComponent(FluidAudioModelManager.manifestFileName).path))
        let installedStatus = await manager.status(for: fixture.descriptor)
        let validationCount = await validator.validationCount()
        let downloadedPaths = await downloader.downloadedPaths()
        let progressUpdates = await progress.updates()
        XCTAssertEqual(
            installedStatus,
            .ready(bundleURL: installedURL, sizeBytes: fixture.descriptor.approximateSizeBytes)
        )
        XCTAssertEqual(validationCount, 1)
        XCTAssertEqual(downloadedPaths, ["model/data.bin", "vocab.json"])
        XCTAssertEqual(progressUpdates.last?.fractionCompleted, 1)
    }

    func testCorruptionIsReportedAndRepairDownloadsOnlyInvalidFile() async throws {
        let fixture = makeFixture()
        let downloader = StubFluidAudioDownloader(files: fixture.files)
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            downloader: downloader,
            loadValidator: RecordingFluidAudioLoadValidator()
        )
        let installedURL = try await manager.install(fixture.descriptor)
        await downloader.resetDownloads()
        try Data("corrupt".utf8).write(
            to: installedURL.appendingPathComponent("model/data.bin")
        )

        guard case .invalid = await manager.status(for: fixture.descriptor) else {
            return XCTFail("Corrupt bundle must be invalid")
        }

        _ = try await manager.install(fixture.descriptor, repair: true)

        let repairDownloads = await downloader.downloadedPaths()
        let repairedStatus = await manager.status(for: fixture.descriptor)
        XCTAssertEqual(repairDownloads, ["model/data.bin"])
        XCTAssertEqual(
            repairedStatus,
            .ready(
                bundleURL: manager.bundleURL(for: fixture.descriptor),
                sizeBytes: fixture.descriptor.approximateSizeBytes
            )
        )
    }

    func testFailedRepairPreservesPreviouslyInstalledBundle() async throws {
        let fixture = makeFixture()
        let successfulDownloader = StubFluidAudioDownloader(files: fixture.files)
        let validator = RecordingFluidAudioLoadValidator()
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            downloader: successfulDownloader,
            loadValidator: validator
        )
        let installedURL = try await manager.install(fixture.descriptor)
        let originalManifest = try Data(contentsOf: installedURL
            .appendingPathComponent(FluidAudioModelManager.manifestFileName))

        await validator.setFailure(TestFailure.loadRejected)
        do {
            _ = try await manager.install(fixture.descriptor, repair: true)
            XCTFail("Expected load validation failure")
        } catch TestFailure.loadRejected {}

        XCTAssertEqual(
            try Data(contentsOf: installedURL
                .appendingPathComponent(FluidAudioModelManager.manifestFileName)),
            originalManifest
        )
        let preservedStatus = await manager.status(for: fixture.descriptor)
        XCTAssertEqual(
            preservedStatus,
            .ready(bundleURL: installedURL, sizeBytes: fixture.descriptor.approximateSizeBytes)
        )
    }

    func testCancellationLeavesNoPromotedOrStagedBundle() async throws {
        let fixture = makeFixture()
        let downloader = SuspendingFluidAudioDownloader()
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            downloader: downloader,
            loadValidator: RecordingFluidAudioLoadValidator()
        )

        let task = Task {
            try await manager.install(fixture.descriptor)
        }
        await downloader.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let cancelledStatus = await manager.status(for: fixture.descriptor)
        XCTAssertEqual(cancelledStatus, .missing)
        let stagingURL = temporaryRoot.appendingPathComponent(".staging")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagingURL.path),
            []
        )
    }

    func testDiskFullDownloadFailureDoesNotPromotePartialBundle() async throws {
        let fixture = makeFixture()
        let downloader = ThrowingFluidAudioDownloader(
            error: CocoaError(.fileWriteOutOfSpace)
        )
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            downloader: downloader,
            loadValidator: RecordingFluidAudioLoadValidator()
        )

        do {
            _ = try await manager.install(fixture.descriptor)
            XCTFail("Expected disk-full failure")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteOutOfSpace)
        }

        let failedStatus = await manager.status(for: fixture.descriptor)
        XCTAssertEqual(failedStatus, .missing)
    }

    func testImportRequiresEveryPinnedHashBeforePromotion() async throws {
        let fixture = makeFixture()
        let sourceURL = temporaryRoot.appendingPathComponent("import", isDirectory: true)
        try writeFixture(fixture.files, to: sourceURL)
        try Data("wrong".utf8).write(to: sourceURL.appendingPathComponent("vocab.json"))
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot.appendingPathComponent("models"),
            downloader: StubFluidAudioDownloader(files: [:]),
            loadValidator: RecordingFluidAudioLoadValidator()
        )

        do {
            _ = try await manager.importBundle(from: sourceURL, as: fixture.descriptor)
            XCTFail("Expected import verification failure")
        } catch {}

        let importStatus = await manager.status(for: fixture.descriptor)
        XCTAssertEqual(importStatus, .missing)
    }

    func testInstalledBundleCanBeLoadedRepeatedlyWithoutDownloader() async throws {
        let fixture = makeFixture()
        let downloader = StubFluidAudioDownloader(files: fixture.files)
        let validator = RecordingFluidAudioLoadValidator()
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            downloader: downloader,
            loadValidator: validator
        )
        _ = try await manager.install(fixture.descriptor)
        await downloader.resetDownloads()

        _ = try await manager.validateInstalledModel(fixture.descriptor)
        _ = try await manager.validateInstalledModel(fixture.descriptor)

        let validationCount = await validator.validationCount()
        let downloadedPaths = await downloader.downloadedPaths()
        XCTAssertEqual(validationCount, 3)
        XCTAssertEqual(downloadedPaths, [])
    }

    func testDeleteRemovesOnlySelectedBundle() async throws {
        let first = makeFixture(kind: .transcription, folder: "first")
        let second = makeFixture(kind: .transcription, folder: "second")
        let downloader = StubFluidAudioDownloader(files: first.files.merging(second.files) { a, _ in a })
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            downloader: downloader,
            loadValidator: RecordingFluidAudioLoadValidator()
        )
        _ = try await manager.install(first.descriptor)
        _ = try await manager.install(second.descriptor)

        try await manager.removeModel(first.descriptor)

        let firstStatus = await manager.status(for: first.descriptor)
        XCTAssertEqual(firstStatus, .missing)
        guard case .ready = await manager.status(for: second.descriptor) else {
            return XCTFail("Second bundle should remain installed")
        }
    }

    func testImportsAndReloadsRealPinnedBundlesWhenPathsAreProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let asrPath = environment["MEETINGSCRIBE_FLUID_ASR_BUNDLE"]
        else {
            throw XCTSkip(
                "Set MEETINGSCRIBE_FLUID_ASR_BUNDLE for the real offline load test."
            )
        }
        let manager = FluidAudioModelManager(
            modelsRoot: temporaryRoot,
            loadValidator: ProductionFluidAudioModelLoadValidator()
        )

        _ = try await manager.importBundle(
            from: URL(fileURLWithPath: asrPath, isDirectory: true),
            as: .parakeetV3
        )
        _ = try await manager.validateInstalledModel(.parakeetV3)
        guard case .ready = await manager.status(for: .parakeetV3) else {
            return XCTFail("Real ASR bundle is not ready after offline reload")
        }
    }

    func testLegacyCleanupIsExplicitAndPreservesFluidAudioBundlesAndOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingScribeLegacyModels-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("FluidAudio/current", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("ggml-large-v3-turbo.bin")
        let partial = root.appendingPathComponent("ggml-small.en-tdrz.bin.download")
        let unrelated = root.appendingPathComponent("keep-me.bin")
        let fluid = root.appendingPathComponent("FluidAudio/current/model.mlmodelc")
        try Data(repeating: 1, count: 10).write(to: model)
        try Data(repeating: 2, count: 7).write(to: partial)
        try Data(repeating: 3, count: 5).write(to: unrelated)
        try Data(repeating: 4, count: 3).write(to: fluid)
        let cleaner = LegacyModelCleaner(modelsRoot: root)

        XCTAssertEqual(cleaner.report(), .init(fileCount: 2, totalBytes: 17))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))

        let removed = try cleaner.remove()

        XCTAssertEqual(removed, .init(fileCount: 2, totalBytes: 17))
        XCTAssertEqual(cleaner.report(), .init(fileCount: 0, totalBytes: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fluid.path))
    }

    private func makeFixture(
        kind: FluidAudioModelKind = .transcription,
        folder: String = "fixture-model"
    ) -> (descriptor: FluidAudioModelDescriptor, files: [String: Data]) {
        let files = [
            "model/data.bin": Data(repeating: 0x42, count: 4_096),
            "vocab.json": Data("{\"tokens\":[\"a\"]}".utf8),
        ]
        let manifestFiles = files.keys.sorted().map { path in
            let data = files[path]!
            return FluidAudioModelFile(
                path: path,
                sizeBytes: Int64(data.count),
                sha256: sha256(of: data)
            )
        }
        return (
            FluidAudioModelDescriptor(
                kind: kind,
                displayName: "Fixture",
                repository: "example/fixture",
                revision: "0123456789abcdef",
                variant: "test",
                installationFolderName: folder,
                licenseName: "Test",
                files: manifestFiles
            ),
            files
        )
    }

    private func writeFixture(_ files: [String: Data], to root: URL) throws {
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
    }

    private func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor StubFluidAudioDownloader: FluidAudioModelFileDownloading {
    private let files: [String: Data]
    private var downloads: [String] = []

    init(files: [String: Data]) {
        self.files = files
    }

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSizeBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let path = files.keys.first { sourceURL.path.hasSuffix($0) }
        guard let path, let data = files[path] else { throw TestFailure.missingFixture }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL)
        downloads.append(path)
        progress(Int64(data.count))
    }

    func downloadedPaths() -> [String] { downloads }
    func resetDownloads() { downloads = [] }
}

private actor RecordingFluidAudioLoadValidator: FluidAudioModelLoadValidating {
    private var count = 0
    private var failure: Error?

    func validate(
        descriptor: FluidAudioModelDescriptor,
        modelsRoot: URL
    ) async throws {
        count += 1
        if let failure { throw failure }
    }

    func validationCount() -> Int { count }
    func setFailure(_ error: Error?) { failure = error }
}

private actor ProgressRecorder {
    private var values: [FluidAudioModelDownloadProgress] = []
    func append(_ value: FluidAudioModelDownloadProgress) { values.append(value) }
    func updates() -> [FluidAudioModelDownloadProgress] { values }
}

private actor SuspendingFluidAudioDownloader: FluidAudioModelFileDownloading {
    private var started = false

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSizeBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        started = true
        try await Task.sleep(for: .seconds(60))
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private struct ThrowingFluidAudioDownloader: FluidAudioModelFileDownloading {
    let error: Error

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSizeBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        throw error
    }
}

private enum TestFailure: Error {
    case missingFixture
    case loadRejected
}
