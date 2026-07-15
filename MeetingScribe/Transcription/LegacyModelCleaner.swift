import Foundation

struct LegacyModelCleanupReport: Equatable, Sendable {
    let fileCount: Int
    let totalBytes: Int64
}

struct LegacyModelCleaner: @unchecked Sendable {
    private static let modelFileNames = [
        "ggml-tiny.bin",
        "ggml-medium.bin",
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3-turbo-q5_0.bin",
        "ggml-silero-v6.2.0.bin",
        "ggml-small.en-tdrz.bin",
    ]
    private static let suffixes = ["", ".partial", ".download"]

    private let modelsRoot: URL
    private let fileManager: FileManager

    init(
        modelsRoot: URL = FluidAudioModelManager.defaultModelsRoot.deletingLastPathComponent(),
        fileManager: FileManager = .default
    ) {
        self.modelsRoot = modelsRoot
        self.fileManager = fileManager
    }

    func report() -> LegacyModelCleanupReport {
        let files = existingFiles()
        let bytes = files.reduce(Int64(0)) { total, url in
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return total + Int64(size ?? 0)
        }
        return LegacyModelCleanupReport(fileCount: files.count, totalBytes: bytes)
    }

    @discardableResult
    func remove() throws -> LegacyModelCleanupReport {
        let files = existingFiles()
        let report = self.report()
        for file in files { try fileManager.removeItem(at: file) }
        return report
    }

    private func existingFiles() -> [URL] {
        Self.modelFileNames.flatMap { name in
            Self.suffixes.map { suffix in
                modelsRoot.appendingPathComponent(name + suffix, isDirectory: false)
            }
        }.filter { fileManager.fileExists(atPath: $0.path) }
    }
}
