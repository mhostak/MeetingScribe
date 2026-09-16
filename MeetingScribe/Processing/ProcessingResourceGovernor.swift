import Foundation

/// Inputs collected by the capture and processing coordinators. They stay free
/// of platform observers so the policy can be exercised deterministically.
struct ProcessingResourceSnapshot: Equatable, Sendable {
    enum CaptureLifecycle: Equatable, Sendable {
        case idle
        case preparing
        case recording
        case stopping
    }

    enum MemoryPressure: Equatable, Sendable {
        case normal
        case warning
        case critical
    }

    enum ThermalState: Equatable, Sendable {
        case nominal
        case fair
        case serious
        case critical
    }

    var captureLifecycle: CaptureLifecycle
    var captureIsHealthy: Bool?
    var memoryPressure: MemoryPressure
    var thermalState: ThermalState
    var availableStorageBytes: Int64?

    init(
        captureLifecycle: CaptureLifecycle,
        captureIsHealthy: Bool? = nil,
        memoryPressure: MemoryPressure = .normal,
        thermalState: ThermalState = .nominal,
        availableStorageBytes: Int64? = nil
    ) {
        self.captureLifecycle = captureLifecycle
        self.captureIsHealthy = captureIsHealthy
        self.memoryPressure = memoryPressure
        self.thermalState = thermalState
        self.availableStorageBytes = availableStorageBytes
    }
}

struct ProcessingResourceLimits: Equatable, Sendable {
    /// This is a background-work reserve, separate from the capture start
    /// reserve owned by StorageGuard. Product measurements may tune it later.
    var pauseBelowStorageBytes: Int64
    /// A separate resume threshold prevents disk-space oscillation.
    var resumeAboveStorageBytes: Int64

    init(
        pauseBelowStorageBytes: Int64 = 2 * 1_073_741_824,
        resumeAboveStorageBytes: Int64 = 3 * 1_073_741_824
    ) {
        self.pauseBelowStorageBytes = max(0, pauseBelowStorageBytes)
        self.resumeAboveStorageBytes = max(
            self.pauseBelowStorageBytes,
            resumeAboveStorageBytes
        )
    }
}

enum ProcessingResourceReason: Equatable, Sendable {
    case captureUnhealthy
    case memoryPressure(ProcessingResourceSnapshot.MemoryPressure)
    case thermal(ProcessingResourceSnapshot.ThermalState)
    case storageReserve
}

enum ProcessingResourceDecision: Equatable, Sendable {
    /// The scheduler may start or resume a heavy pipeline stage.
    case allow
    /// Do not start another heavy stage. A running worker has already stopped.
    case hold([ProcessingResourceReason])
    /// Cancel the owned worker, await its exit, release its model, then report
    /// the job paused. This is deliberately distinct from `hold`.
    case cancelRunning([ProcessingResourceReason])
}

/// Stateful, pure policy for the scheduler. It never claims to throttle a GPU
/// or pause a library call; it decides when the scheduler must stop its owned
/// worker and wait for its real termination.
struct ProcessingResourceGovernor: Sendable {
    private let limits: ProcessingResourceLimits
    private var isPausedForResources = false

    init(limits: ProcessingResourceLimits = .init()) {
        self.limits = limits
    }

    mutating func decision(
        for snapshot: ProcessingResourceSnapshot,
        workerIsRunning: Bool
    ) -> ProcessingResourceDecision {
        let reasons = pauseReasons(for: snapshot)
        if !reasons.isEmpty {
            isPausedForResources = true
            return workerIsRunning ? .cancelRunning(reasons) : .hold(reasons)
        }

        guard isPausedForResources else { return .allow }
        guard canResume(after: snapshot) else {
            return .hold([])
        }

        isPausedForResources = false
        return .allow
    }

    private func pauseReasons(
        for snapshot: ProcessingResourceSnapshot
    ) -> [ProcessingResourceReason] {
        var reasons: [ProcessingResourceReason] = []
        if snapshot.captureLifecycle != .idle, snapshot.captureIsHealthy == false {
            reasons.append(.captureUnhealthy)
        }
        if snapshot.memoryPressure != .normal {
            reasons.append(.memoryPressure(snapshot.memoryPressure))
        }
        if snapshot.thermalState == .serious || snapshot.thermalState == .critical {
            reasons.append(.thermal(snapshot.thermalState))
        }
        if let availableStorageBytes = snapshot.availableStorageBytes,
           availableStorageBytes < limits.pauseBelowStorageBytes {
            reasons.append(.storageReserve)
        }
        return reasons
    }

    private func canResume(after snapshot: ProcessingResourceSnapshot) -> Bool {
        guard snapshot.captureLifecycle == .idle || snapshot.captureIsHealthy != false else {
            return false
        }
        guard snapshot.memoryPressure == .normal else { return false }
        guard snapshot.thermalState == .nominal || snapshot.thermalState == .fair else {
            return false
        }
        guard let availableStorageBytes = snapshot.availableStorageBytes else {
            return true
        }
        return availableStorageBytes >= limits.resumeAboveStorageBytes
    }
}
