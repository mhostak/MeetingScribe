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
        case "silero-vad-v6.2.0": return "Silero VAD 6.2.0"
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

    static let sileroVAD = WhisperModelDescriptor(
        id: "silero-vad-v6.2.0",
        fileName: "ggml-silero-v6.2.0.bin",
        downloadURL: URL(
            string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
        )!,
        expectedSHA1: "470e5d9d094ddba2f0a512cecc3732a252188abd",
        approximateSizeBytes: 865 * 1_024
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
    private let urlSession: URLSession

    init(
        modelsRoot: URL = WhisperModelManager.defaultModelsRoot,
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared
    ) {
        self.modelsRoot = modelsRoot
        self.fileManager = fileManager
        self.urlSession = urlSession
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

    func removeModel(_ descriptor: WhisperModelDescriptor) throws {
        let urls = [
            modelURL(for: descriptor),
            downloadPartialURL(for: descriptor),
        ]
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func download(
        _ descriptor: WhisperModelDescriptor,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try prepareStorage()

        let destinationURL = modelURL(for: descriptor)
        if fileManager.fileExists(atPath: destinationURL.path) {
            do {
                try validateChecksum(of: destinationURL, expectedSHA1: descriptor.expectedSHA1)
                progress(1)
                return destinationURL
            } catch {
                try fileManager.removeItem(at: destinationURL)
            }
        }

        let partialURL = downloadPartialURL(for: descriptor)
        let existingBytes = fileSize(at: partialURL)
        var request = URLRequest(url: descriptor.downloadURL)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try? fileManager.removeItem(at: partialURL)
            throw WhisperModelManagerError.downloadFailed
        }

        let isResume = existingBytes > 0 && httpResponse.statusCode == 206
        if isResume {
            guard contentRangeStarts(at: existingBytes, response: httpResponse) else {
                try? fileManager.removeItem(at: partialURL)
                throw WhisperModelManagerError.invalidResumeResponse
            }
        } else if !(200..<300).contains(httpResponse.statusCode) {
            try? fileManager.removeItem(at: partialURL)
            throw WhisperModelManagerError.downloadFailed
        }

        let startingBytes = isResume ? existingBytes : 0
        if !isResume {
            try? fileManager.removeItem(at: partialURL)
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw WhisperModelManagerError.downloadFailed
            }
        }

        let expectedResponseBytes = response.expectedContentLength
        let expectedTotalBytes = expectedResponseBytes > 0
            ? startingBytes + expectedResponseBytes
            : descriptor.approximateSizeBytes
        let handle = try FileHandle(forWritingTo: partialURL)
        do {
            try handle.seekToEnd()
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            var downloadedBytes = startingBytes

            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 64 * 1_024 {
                    try handle.write(contentsOf: buffer)
                    downloadedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    reportProgress(downloadedBytes, expectedTotalBytes, progress)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                downloadedBytes += Int64(buffer.count)
                reportProgress(downloadedBytes, expectedTotalBytes, progress)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.synchronize()
            try? handle.close()
            if !(error is CancellationError) {
                // URLSession transport errors leave a valid byte prefix for a later Range request.
                // Local file errors can make that prefix unreliable.
                if !(error is URLError) {
                    try? fileManager.removeItem(at: partialURL)
                }
            }
            throw error
        }

        do {
            try validateChecksum(of: partialURL, expectedSHA1: descriptor.expectedSHA1)
            try fileManager.moveItem(at: partialURL, to: destinationURL)
            progress(1)
            return destinationURL
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }
    }

    nonisolated func downloadPartialURL(for descriptor: WhisperModelDescriptor) -> URL {
        modelURL(for: descriptor).appendingPathExtension("download")
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

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    private func contentRangeStarts(at offset: Int64, response: HTTPURLResponse) -> Bool {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else {
            return false
        }
        return value.lowercased().hasPrefix("bytes \(offset)-")
    }

    private func reportProgress(
        _ downloadedBytes: Int64,
        _ expectedTotalBytes: Int64,
        _ progress: @Sendable (Double) -> Void
    ) {
        guard expectedTotalBytes > 0 else { return }
        progress(min(Double(downloadedBytes) / Double(expectedTotalBytes), 0.999))
    }
}

enum WhisperModelManagerError: Error, LocalizedError, Equatable {
    case downloadFailed
    case invalidResumeResponse
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "The Whisper model download failed."
        case .invalidResumeResponse:
            return "The Whisper model server returned an invalid resume response."
        case let .checksumMismatch(expected, actual):
            return "The Whisper model checksum is invalid. Expected \(expected), received \(actual)."
        }
    }
}
