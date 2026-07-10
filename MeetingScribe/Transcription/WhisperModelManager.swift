import CryptoKit
import Foundation

struct WhisperModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let fileName: String
    let downloadURL: URL
    let expectedSHA1: String
    let approximateSizeBytes: Int64

    var displayName: String {
        switch id {
        case "large-v3-turbo": return "Large v3 Turbo"
        case "large-v3-turbo-q5_0": return "Large v3 Turbo Q5"
        case "medium": return "Medium"
        case "tiny": return "Tiny (prototype)"
        default: return id
        }
    }

    static let tiny = WhisperModelDescriptor(
        id: "tiny",
        fileName: "ggml-tiny.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
        expectedSHA1: "bd577a113a864445d4c299885e0cb97d4ba92b5f",
        approximateSizeBytes: 75 * 1_024 * 1_024
    )

    static let medium = WhisperModelDescriptor(
        id: "medium",
        fileName: "ggml-medium.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
        expectedSHA1: "fd9727b6e1217c2f614f9b698455c4ffd82463b4",
        approximateSizeBytes: 1_500 * 1_024 * 1_024
    )

    static let largeV3Turbo = WhisperModelDescriptor(
        id: "large-v3-turbo",
        fileName: "ggml-large-v3-turbo.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        expectedSHA1: "4af2b29d7ec73d781377bfd1758ca957a807e941",
        approximateSizeBytes: 1_500 * 1_024 * 1_024
    )

    static let largeV3TurboQ5 = WhisperModelDescriptor(
        id: "large-v3-turbo-q5_0",
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        expectedSHA1: "e050f7970618a659205450ad97eb95a18d69c9ee",
        approximateSizeBytes: 547 * 1_024 * 1_024
    )

    static let supported: [WhisperModelDescriptor] = [
        .largeV3Turbo,
        .largeV3TurboQ5,
        .medium,
        .tiny
    ]
}

enum WhisperModelStatus: Equatable, Sendable {
    case missing
    case ready(url: URL, sizeBytes: Int64)
    case invalid(reason: String)
}

actor WhisperModelManager {
    nonisolated let modelsRoot: URL
    private let fileManager: FileManager

    init(
        modelsRoot: URL = WhisperModelManager.defaultModelsRoot,
        fileManager: FileManager = .default
    ) {
        self.modelsRoot = modelsRoot
        self.fileManager = fileManager
    }

    static var defaultModelsRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    func prepareStorage() throws {
        try fileManager.createDirectory(
            at: modelsRoot,
            withIntermediateDirectories: true
        )
    }

    nonisolated func modelURL(for descriptor: WhisperModelDescriptor) -> URL {
        modelsRoot.appendingPathComponent(descriptor.fileName, isDirectory: false)
    }

    func status(for descriptor: WhisperModelDescriptor) throws -> WhisperModelStatus {
        let url = modelURL(for: descriptor)
        guard fileManager.fileExists(atPath: url.path) else { return .missing }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 1_024 else {
            return .invalid(reason: "The model file is empty or is not a regular file.")
        }
        return .ready(url: url, sizeBytes: Int64(size))
    }

    func importModel(
        from sourceURL: URL,
        as descriptor: WhisperModelDescriptor
    ) throws -> URL {
        try prepareStorage()
        try validateChecksum(of: sourceURL, expectedSHA1: descriptor.expectedSHA1)

        let destinationURL = modelURL(for: descriptor)
        let partialURL = destinationURL.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partialURL)
        try fileManager.copyItem(at: sourceURL, to: partialURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: partialURL, to: destinationURL)
        return destinationURL
    }

    func download(_ descriptor: WhisperModelDescriptor) async throws -> URL {
        try prepareStorage()
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: descriptor.downloadURL
        )
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw WhisperModelManagerError.downloadFailed
        }
        return try importModel(from: temporaryURL, as: descriptor)
    }

    func validateChecksum(of url: URL, expectedSHA1: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA1.lowercased() else {
            throw WhisperModelManagerError.checksumMismatch(
                expected: expectedSHA1.lowercased(),
                actual: digest
            )
        }
    }
}

enum WhisperModelManagerError: Error, LocalizedError, Equatable {
    case downloadFailed
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "The Whisper model download failed."
        case let .checksumMismatch(expected, actual):
            return "The Whisper model checksum is invalid. Expected \(expected), received \(actual)."
        }
    }
}
