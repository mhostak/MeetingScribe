import Foundation
import XCTest
@testable import MeetingScribe

final class StorageGuardTests: XCTestCase {
    func testStorageGuardRejectsCapacityBelowThreshold() throws {
        let guardService = StorageGuard(
            provider: FixedCapacityProvider(capacity: 99),
            minimumBytes: 100
        )

        XCTAssertThrowsError(try guardService.requireCapacity(at: URL(fileURLWithPath: "/tmp"))) {
            XCTAssertEqual(
                $0 as? StorageGuardError,
                .insufficientCapacity(availableBytes: 99, requiredBytes: 100)
            )
        }
    }

    func testSessionDoesNotStartWhenStorageIsCriticallyLow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(
                provider: FixedCapacityProvider(capacity: 10),
                minimumBytes: 100
            )
        )

        do {
            _ = try await manager.startSession(title: "No space")
            XCTFail("Expected recording start to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? StorageGuardError,
                .insufficientCapacity(availableBytes: 10, requiredBytes: 100)
            )
        }
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(children.isEmpty)
    }
}

private struct FixedCapacityProvider: StorageCapacityProviding {
    let capacity: Int64

    func availableCapacity(at url: URL) throws -> Int64 {
        capacity
    }
}
