import Foundation
import XCTest
@testable import MeetingScribe

final class StorageGuardTests: XCTestCase {
    func testStorageGuardRejectsCapacityBelowThreshold() throws {
        let guardService = StorageGuard(
            provider: FixedCapacityProvider(capacity: StorageGuard.defaultMinimumBytes - 1),
            minimumBytes: 1
        )

        XCTAssertThrowsError(try guardService.requireCapacity(at: URL(fileURLWithPath: "/tmp"))) {
            XCTAssertEqual(
                $0 as? StorageGuardError,
                .insufficientCapacity(
                    availableBytes: StorageGuard.defaultMinimumBytes - 1,
                    requiredBytes: StorageGuard.defaultMinimumBytes
                )
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
                provider: FixedCapacityProvider(capacity: StorageGuard.defaultMinimumBytes - 1),
                minimumBytes: 1
            )
        )

        do {
            _ = try await manager.startSession(title: "No space")
            XCTFail("Expected recording start to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? StorageGuardError,
                .insufficientCapacity(
                    availableBytes: StorageGuard.defaultMinimumBytes - 1,
                    requiredBytes: StorageGuard.defaultMinimumBytes
                )
            )
        }
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(children.isEmpty)
    }

    @MainActor
    func testApplicationSettingsClampPersistedAndIncomingStorageValuesToOneGiB() {
        let suiteName = "MeetingScribeStorageGuardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ApplicationSettingsStore(defaults: defaults)

        store.setMinimumStorageBytes(1)
        XCTAssertEqual(store.minimumStorageBytes, StorageGuard.defaultMinimumBytes)
    }
}

private struct FixedCapacityProvider: StorageCapacityProviding {
    let capacity: Int64

    func availableCapacity(at url: URL) throws -> Int64 {
        capacity
    }
}
