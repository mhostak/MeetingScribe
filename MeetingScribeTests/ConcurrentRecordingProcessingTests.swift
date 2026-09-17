import Foundation
import XCTest
@testable import MeetingScribe

@MainActor
final class ConcurrentRecordingProcessingTests: XCTestCase {
    func testStartNewCaptureWhileEveryPreviousProcessingStageIsSuspended() async throws {
        for stage in ProcessingStepID.allCases {
            let fixture = try Fixture(stage: stage)
            defer { fixture.remove() }
            let app = fixture.app
            app.meetingTitle = "A"
            await app.startRecording()
            let a = try XCTUnwrap(app.currentSession)
            await app.stopRecording()
            await fixture.processor.waitForStarts(1)
            XCTAssertTrue(app.canStartRecording)
            app.meetingTitle = "B"
            await app.startRecording()
            let b = try XCTUnwrap(app.currentSession)
            XCTAssertNotEqual(a.metadata.id, b.metadata.id)
            XCTAssertEqual(app.status, .recording)
            await fixture.processor.releaseNext()
            await app.waitForProcessing()
            XCTAssertEqual(app.status, .recording)
            XCTAssertEqual(app.currentSession?.metadata.id, b.metadata.id)
            XCTAssertEqual(app.meetingTitle, "B")
            let storedB = try await fixture.repository.loadSession(id: b.metadata.id)
            XCTAssertEqual(storedB.metadata.status, .recording)
            XCTAssertNil(storedB.metadata.processing)
            await app.stopRecording()
            await fixture.processor.waitForStarts(2)
            await fixture.processor.releaseNext()
            await app.waitForProcessing()
        }
    }

    func testThreeRecordingsUseOneWorkerAndRetainFIFOAfterFailure() async throws {
        let fixture = try Fixture(stage: .transcribing, failFirst: true)
        defer { fixture.remove() }
        let app = fixture.app
        await app.startRecording()
        let a = try XCTUnwrap(app.currentSession)
        await app.stopRecording()
        await fixture.processor.waitForStarts(1)
        await app.stopRecording() // no second enqueue
        await app.startRecording()
        let b = try XCTUnwrap(app.currentSession)
        await app.stopRecording()
        await app.startRecording()
        let c = try XCTUnwrap(app.currentSession)
        let before = await fixture.processor.startedIDs()
        XCTAssertEqual(before, [a.metadata.id])
        let queuedB = try await fixture.repository.loadSession(id: b.metadata.id)
        XCTAssertEqual(queuedB.metadata.processing?.state, .queued)
        await fixture.processor.releaseNext()
        await fixture.processor.waitForStarts(2)
        let after = await fixture.processor.startedIDs()
        XCTAssertEqual(after, [a.metadata.id, b.metadata.id])
        XCTAssertEqual(app.currentSession?.metadata.id, c.metadata.id)
        let storedA = try await fixture.repository.loadSession(id: a.metadata.id)
        XCTAssertEqual(storedA.metadata.processing?.state, .failed)
        await fixture.processor.releaseNext()
        await app.waitForProcessing()
        await app.stopRecording()
        await fixture.processor.waitForStarts(3)
        await fixture.processor.releaseNext()
        await app.waitForProcessing()
        let maximum = await fixture.processor.maximumConcurrency()
        XCTAssertEqual(maximum, 1)
    }

    func testQueueRestoresDurablePendingJobWithoutOccupyingCaptureSlot() async throws {
        let fixture = try Fixture(stage: .exporting)
        defer { fixture.remove() }
        let session = try await fixture.repository.startSession(title: "Persisted")
        let queued = try await fixture.repository.finishCaptureAndQueue(
            expectedSessionID: session.metadata.id, endedAt: Date(), diagnostics: .empty,
            configuration: ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
        )
        let queue = ProcessingQueue(repository: fixture.repository, processor: fixture.processor)
        try await queue.restore()
        await fixture.processor.waitForStarts(1)
        let next = try await fixture.repository.startSession(title: "Next")
        await fixture.processor.releaseNext()
        await queue.waitUntilSettled()
        let active = await fixture.repository.currentSession()
        XCTAssertEqual(active?.metadata.id, next.metadata.id)
        let completed = try await fixture.repository.loadSession(id: queued.metadata.id)
        XCTAssertEqual(completed.metadata.processing?.state, .completed)
    }

    func testCombinedIconKeepsRecordingVisibleWhenBackgroundJobFails() {
        XCTAssertEqual(MenuBarIconState(status: .recording, hasRecovery: false, hasProcessing: true), .recordingAndProcessing)
        XCTAssertEqual(MenuBarIconState(status: .recording, hasRecovery: true, hasProcessingFailures: true), .recording)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let processor: BarrierProcessor
        let repository: SessionManager
        let app: AppState

        init(stage: ProcessingStepID, failFirst: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentTests-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = SessionManager(recordingsRoot: root, storageGuard: StorageGuard(provider: LargeCapacity()))
            processor = BarrierProcessor(stage: stage, failFirst: failFirst)
            app = AppState(sessionManager: repository,
                captureCoordinator: CaptureCoordinator(systemAudioCapture: TestCapture(), microphoneCapture: TestCapture()),
                captureMonitoringConfiguration: CaptureMonitoringConfiguration(interval: .seconds(3600)),
                sessionProcessor: processor, resourceMonitoringEnabled: false)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private struct LargeCapacity: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 { 100_000_000_000 }
}

private actor TestCapture: AudioCaptureService {
    var value = AudioCaptureDiagnostics.empty
    func start(outputURL: URL) async throws {
        value = AudioCaptureDiagnostics(fileName: outputURL.lastPathComponent, startedAt: Date())
        value.registerBuffer(frameCount: 160, sampleRate: 16_000, channelCount: 1, presentationTimestamp: 0)
    }
    func stop() async -> AudioCaptureDiagnostics { value }
    func diagnostics() async -> AudioCaptureDiagnostics { value }
}

private actor BarrierProcessor: SessionProcessing {
    let stage: ProcessingStepID
    let failFirst: Bool
    var ids: [String] = []
    var blocked: [CheckedContinuation<Void, Never>] = []
    var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    var active = 0
    var maximum = 0
    init(stage: ProcessingStepID, failFirst: Bool) { self.stage = stage; self.failFirst = failFirst }
    func process(_ context: SessionProcessingContext,
                 onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void) async throws -> SessionProcessingResult {
        active += 1
        maximum = max(maximum, active)
        defer { active -= 1 }
        let identity = SessionProcessingEventIdentity(sessionID: context.session.metadata.id, jobID: context.jobID, attemptID: context.attemptID)
        try await onEvent(.stageStarted(identity, stage))
        ids.append(context.session.metadata.id)
        let fail = failFirst && ids.count == 1
        await withCheckedContinuation { continuation in
            blocked.append(continuation)
            let ready = observers.filter { $0.0 <= ids.count }
            observers.removeAll { $0.0 <= ids.count }
            for (_, observer) in ready { observer.resume() }
        }
        return SessionProcessingResult(artifacts: ProcessingArtifactMetadata(), failedSteps: fail ? [stage] : [],
            failureDescription: fail ? "Expected test failure" : nil, revision: nil)
    }
    func waitForStarts(_ count: Int) async {
        if ids.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func releaseNext() { if !blocked.isEmpty { blocked.removeFirst().resume() } }
    func startedIDs() -> [String] { ids }
    func maximumConcurrency() -> Int { maximum }
}
