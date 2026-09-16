import Foundation
import XCTest
@testable import MeetingScribe

final class ProcessingQueueTests: XCTestCase {
    private var root: URL!
    private var repository: SessionManager!
    private var processor: QueueBarrierProcessor!
    private var queue: ProcessingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessingQueueTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(provider: QueueTestCapacity())
        )
        processor = QueueBarrierProcessor()
        queue = ProcessingQueue(repository: repository, processor: processor)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        queue = nil
        processor = nil
        repository = nil
        root = nil
    }

    func testFIFOUsesOneWorkerAndDuplicateAcceptStartsOnlyOnce() async throws {
        let first = try await enqueue(title: "First", at: 100)
        await queue.accept(first)
        await queue.accept(first)
        await processor.waitForStarts(1)

        let second = try await enqueue(title: "Second", at: 200)
        let third = try await enqueue(title: "Third", at: 300)
        await queue.accept(second)
        await queue.accept(third)

        let initiallyStarted = await processor.startedSessionIDs()
        XCTAssertEqual(initiallyStarted, [first.metadata.id])
        await processor.releaseNext()
        await processor.waitForStarts(2)
        let afterSecond = await processor.startedSessionIDs()
        XCTAssertEqual(afterSecond, [first.metadata.id, second.metadata.id])

        await processor.releaseNext()
        await processor.waitForStarts(3)
        let afterThird = await processor.startedSessionIDs()
        XCTAssertEqual(afterThird, [first.metadata.id, second.metadata.id, third.metadata.id])
        await processor.releaseNext()
        await queue.waitUntilSettled()

        let maximumConcurrency = await processor.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)
        let completedFirst = try await repository.loadSession(id: first.metadata.id)
        XCTAssertEqual(completedFirst.metadata.processing?.state, .completed)
        let completedSecond = try await repository.loadSession(id: second.metadata.id)
        XCTAssertEqual(completedSecond.metadata.processing?.state, .completed)
        let completedThird = try await repository.loadSession(id: third.metadata.id)
        XCTAssertEqual(completedThird.metadata.processing?.state, .completed)
    }

    func testPauseWaitsForCooperativeCleanupThenResumeUsesSameQueuedJob() async throws {
        let session = try await enqueue(title: "Pause", at: 100)
        let originalJob = try XCTUnwrap(session.metadata.processing)
        await queue.accept(session)
        await processor.waitForStarts(1)

        await queue.pause(reason: "Memory pressure")
        await processor.waitForCleanups(1)
        await queue.waitUntilSettled()

        let paused = try await repository.loadSession(id: session.metadata.id)
        XCTAssertEqual(paused.metadata.processing?.state, .paused)
        XCTAssertEqual(paused.metadata.processing?.jobID, originalJob.jobID)
        let activeCount = await processor.activeCount()
        XCTAssertEqual(activeCount, 0)

        try await queue.resume()
        await processor.waitForStarts(2)
        await processor.releaseNext()
        await queue.waitUntilSettled()

        let completed = try await repository.loadSession(id: session.metadata.id)
        XCTAssertEqual(completed.metadata.processing?.state, .completed)
        XCTAssertEqual(completed.metadata.processing?.jobID, originalJob.jobID)
        let maximumConcurrency = await processor.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testRestoreDoesNotRunFutureSchemaJobAndSurfacesRecoveryIssue() async throws {
        let session = try await enqueue(title: "Future schema", at: 100)
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: session.manifestURL)) as? [String: Any]
        )
        var processing = try XCTUnwrap(document["processing"] as? [String: Any])
        processing["schemaVersion"] = ProcessingJob.currentSchemaVersion + 1
        document["processing"] = processing
        try JSONSerialization.data(withJSONObject: document).write(to: session.manifestURL, options: .atomic)

        try await queue.restore()
        let started = await processor.startedSessionIDs()
        XCTAssertEqual(started, [])
        let issues = try await repository.scanForRecovery().issues
        XCTAssertTrue(issues.contains { $0.directoryName == session.metadata.id })
    }

    private func enqueue(title: String, at timestamp: TimeInterval) async throws -> RecordingSession {
        let now = Date(timeIntervalSince1970: timestamp)
        let session = try await repository.startSession(title: title, now: now)
        return try await repository.finishCaptureAndQueue(
            expectedSessionID: session.metadata.id,
            endedAt: now.addingTimeInterval(1),
            diagnostics: .empty,
            configuration: ProcessingJobConfiguration(
                outputDirectoryURL: nil,
                automaticallyDeleteSourceCAF: false
            ),
            now: now.addingTimeInterval(2)
        )
    }
}

private struct QueueTestCapacity: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 { 100_000_000_000 }
}

private actor QueueBarrierProcessor: SessionProcessing {
    private var started: [String] = []
    private var active = 0
    private var maximum = 0
    private var gates: [String: CheckedContinuation<Void, Error>] = [:]
    private var cancellationRequests: Set<String> = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cleanupCount = 0
    private var cleanupWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func process(
        _ context: SessionProcessingContext,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> SessionProcessingResult {
        let sessionID = context.session.metadata.id
        active += 1
        maximum = max(maximum, active)
        defer {
            active -= 1
            cleanupCount += 1
            resumeCleanupWaiters()
        }

        let identity = SessionProcessingEventIdentity(
            sessionID: sessionID,
            jobID: context.jobID,
            attemptID: context.attemptID
        )
        try await onEvent(.stageStarted(identity, .transcribing))
        started.append(sessionID)
        resumeStartWaiters()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancellationRequests.remove(sessionID) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    gates[sessionID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(sessionID: sessionID) }
        }
        try Task.checkCancellation()
        return SessionProcessingResult(
            artifacts: ProcessingArtifactMetadata(),
            failedSteps: [],
            failureDescription: nil,
            revision: nil
        )
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func waitForCleanups(_ count: Int) async {
        guard cleanupCount < count else { return }
        await withCheckedContinuation { cleanupWaiters.append((count, $0)) }
    }

    func releaseNext() {
        guard let id = gates.keys.sorted().first,
              let gate = gates.removeValue(forKey: id) else { return }
        gate.resume()
    }

    func startedSessionIDs() -> [String] { started }
    func activeCount() -> Int { active }
    func maximumConcurrency() -> Int { maximum }

    private func cancel(sessionID: String) {
        if let gate = gates.removeValue(forKey: sessionID) {
            gate.resume(throwing: CancellationError())
        } else {
            cancellationRequests.insert(sessionID)
        }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { $0.0 <= started.count }
        startWaiters.removeAll { $0.0 <= started.count }
        for (_, continuation) in ready { continuation.resume() }
    }

    private func resumeCleanupWaiters() {
        let ready = cleanupWaiters.filter { $0.0 <= cleanupCount }
        cleanupWaiters.removeAll { $0.0 <= cleanupCount }
        for (_, continuation) in ready { continuation.resume() }
    }
}
