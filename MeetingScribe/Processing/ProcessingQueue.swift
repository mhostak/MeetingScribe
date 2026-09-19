import Foundation

/// Why the scheduler refuses to start queued work. `resource` is re-evaluated on
/// every policy tick, `manual` and `shutdown` are explicit decisions.
enum ProcessingPauseKind: String, Equatable, Sendable {
    case resource
    case manual
    case shutdown
}

/// A queued job keeps its own `.queued` state while the scheduler is paused, so
/// the pause belongs to the scheduler and has to be published separately. Without
/// this the queue looks idle while nothing can start.
struct ProcessingQueuePause: Equatable, Sendable {
    var kind: ProcessingPauseKind
    var reason: String

    init(kind: ProcessingPauseKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

/// Scheduler state independent of any single job.
struct ProcessingQueueStatus: Equatable, Sendable {
    var pause: ProcessingQueuePause?
    var isWorking: Bool
    var queuedCount: Int

    static let idle = ProcessingQueueStatus(pause: nil, isWorking: false, queuedCount: 0)

    init(pause: ProcessingQueuePause? = nil, isWorking: Bool = false, queuedCount: Int = 0) {
        self.pause = pause
        self.isWorking = isWorking
        self.queuedCount = queuedCount
    }

    var isPausedForResources: Bool { pause?.kind == .resource }
    var isPaused: Bool { pause != nil }
}

/// The only owner of the processing slot. A slot remains reserved across every await,
/// including cancellation, resource release, checkpoint persistence and notifications.
actor ProcessingQueue {
    typealias ChangeHandler = @Sendable ([RecordingSession], ProcessingQueueStatus) async -> Void
    typealias CompletionHandler = @Sendable (RecordingSession, SessionProcessingResult?) async -> Void

    private let repository: SessionManager
    private let processor: any SessionProcessing
    private var sessions: [String: RecordingSession] = [:]
    private var worker: Task<Void, Never>?
    private var workerIdentity: SessionProcessingEventIdentity?
    private var activePause: ProcessingQueuePause?
    private var shuttingDown = false
    private var hasRestored = false
    private var acceptVersions: [String: UUID] = [:]
    private let logger = ProcessingLogger()
    private var onChange: ChangeHandler = { _, _ in }
    private var onCompletion: CompletionHandler = { _, _ in }
    private var waiters: [UUID: [UUID: CheckedContinuation<SessionProcessingResult, Error>]] = [:]
    private var results: [UUID: Result<SessionProcessingResult, Error>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(repository: SessionManager, processor: any SessionProcessing) {
        self.repository = repository
        self.processor = processor
    }

    func observe(onChange: @escaping ChangeHandler, onCompletion: @escaping CompletionHandler) async {
        self.onChange = onChange
        self.onCompletion = onCompletion
        await publish()
    }

    func restore() async throws {
        guard !hasRestored else { return }
        let persistedSessions = try await repository.loadProcessingSessions()
        for var session in persistedSessions {
            guard let job = session.metadata.processing, job.schemaVersion == 1 else { continue }
            if job.state == .running || job.state == .pauseRequested || job.state == .paused {
                session = try await repository.resumeInterruptedProcessing(
                    sessionID: session.metadata.id, jobID: job.jobID, attemptID: job.attemptID
                )
            }
            sessions[session.metadata.id] = session
        }
        hasRestored = true
        await publish()
        schedule()
    }

    /// The caller persists enqueue atomically before handing it to the scheduler.
    func accept(_ session: RecordingSession) async {
        guard let job = session.metadata.processing, job.schemaVersion == 1 else { return }
        let version = UUID()
        acceptVersions[session.metadata.id] = version
        guard let persisted = try? await repository.loadSession(id: session.metadata.id),
              persisted.metadata.processing?.jobID == job.jobID,
              persisted.metadata.processing?.attemptID == job.attemptID,
              acceptVersions[session.metadata.id] == version else { return }
        let oldJob = sessions[session.metadata.id]?.metadata.processing
        if let oldJob, oldJob.attemptID == job.attemptID, oldJob.state != .queued { return }
        sessions[session.metadata.id] = persisted
        await publish()
        schedule()
    }

    /// Drops a settled job whose recording no longer exists on disk. Without
    /// this the queue keeps republishing the deleted session, so a failed job
    /// would keep asking the menu bar for attention forever. A job that can
    /// still run is left alone; the caller refuses to delete in that case.
    func forget(sessionID: String) async {
        guard sessions[sessionID]?.metadata.processing?.state.isTerminal == true else { return }
        sessions.removeValue(forKey: sessionID)
        acceptVersions.removeValue(forKey: sessionID)
        await publish()
    }

    func result(for attemptID: UUID) async throws -> SessionProcessingResult {
        try Task.checkCancellation()
        if let result = results[attemptID] { return try result.get() }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[attemptID, default: [:]][waiterID] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(attemptID: attemptID, waiterID: waiterID) }
        }
    }

    private func cancelWaiter(attemptID: UUID, waiterID: UUID) {
        waiters[attemptID]?.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    /// Test/integration barrier; stopping capture never waits for this.
    func waitUntilSettled() async {
        if worker == nil && (activePause != nil || !sessions.values.contains(where: { $0.metadata.processing?.state == .queued })) { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The scheduler's published pause, so callers never have to mirror it.
    func status() -> ProcessingQueueStatus { currentStatus() }

    func pause(reason: String, kind: ProcessingPauseKind = .resource) async {
        // A shutdown pause outranks every other reason and must not be relabelled.
        guard activePause?.kind != .shutdown || kind == .shutdown else { return }
        activePause = ProcessingQueuePause(kind: kind, reason: reason)
        if let identity = workerIdentity {
            do {
                let updated = try await repository.updateProcessing(
                    sessionID: identity.sessionID, jobID: identity.jobID, attemptID: identity.attemptID,
                    patch: ProcessingJobPatch(state: .pauseRequested, failureDescription: reason)
                )
                // Do not replace a newer terminal/paused snapshot after actor reentrancy.
                if workerIdentity == identity { sessions[identity.sessionID] = updated }
            } catch { /* Worker will surface persistence errors when it settles. */ }
            if workerIdentity == identity { worker?.cancel() }
        }
        await publish()
    }

    /// Throwing leaves the pause in place on purpose: the caller keeps seeing a
    /// paused queue and can retry instead of losing the request.
    func resume() async throws {
        guard !shuttingDown else { return }
        let previousPause = activePause
        activePause = nil
        do { try await requeuePausedJobs() }
        catch {
            activePause = previousPause
            await publish()
            throw error
        }
        await publish()
        schedule()
    }

    private func requeuePausedJobs() async throws {
        for session in sortedSessions() {
            guard let job = session.metadata.processing, job.state == .paused else { continue }
            let updated = try await repository.updateProcessing(
                sessionID: session.metadata.id, jobID: job.jobID, attemptID: job.attemptID,
                patch: ProcessingJobPatch(state: .queued, updatesFailureDescription: true)
            )
            sessions[session.metadata.id] = updated
        }
    }

    func shutdown() async {
        shuttingDown = true
        await pause(reason: "Application is closing", kind: .shutdown)
        let running = worker
        await running?.value
    }

    /// The system can cancel a termination it already asked us to prepare for.
    /// Without this the scheduler would stay dead for the rest of the process.
    func cancelShutdown() async throws {
        guard shuttingDown else { return }
        shuttingDown = false
        guard activePause?.kind == .shutdown else {
            await publish()
            return
        }
        try await resume()
    }

    private func schedule() {
        guard worker == nil, activePause == nil, !shuttingDown,
              let session = sortedSessions().first(where: { $0.metadata.processing?.state == .queued }),
              let job = session.metadata.processing else {
            resolveIdleWaitersIfNeeded()
            return
        }
        let identity = SessionProcessingEventIdentity(sessionID: session.metadata.id, jobID: job.jobID, attemptID: job.attemptID)
        workerIdentity = identity
        worker = Task(priority: .utility) { await self.run(session, identity: identity) }
    }

    private func run(_ initialSession: RecordingSession, identity: SessionProcessingEventIdentity) async {
        var outcome: SessionProcessingResult?
        var terminalSession: RecordingSession?
        var terminalResolution: Result<SessionProcessingResult, Error>?
        do {
            try Task.checkCancellation()
            let session = try await repository.updateProcessing(
                sessionID: identity.sessionID, jobID: identity.jobID, attemptID: identity.attemptID,
                patch: ProcessingJobPatch(state: .running)
            )
            sessions[identity.sessionID] = session
            await publish()
            try Task.checkCancellation()
            let job = session.metadata.processing!
            if job.kind == .recovery { try? await logger.log(.recoveryStarted, for: session) }
            let diagnostics = Self.diagnostics(for: session)
            let context = SessionProcessingContext(
                session: session, jobID: identity.jobID, attemptID: identity.attemptID,
                kind: job.kind, configuration: job.configuration, diagnostics: diagnostics,
                endedAt: session.metadata.endedAt ?? session.metadata.startedAt ?? session.metadata.createdAt
            )
            let result = try await processor.process(context) { [weak self] event in
                guard let self else { throw CancellationError() }
                try await self.receive(event, expected: identity)
            }
            try Task.checkCancellation()
            let completed = try await repository.completeProcessing(
                sessionID: identity.sessionID, jobID: identity.jobID, attemptID: identity.attemptID,
                artifactMetadata: result.artifacts, failureDescription: result.failureDescription,
                failedSteps: Set(result.failedSteps)
            )
            sessions[identity.sessionID] = completed
            outcome = result
            terminalSession = completed
            terminalResolution = .success(result)
            if completed.metadata.recovery?.status == .completed {
                try? await logger.log(.recoveryCompleted, for: completed)
            }
        } catch is CancellationError {
            do {
                let paused = try await repository.updateProcessing(
                    sessionID: identity.sessionID, jobID: identity.jobID, attemptID: identity.attemptID,
                    patch: ProcessingJobPatch(state: .paused, failureDescription: activePause?.reason ?? "Processing paused")
                )
                sessions[identity.sessionID] = paused
            } catch {
                await recordFailure(error, identity: identity)
                terminalSession = sessions[identity.sessionID]
                terminalResolution = .failure(error)
            }
        } catch {
            await recordFailure(error, identity: identity)
            terminalSession = sessions[identity.sessionID]
            terminalResolution = .failure(error)
        }
        await publish()
        if let terminalSession { await onCompletion(terminalSession, outcome) }
        if let terminalResolution { resolve(identity.attemptID, with: terminalResolution) }
        // Keep the slot occupied until all completion side effects are finished.
        worker = nil
        workerIdentity = nil
        if activePause == nil, !shuttingDown,
           let session = sessions[identity.sessionID], session.metadata.processing?.state == .paused {
            do { try await resume() } catch { await recordFailure(error, identity: identity) }
        }
        schedule()
    }

    private func receive(_ event: SessionProcessingEvent, expected identity: SessionProcessingEventIdentity) async throws {
        try Task.checkCancellation()
        guard workerIdentity == identity, activePause == nil else { throw CancellationError() }
        let patch: ProcessingJobPatch
        var artifacts: ProcessingArtifactMetadata?
        switch event {
        case let .stageStarted(eventIdentity, stage):
            guard eventIdentity == identity else { throw CancellationError() }
            patch = ProcessingJobPatch(state: .running, stage: stage)
        case let .checkpoint(checkpoint):
            guard checkpoint.identity == identity else { throw CancellationError() }
            patch = ProcessingJobPatch(checkpoint: checkpoint.stage)
            artifacts = checkpoint.artifacts
        case let .stageSkipped(eventIdentity, _):
            guard eventIdentity == identity else { throw CancellationError() }
            return
        case let .stageFailed(eventIdentity, stage, message):
            guard eventIdentity == identity else { throw CancellationError() }
            patch = ProcessingJobPatch(stage: stage, failureDescription: message)
        }
        let updated = try await repository.updateProcessing(
            sessionID: identity.sessionID, jobID: identity.jobID, attemptID: identity.attemptID,
            patch: patch, artifactMetadata: artifacts
        )
        sessions[identity.sessionID] = updated
        await publish()
        try Task.checkCancellation()
    }

    private func recordFailure(_ error: Error, identity: SessionProcessingEventIdentity) async {
        do {
            let failed = try await repository.completeProcessing(
                sessionID: identity.sessionID, jobID: identity.jobID, attemptID: identity.attemptID,
                artifactMetadata: ProcessingArtifactMetadata(), failureDescription: error.localizedDescription,
                failedSteps: [sessions[identity.sessionID]?.metadata.processing?.stage ?? .preparingAudio]
            )
            sessions[identity.sessionID] = failed
        } catch {
            // Keep durable work recoverable and expose the persistence failure in-memory.
            if let latest = try? await repository.loadSession(id: identity.sessionID),
               latest.metadata.processing?.attemptID != identity.attemptID
                || latest.metadata.processing?.state.isTerminal == true {
                sessions[identity.sessionID] = latest
                return
            }
            if var session = sessions[identity.sessionID], session.metadata.processing?.attemptID == identity.attemptID {
                session.metadata.processing?.state = .failed
                session.metadata.processing?.failureDescription = error.localizedDescription
                sessions[identity.sessionID] = session
            }
        }
    }

    private func resolve(_ attemptID: UUID, with result: Result<SessionProcessingResult, Error>) {
        results[attemptID] = result
        for continuation in (waiters.removeValue(forKey: attemptID) ?? [:]).values { continuation.resume(with: result) }
    }

    private func sortedSessions() -> [RecordingSession] {
        sessions.values.sorted {
            let lhs = $0.metadata.processing!, rhs = $1.metadata.processing!
            if lhs.enqueuedAt == rhs.enqueuedAt { return lhs.jobID.uuidString < rhs.jobID.uuidString }
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
    }

    private func currentStatus() -> ProcessingQueueStatus {
        ProcessingQueueStatus(
            pause: activePause,
            isWorking: worker != nil,
            queuedCount: sessions.values.filter { $0.metadata.processing?.state == .queued }.count
        )
    }

    private func publish() async { await onChange(sortedSessions(), currentStatus()) }

    private func resolveIdleWaitersIfNeeded() {
        guard worker == nil,
              activePause != nil || !sessions.values.contains(where: { $0.metadata.processing?.state == .queued }) else { return }
        for continuation in idleWaiters { continuation.resume() }
        idleWaiters.removeAll()
    }

    private static func diagnostics(for session: RecordingSession) -> CaptureSessionDiagnostics {
        func track(_ metadata: AudioTrackMetadata?) -> AudioCaptureDiagnostics {
            guard let metadata else { return .empty }
            return AudioCaptureDiagnostics(
                fileName: metadata.fileName, bufferCount: metadata.bufferCount, totalFrames: metadata.totalFrames,
                sampleRate: metadata.sampleRate, channelCount: metadata.channelCount,
                firstPresentationTimestamp: metadata.firstPresentationTimestamp,
                lastPresentationTimestamp: metadata.lastPresentationTimestamp,
                lastBufferDurationSeconds: nil, failureReason: metadata.failureReason
            )
        }
        return CaptureSessionDiagnostics(systemAudio: track(session.metadata.systemAudio), microphone: track(session.metadata.microphoneAudio))
    }
}
