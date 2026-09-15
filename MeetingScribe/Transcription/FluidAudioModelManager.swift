import CryptoKit
import FluidAudio
import Foundation

enum FluidAudioModelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcription

    var id: String { rawValue }
}

struct FluidAudioModelFile: Codable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int64
    let sha256: String
}

struct FluidAudioModelManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: FluidAudioModelKind
    let repository: String
    let revision: String
    let variant: String
    let files: [FluidAudioModelFile]
}

struct FluidAudioModelDescriptor: Equatable, Identifiable, Sendable {
    let kind: FluidAudioModelKind
    let displayName: String
    let repository: String
    let revision: String
    let variant: String
    let installationFolderName: String
    let licenseName: String
    let files: [FluidAudioModelFile]

    var id: String { kind.rawValue }

    var approximateSizeBytes: Int64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }

    var sourceURL: URL {
        URL(string: "https://huggingface.co/\(repository)/tree/\(revision)")!
    }

    var manifest: FluidAudioModelManifest {
        FluidAudioModelManifest(
            schemaVersion: 1,
            kind: kind,
            repository: repository,
            revision: revision,
            variant: variant,
            files: files
        )
    }

    static let parakeetV3 = FluidAudioModelDescriptor(
        kind: .transcription,
        displayName: "Parakeet TDT 0.6B v3 (int8)",
        repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        revision: "aed02740059203c4a87495924f685de3722ae9ce",
        variant: "v3-int8",
        installationFolderName: "parakeet-tdt-0.6b-v3",
        licenseName: "CC BY 4.0",
        files: [
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", sizeBytes: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", sizeBytes: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            .init(path: "Decoder.mlmodelc/metadata.json", sizeBytes: 3_427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            .init(path: "Decoder.mlmodelc/model.mil", sizeBytes: 13_110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", sizeBytes: 23_604_992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", sizeBytes: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", sizeBytes: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            .init(path: "Encoder.mlmodelc/metadata.json", sizeBytes: 2_921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            .init(path: "Encoder.mlmodelc/model.mil", sizeBytes: 959_769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", sizeBytes: 445_187_200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", sizeBytes: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", sizeBytes: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            .init(path: "JointDecisionv3.mlmodelc/metadata.json", sizeBytes: 3_453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            .init(path: "JointDecisionv3.mlmodelc/model.mil", sizeBytes: 11_775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", sizeBytes: 12_642_764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", sizeBytes: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", sizeBytes: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", sizeBytes: 2_841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            .init(path: "Preprocessor.mlmodelc/model.mil", sizeBytes: 28_181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", sizeBytes: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            .init(path: "parakeet_vocab.json", sizeBytes: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
    )

    static let supported: [FluidAudioModelDescriptor] = [
        .parakeetV3,
    ]
}

enum FluidAudioModelStatus: Equatable, Sendable {
    case missing
    case ready(bundleURL: URL, sizeBytes: Int64)
    case invalid(reason: String)
}

struct FluidAudioModelDownloadProgress: Equatable, Sendable {
    let fractionCompleted: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
}

protocol FluidAudioModelFileDownloading: Sendable {
    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSizeBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

private final class FluidAudioDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let progress: @Sendable (Int64) -> Void

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

struct FluidAudioHTTPModelFileDownloader: FluidAudioModelFileDownloading, @unchecked Sendable {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSizeBytes: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try Task.checkCancellation()
        let delegate = FluidAudioDownloadDelegate(progress: progress)
        let (temporaryURL, response) = try await session.download(
            for: URLRequest(url: sourceURL),
            delegate: delegate
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            throw FluidAudioModelManagerError.downloadFailed(sourceURL.lastPathComponent)
        }

        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard actualSize == expectedSizeBytes else {
            throw FluidAudioModelManagerError.invalidSize(
                path: sourceURL.lastPathComponent,
                expected: expectedSizeBytes,
                actual: actualSize
            )
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        progress(actualSize)
    }
}

protocol FluidAudioModelLoadValidating: Sendable {
    func validate(
        descriptor: FluidAudioModelDescriptor,
        modelsRoot: URL
    ) async throws
}

struct ProductionFluidAudioModelLoadValidator: FluidAudioModelLoadValidating {
    func validate(
        descriptor: FluidAudioModelDescriptor,
        modelsRoot: URL
    ) async throws {
        ModelHub.offlineMode = true
        switch descriptor.kind {
        case .transcription:
            _ = try await AsrModels.load(
                from: modelsRoot.appendingPathComponent(
                    descriptor.installationFolderName,
                    isDirectory: true
                ),
                version: .v3,
                encoderPrecision: .int8
            )
        }
    }
}

protocol FluidAudioModelManaging: Sendable {
    func prepareStorage() async throws
    func status(for descriptor: FluidAudioModelDescriptor) async -> FluidAudioModelStatus
    func validateInstalledModel(_ descriptor: FluidAudioModelDescriptor) async throws -> URL
    func install(
        _ descriptor: FluidAudioModelDescriptor,
        repair: Bool,
        progress: @escaping @Sendable (FluidAudioModelDownloadProgress) -> Void
    ) async throws -> URL
    func importBundle(
        from sourceBundleURL: URL,
        as descriptor: FluidAudioModelDescriptor
    ) async throws -> URL
    func removeModel(_ descriptor: FluidAudioModelDescriptor) async throws
}

actor FluidAudioModelManager: FluidAudioModelManaging {
    nonisolated static let manifestFileName = ".meetingscribe-model-manifest.json"
    nonisolated let modelsRoot: URL

    private let fileManager: FileManager
    private let downloader: any FluidAudioModelFileDownloading
    private let loadValidator: any FluidAudioModelLoadValidating
    private var activeStagingRoots = Set<URL>()

    init(
        modelsRoot: URL = FluidAudioModelManager.defaultModelsRoot,
        fileManager: FileManager = .default,
        downloader: any FluidAudioModelFileDownloading = FluidAudioHTTPModelFileDownloader(),
        loadValidator: any FluidAudioModelLoadValidating = ProductionFluidAudioModelLoadValidator()
    ) {
        self.modelsRoot = modelsRoot
        self.fileManager = fileManager
        self.downloader = downloader
        self.loadValidator = loadValidator
    }

    static var defaultModelsRoot: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("MeetingScribe", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    func prepareStorage() throws {
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let stagingRoot = modelsRoot.appendingPathComponent(".staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try removeAbandonedStagingDirectories(at: stagingRoot)
    }

    nonisolated func bundleURL(for descriptor: FluidAudioModelDescriptor) -> URL {
        modelsRoot.appendingPathComponent(
            descriptor.installationFolderName,
            isDirectory: true
        )
    }

    func status(for descriptor: FluidAudioModelDescriptor) -> FluidAudioModelStatus {
        let bundleURL = bundleURL(for: descriptor)
        guard fileManager.fileExists(atPath: bundleURL.path) else { return .missing }
        do {
            try validateBundle(
                at: bundleURL,
                descriptor: descriptor,
                verifyChecksums: false
            )
            return .ready(bundleURL: bundleURL, sizeBytes: descriptor.approximateSizeBytes)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
    }

    @discardableResult
    func validateInstalledModel(
        _ descriptor: FluidAudioModelDescriptor
    ) async throws -> URL {
        let installedBundleURL = bundleURL(for: descriptor)
        try validateBundle(
            at: installedBundleURL,
            descriptor: descriptor,
            verifyChecksums: true
        )
        try await loadValidator.validate(descriptor: descriptor, modelsRoot: modelsRoot)
        return installedBundleURL
    }

    @discardableResult
    func install(
        _ descriptor: FluidAudioModelDescriptor,
        repair: Bool = false,
        progress: @escaping @Sendable (FluidAudioModelDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        try prepareStorage()
        if !repair, case let .ready(bundleURL, _) = status(for: descriptor) {
            progress(.init(
                fractionCompleted: 1,
                downloadedBytes: descriptor.approximateSizeBytes,
                totalBytes: descriptor.approximateSizeBytes
            ))
            return bundleURL
        }

        let stagingRoot = try makeStagingRoot(for: descriptor)
        do {
            let stagedBundleURL = stagingRoot.appendingPathComponent(
                descriptor.installationFolderName,
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: stagedBundleURL,
                withIntermediateDirectories: true
            )

            var completedBytes: Int64 = 0
            for file in descriptor.files {
                try Task.checkCancellation()
                let stagedFileURL = stagedBundleURL.appendingPathComponent(file.path)
                let installedFileURL = bundleURL(for: descriptor)
                    .appendingPathComponent(file.path)

                if isValid(file: file, at: installedFileURL) {
                    try copyInstalledFile(from: installedFileURL, to: stagedFileURL)
                    completedBytes += file.sizeBytes
                    reportProgress(completedBytes, descriptor: descriptor, progress: progress)
                    continue
                }

                let completedBeforeFile = completedBytes
                try await downloader.download(
                    from: try remoteURL(for: file, descriptor: descriptor),
                    to: stagedFileURL,
                    expectedSizeBytes: file.sizeBytes
                ) { downloadedBytes in
                    let aggregate = min(
                        completedBeforeFile + downloadedBytes,
                        descriptor.approximateSizeBytes
                    )
                    progress(.init(
                        fractionCompleted: Double(aggregate)
                            / Double(descriptor.approximateSizeBytes),
                        downloadedBytes: aggregate,
                        totalBytes: descriptor.approximateSizeBytes
                    ))
                }
                try validate(file: file, at: stagedFileURL)
                completedBytes += file.sizeBytes
                reportProgress(completedBytes, descriptor: descriptor, progress: progress)
            }

            try writeManifest(descriptor.manifest, to: stagedBundleURL)
            try validateBundle(
                at: stagedBundleURL,
                descriptor: descriptor,
                verifyChecksums: true
            )
            try Task.checkCancellation()
            try await loadValidator.validate(descriptor: descriptor, modelsRoot: stagingRoot)
            try Task.checkCancellation()
            try promote(stagedBundleURL, descriptor: descriptor)
            cleanupStagingRoot(stagingRoot)
            progress(.init(
                fractionCompleted: 1,
                downloadedBytes: descriptor.approximateSizeBytes,
                totalBytes: descriptor.approximateSizeBytes
            ))
            return bundleURL(for: descriptor)
        } catch {
            cleanupStagingRoot(stagingRoot)
            throw error
        }
    }

    @discardableResult
    func importBundle(
        from sourceBundleURL: URL,
        as descriptor: FluidAudioModelDescriptor
    ) async throws -> URL {
        try prepareStorage()
        let stagingRoot = try makeStagingRoot(for: descriptor)
        do {
            let stagedBundleURL = stagingRoot.appendingPathComponent(
                descriptor.installationFolderName,
                isDirectory: true
            )
            for file in descriptor.files {
                try Task.checkCancellation()
                let sourceFileURL = sourceBundleURL.appendingPathComponent(file.path)
                try validate(file: file, at: sourceFileURL)
                try copyInstalledFile(
                    from: sourceFileURL,
                    to: stagedBundleURL.appendingPathComponent(file.path)
                )
            }
            try writeManifest(descriptor.manifest, to: stagedBundleURL)
            try validateBundle(
                at: stagedBundleURL,
                descriptor: descriptor,
                verifyChecksums: true
            )
            try await loadValidator.validate(descriptor: descriptor, modelsRoot: stagingRoot)
            try Task.checkCancellation()
            try promote(stagedBundleURL, descriptor: descriptor)
            cleanupStagingRoot(stagingRoot)
            return bundleURL(for: descriptor)
        } catch {
            cleanupStagingRoot(stagingRoot)
            throw error
        }
    }

    func removeModel(_ descriptor: FluidAudioModelDescriptor) throws {
        let url = bundleURL(for: descriptor)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func makeStagingRoot(for descriptor: FluidAudioModelDescriptor) throws -> URL {
        let root = modelsRoot
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                "\(descriptor.id)-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        activeStagingRoots.insert(root)
        return root
    }

    private func removeAbandonedStagingDirectories(at stagingRoot: URL) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        )
        for url in urls where !activeStagingRoots.contains(url) {
            try fileManager.removeItem(at: url)
        }
    }

    private func cleanupStagingRoot(_ url: URL) {
        try? fileManager.removeItem(at: url)
        activeStagingRoots.remove(url)
    }

    private func remoteURL(
        for file: FluidAudioModelFile,
        descriptor: FluidAudioModelDescriptor
    ) throws -> URL {
        let encodedPath = file.path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? file.path
        guard let url = URL(
            string: "https://huggingface.co/\(descriptor.repository)/resolve/\(descriptor.revision)/\(encodedPath)"
        ) else {
            throw FluidAudioModelManagerError.invalidRemoteURL(file.path)
        }
        return url
    }

    private func reportProgress(
        _ completedBytes: Int64,
        descriptor: FluidAudioModelDescriptor,
        progress: @Sendable (FluidAudioModelDownloadProgress) -> Void
    ) {
        progress(.init(
            fractionCompleted: Double(completedBytes)
                / Double(descriptor.approximateSizeBytes),
            downloadedBytes: completedBytes,
            totalBytes: descriptor.approximateSizeBytes
        ))
    }

    private func copyInstalledFile(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func writeManifest(
        _ manifest: FluidAudioModelManifest,
        to bundleURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(
            to: bundleURL.appendingPathComponent(Self.manifestFileName),
            options: .atomic
        )
    }

    private func validateBundle(
        at bundleURL: URL,
        descriptor: FluidAudioModelDescriptor,
        verifyChecksums: Bool
    ) throws {
        let manifestURL = bundleURL.appendingPathComponent(Self.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw FluidAudioModelManagerError.manifestMissing
        }
        let installedManifest = try JSONDecoder().decode(
            FluidAudioModelManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard installedManifest == descriptor.manifest else {
            throw FluidAudioModelManagerError.manifestMismatch
        }
        for file in descriptor.files {
            try validate(
                file: file,
                at: bundleURL.appendingPathComponent(file.path),
                verifyChecksum: verifyChecksums
            )
        }
    }

    private func isValid(file: FluidAudioModelFile, at url: URL) -> Bool {
        (try? validate(file: file, at: url, verifyChecksum: true)) != nil
    }

    private func validate(
        file: FluidAudioModelFile,
        at url: URL,
        verifyChecksum: Bool = true
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FluidAudioModelManagerError.fileMissing(file.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard actualSize == file.sizeBytes else {
            throw FluidAudioModelManagerError.invalidSize(
                path: file.path,
                expected: file.sizeBytes,
                actual: actualSize
            )
        }
        guard verifyChecksum else { return }
        let actualSHA256 = try sha256(of: url)
        guard actualSHA256 == file.sha256.lowercased() else {
            throw FluidAudioModelManagerError.checksumMismatch(
                path: file.path,
                expected: file.sha256.lowercased(),
                actual: actualSHA256
            )
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func promote(
        _ stagedBundleURL: URL,
        descriptor: FluidAudioModelDescriptor
    ) throws {
        let destinationURL = bundleURL(for: descriptor)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagedBundleURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagedBundleURL, to: destinationURL)
        }
    }
}

enum FluidAudioModelManagerError: Error, LocalizedError, Equatable {
    case invalidRemoteURL(String)
    case downloadFailed(String)
    case manifestMissing
    case manifestMismatch
    case fileMissing(String)
    case invalidSize(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRemoteURL(path):
            return "The pinned model URL is invalid for \(path)."
        case let .downloadFailed(path):
            return "The FluidAudio model download failed for \(path)."
        case .manifestMissing:
            return "The verified FluidAudio model manifest is missing."
        case .manifestMismatch:
            return "The installed FluidAudio model does not match the pinned revision."
        case let .fileMissing(path):
            return "The FluidAudio model file \(path) is missing."
        case let .invalidSize(path, expected, actual):
            return "The FluidAudio model file \(path) has size \(actual), expected \(expected)."
        case let .checksumMismatch(path, expected, actual):
            return "The FluidAudio model file \(path) has SHA-256 \(actual), expected \(expected)."
        }
    }
}
