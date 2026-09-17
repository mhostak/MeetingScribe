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

    /// Background work must never keep writing below the reserve that capture
    /// itself refuses to start on. The background reserve stays a distinct value
    /// and keeps its hysteresis gap, it is only raised to respect that floor.
    static func backgroundReserve(
        captureMinimumBytes: Int64,
        defaults: ProcessingResourceLimits = ProcessingResourceLimits()
    ) -> ProcessingResourceLimits {
        let pauseBelow = max(defaults.pauseBelowStorageBytes, captureMinimumBytes)
        let gap = max(
            defaults.resumeAboveStorageBytes - defaults.pauseBelowStorageBytes,
            1_073_741_824
        )
        return ProcessingResourceLimits(
            pauseBelowStorageBytes: pauseBelow,
            resumeAboveStorageBytes: pauseBelow + gap
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
        // Reporting the unmet resume conditions instead of an empty list is what
        // makes an indefinite hold explainable to the user.
        let blockers = resumeBlockers(for: snapshot)
        guard blockers.isEmpty else { return .hold(blockers) }

        isPausedForResources = false
        return .allow
    }

    private func pauseReasons(
        for snapshot: ProcessingResourceSnapshot
    ) -> [ProcessingResourceReason] {
        reasons(for: snapshot, storageThreshold: limits.pauseBelowStorageBytes)
    }

    /// Storage uses the higher resume threshold so free space cannot oscillate
    /// around a single boundary. The other inputs are already complementary.
    private func resumeBlockers(
        for snapshot: ProcessingResourceSnapshot
    ) -> [ProcessingResourceReason] {
        reasons(for: snapshot, storageThreshold: limits.resumeAboveStorageBytes)
    }

    private func reasons(
        for snapshot: ProcessingResourceSnapshot,
        storageThreshold: Int64
    ) -> [ProcessingResourceReason] {
        var reasons: [ProcessingResourceReason] = []
        if snapshot.captureLifecycle != .idle, snapshot.captureIsHealthy == false {
            reasons.append(.captureUnhealthy)
        }
        // `warning` memory pressure and `serious` thermal state are ordinary
        // steady states on a passively cooled Mac with unified memory — a
        // MacBook Air sits at pressure level 2 with a third of its memory free.
        // Treating them as a reason to stop meant background work never ran at
        // all. They withhold work only while a capture is in flight, which is
        // what the invariant actually protects. Only the critical levels, where
        // the system itself is about to intervene, stop work unconditionally.
        switch snapshot.memoryPressure {
        case .critical:
            reasons.append(.memoryPressure(.critical))
        case .warning where snapshot.captureLifecycle != .idle:
            reasons.append(.memoryPressure(.warning))
        case .warning, .normal:
            break
        }
        switch snapshot.thermalState {
        case .critical:
            reasons.append(.thermal(.critical))
        case .serious where snapshot.captureLifecycle != .idle:
            reasons.append(.thermal(.serious))
        case .serious, .fair, .nominal:
            break
        }
        if let availableStorageBytes = snapshot.availableStorageBytes,
           availableStorageBytes < storageThreshold {
            reasons.append(.storageReserve)
        }
        return reasons
    }
}
