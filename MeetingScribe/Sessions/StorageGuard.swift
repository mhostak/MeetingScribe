import Foundation

protocol StorageCapacityProviding: Sendable {
    func availableCapacity(at url: URL) throws -> Int64
}

struct VolumeStorageCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw StorageGuardError.capacityUnavailable
        }
        return capacity
    }
}

struct StorageStatus: Equatable, Sendable {
    let availableBytes: Int64
    let requiredBytes: Int64

    var hasSufficientCapacity: Bool {
        availableBytes >= requiredBytes
    }
}

struct StorageGuard: Sendable {
    static let defaultMinimumBytes: Int64 = 1_073_741_824

    private let provider: any StorageCapacityProviding
    let minimumBytes: Int64

    init(
        provider: any StorageCapacityProviding = VolumeStorageCapacityProvider(),
        minimumBytes: Int64 = StorageGuard.defaultMinimumBytes
    ) {
        self.provider = provider
        self.minimumBytes = max(1, minimumBytes)
    }

    func status(at url: URL) throws -> StorageStatus {
        StorageStatus(
            availableBytes: try provider.availableCapacity(at: url),
            requiredBytes: minimumBytes
        )
    }

    func requireCapacity(at url: URL) throws {
        let status = try status(at: url)
        guard status.hasSufficientCapacity else {
            throw StorageGuardError.insufficientCapacity(
                availableBytes: status.availableBytes,
                requiredBytes: status.requiredBytes
            )
        }
    }

    func withMinimumBytes(_ bytes: Int64) -> StorageGuard {
        StorageGuard(provider: provider, minimumBytes: bytes)
    }
}

enum StorageGuardError: Error, Equatable, LocalizedError {
    case capacityUnavailable
    case insufficientCapacity(availableBytes: Int64, requiredBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .capacityUnavailable:
            return "MeetingScribe could not determine the available recording storage."
        case let .insufficientCapacity(availableBytes, requiredBytes):
            let available = ByteCountFormatter.string(
                fromByteCount: availableBytes,
                countStyle: .file
            )
            let required = ByteCountFormatter.string(
                fromByteCount: requiredBytes,
                countStyle: .file
            )
            return "Not enough free space to record safely. Available: \(available); required: \(required)."
        }
    }
}
