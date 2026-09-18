import Darwin
import Foundation

struct RecordingOwnershipMarker: Codable, Sendable, Equatable {
    let processID: Int32
    let bootSessionUUID: String
    let claimedAt: Date
    var heartbeatAt: Date
}

enum RecordingOwnershipState: Sendable, Equatable {
    case claimedByThisProcess
    case claimedByAnotherLiveProcess
    case stale
    case unclaimed

    var isLive: Bool {
        self == .claimedByThisProcess || self == .claimedByAnotherLiveProcess
    }
}

struct RecordingOwnership: Sendable {
    static let markerFileName = ".recording-owner"
    static let stalenessWindow: TimeInterval = 90

    private let processID: Int32
    private let clock: @Sendable () -> Date
    private let isProcessAlive: @Sendable (Int32) -> Bool
    private let bootSessionUUID: @Sendable () throws -> String

    init(
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        clock: @escaping @Sendable () -> Date = { Date() },
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { pid in
            guard pid > 0 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        },
        bootSessionUUID: @escaping @Sendable () throws -> String = {
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
                  size > 1 else { throw POSIXError(.EIO) }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
                throw POSIXError(.EIO)
            }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    ) {
        self.processID = processID
        self.clock = clock
        self.isProcessAlive = isProcessAlive
        self.bootSessionUUID = bootSessionUUID
    }

    func read(in directory: URL) throws -> RecordingOwnershipMarker? {
        let url = directory.appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RecordingOwnershipMarker.self, from: Data(contentsOf: url))
    }

    func classification(of directory: URL) -> RecordingOwnershipState {
        let marker: RecordingOwnershipMarker
        do {
            guard let existing = try read(in: directory) else { return .unclaimed }
            marker = existing
        } catch {
            return .stale
        }
        guard let boot = try? bootSessionUUID(), marker.bootSessionUUID == boot,
              marker.processID > 0, isProcessAlive(marker.processID),
              marker.heartbeatAt > clock().addingTimeInterval(-Self.stalenessWindow) else {
            return .stale
        }
        return marker.processID == processID ? .claimedByThisProcess : .claimedByAnotherLiveProcess
    }

    func claim(in directory: URL) throws {
        try withExclusiveAccess(to: directory) {
            guard classification(of: directory) != .claimedByAnotherLiveProcess else {
                throw ProcessingJobRepositoryError.sessionStillRecording(directory.lastPathComponent)
            }
            let now = clock()
            try write(RecordingOwnershipMarker(
                processID: processID,
                bootSessionUUID: try bootSessionUUID(),
                claimedAt: now,
                heartbeatAt: now
            ), in: directory)
        }
    }

    func refresh(in directory: URL) throws {
        try withExclusiveAccess(to: directory) {
            guard var marker = try read(in: directory), marker.processID == processID,
                  marker.bootSessionUUID == (try bootSessionUUID()) else {
                throw ProcessingJobRepositoryError.sessionStillRecording(directory.lastPathComponent)
            }
            marker.heartbeatAt = clock()
            try write(marker, in: directory)
        }
    }

    func release(in directory: URL) throws {
        try withExclusiveAccess(to: directory) {
            guard let marker = try read(in: directory), marker.processID == processID,
                  marker.bootSessionUUID == (try bootSessionUUID()) else { return }
            try FileManager.default.removeItem(at: directory.appendingPathComponent(Self.markerFileName))
        }
    }

    // Lock the stable directory inode because atomic marker rewrites replace the
    // file inode. This also serializes queue admission with a competing claim.
    func withExclusiveAccess<T>(to directory: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func write(_ marker: RecordingOwnershipMarker, in directory: URL) throws {
        try JSONEncoder().encode(marker).write(
            to: directory.appendingPathComponent(Self.markerFileName),
            options: .atomic
        )
    }
}
