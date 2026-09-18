import Foundation
import XCTest
@testable import MeetingScribe

final class RecordingOwnershipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ownership(pid: Int32 = 100, alive: Bool = true, age: TimeInterval = 0, boot: String = "boot") -> RecordingOwnership {
        let date = now.addingTimeInterval(age)
        return RecordingOwnership(
            processID: pid,
            clock: { date },
            isProcessAlive: { _ in alive },
            bootSessionUUID: { boot }
        )
    }

    private func makeSession(in root: URL) throws -> RecordingSession {
        let directory = root.appendingPathComponent("recording", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = RecordingSession(
            metadata: SessionMetadata(id: "recording", title: "Recording", status: .recording, createdAt: now),
            directoryURL: directory
        )
        try SessionJSONCoder.makeEncoder().encode(session.metadata).write(to: session.manifestURL)
        try Data("audio".utf8).write(to: session.systemAudioURL)
        return session
    }

    func testClaimRefreshAndReleaseRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let owner = ownership()
        XCTAssertEqual(owner.classification(of: session.directoryURL), .unclaimed)
        try owner.claim(in: session.directoryURL)
        XCTAssertEqual(owner.classification(of: session.directoryURL), .claimedByThisProcess)
        let original = try XCTUnwrap(owner.read(in: session.directoryURL))
        try ownership(age: 15).refresh(in: session.directoryURL)
        let refreshed = try XCTUnwrap(owner.read(in: session.directoryURL))
        XCTAssertEqual(refreshed.claimedAt, original.claimedAt)
        XCTAssertEqual(refreshed.heartbeatAt, now.addingTimeInterval(15))
        try owner.release(in: session.directoryURL)
        XCTAssertNil(try owner.read(in: session.directoryURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directoryURL.appendingPathComponent(RecordingOwnership.markerFileName).path))
    }

    func testLiveForeignClaimSuppressesCandidateAndIssue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try ownership(pid: 200).claim(in: session.directoryURL)
        let observer = ownership()
        let scanner = SessionRecoveryScanner(ownership: observer)
        XCTAssertEqual(observer.classification(of: session.directoryURL), .claimedByAnotherLiveProcess)
        XCTAssertTrue(scanner.scan(recordingsRoot: root).candidates.isEmpty)
        XCTAssertNil(scanner.candidate(recordingsRoot: root, id: session.metadata.id))
        try FileManager.default.removeItem(at: session.manifestURL)
        XCTAssertTrue(scanner.scan(recordingsRoot: root).issues.isEmpty)
        XCTAssertNil(scanner.issue(recordingsRoot: root, directoryName: session.metadata.id))
        XCTAssertThrowsError(try observer.claim(in: session.directoryURL))
        try observer.release(in: session.directoryURL)
        XCTAssertNotNil(try observer.read(in: session.directoryURL))
    }

    func testStaleAndUnclaimedRecordingsRemainRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        XCTAssertNotNil(SessionRecoveryScanner(ownership: ownership()).candidate(recordingsRoot: root, id: session.metadata.id))
        try ownership(pid: 200).claim(in: session.directoryURL)
        for observer in [ownership(alive: false), ownership(age: 90), ownership(age: 91), ownership(boot: "next-boot")] {
            XCTAssertEqual(observer.classification(of: session.directoryURL), .stale)
            let scanner = SessionRecoveryScanner(ownership: observer)
            XCTAssertNotNil(scanner.candidate(recordingsRoot: root, id: session.metadata.id))
            XCTAssertEqual(scanner.scan(recordingsRoot: root).candidates.count, 1)
        }
        XCTAssertEqual(ownership(age: 89).classification(of: session.directoryURL), .claimedByAnotherLiveProcess)
    }

    func testManagerRejectsForeignRecoveryWithoutChangingManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try ownership(pid: 200).claim(in: session.directoryURL)
        let original = try Data(contentsOf: session.manifestURL)
        let manager = SessionManager(recordingsRoot: root, ownership: ownership())
        let scan = try await manager.scanForRecovery()
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.issues.isEmpty)
        let detectionRecorded = try await manager.recordRecoveryDetection(id: session.metadata.id)
        XCTAssertFalse(detectionRecorded)
        do {
            _ = try await manager.queueProcessing(
                sessionID: session.metadata.id,
                kind: .recovery,
                configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
            )
            XCTFail("Live recordings must not enter processing.")
        } catch let error as ProcessingJobRepositoryError {
            XCTAssertEqual(error, .sessionStillRecording(session.metadata.id))
        }
        do {
            _ = try await manager.beginRecovery(id: session.metadata.id)
            XCTFail("Live recordings must not enter recovery.")
        } catch is SessionRecoveryError {
            // The scanner deliberately hides live owners from candidate lookup.
        }
        XCTAssertEqual(try Data(contentsOf: session.manifestURL), original)
    }

    func testNewCaptureClaimsAndHandoffReleasesOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ownership()
        let manager = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: OwnershipCapacityProvider()),
            ownership: owner
        )
        let session = try await manager.startSession(title: "Capture")
        XCTAssertEqual(owner.classification(of: session.directoryURL), .claimedByThisProcess)
        _ = try await manager.finishCaptureAndQueue(
            expectedSessionID: session.metadata.id,
            endedAt: now,
            diagnostics: .empty,
            configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
        )
        XCTAssertNil(try owner.read(in: session.directoryURL))
        let active = await manager.currentSession()
        XCTAssertNil(active)
    }

    func testEndingCaptureCompletesWhenOwnershipCannotBeReleased() async throws {
        for ending in ["stop", "handoff", "failure"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = ownership()
            let manager = SessionManager(
                recordingsRoot: root,
                storageGuard: StorageGuard(provider: OwnershipCapacityProvider()),
                ownership: owner
            )
            let session = try await manager.startSession(title: "Capture")
            let markerURL = session.directoryURL.appendingPathComponent(RecordingOwnership.markerFileName)
            try Data("unreadable marker".utf8).write(to: markerURL)
            XCTAssertThrowsError(try owner.release(in: session.directoryURL))

            let ended: RecordingSession
            switch ending {
            case "stop":
                ended = try await manager.stopSession()
            case "handoff":
                ended = try await manager.finishCaptureAndQueue(
                    expectedSessionID: session.metadata.id,
                    endedAt: now,
                    diagnostics: .empty,
                    configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
                )
            default:
                ended = try await manager.failSession(reason: "Capture failed")
            }
            XCTAssertEqual(ended.metadata.status, ending == "failure" ? .failed : .recorded)
            let persisted = try await manager.loadSession(id: session.metadata.id)
            XCTAssertEqual(persisted.metadata.status, ended.metadata.status)
            let active = await manager.currentSession()
            XCTAssertNil(active)
            XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
            _ = try await manager.startSession(title: "Next capture", now: now.addingTimeInterval(60))
            _ = try await manager.stopSession()
        }
    }

    func testActiveSessionCanReclaimMissingMarkerAfterRefreshFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let owner = ownership()
        let manager = SessionManager(recordingsRoot: root, ownership: owner)
        _ = try await manager.beginRecovery(id: session.metadata.id)
        try owner.release(in: session.directoryURL)
        do {
            try await manager.refreshRecordingOwnership()
            XCTFail("A missing marker must trigger a reclaim attempt.")
        } catch {}
        try await manager.reclaimRecordingOwnership()
        XCTAssertEqual(owner.classification(of: session.directoryURL), .claimedByThisProcess)
        let active = await manager.currentSession()
        XCTAssertEqual(active?.metadata.status, .recording)
        _ = try await manager.stopSession()
    }

    func testRecoveryReleasesOwnershipOnStopAndFailure() async throws {
        for fail in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try makeSession(in: root)
            let owner = ownership()
            let manager = SessionManager(recordingsRoot: root, ownership: owner)
            _ = try await manager.beginRecovery(id: session.metadata.id)
            XCTAssertEqual(owner.classification(of: session.directoryURL), .claimedByThisProcess)
            try await manager.refreshRecordingOwnership()
            if fail {
                _ = try await manager.failSession(reason: "Capture failed")
            } else {
                _ = try await manager.stopSession()
            }
            XCTAssertNil(try owner.read(in: session.directoryURL))
        }
    }
}

private struct OwnershipCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 { Int64.max }
}
