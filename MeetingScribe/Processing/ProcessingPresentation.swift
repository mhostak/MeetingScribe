import Foundation

extension ProcessingJob {
    var displayName: String {
        switch state {
        case .queued: return "Queued"
        case .running: return stage?.displayName ?? "Processing"
        case .pauseRequested: return "Pausing processing"
        case .paused: return "Processing paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var isHeldByScheduler: Bool {
        state == .queued || state == .paused
    }

    /// A queued job stays `.queued` while the scheduler itself is paused, so the
    /// row label has to take the scheduler state into account or the user sees
    /// "Queued" on a queue that will never start on its own.
    func statusLabel(queueStatus: ProcessingQueueStatus?) -> String {
        guard queueStatus?.isPaused == true, isHeldByScheduler else { return displayName }
        return "Processing paused"
    }

    /// The sentence shown with the badge: the job's own failure when it has one,
    /// otherwise the reason the scheduler is holding it. Already localized text,
    /// so views must render it verbatim rather than as a localization key.
    func statusDetail(queueStatus: ProcessingQueueStatus?) -> String? {
        if let failureDescription, !failureDescription.isEmpty { return failureDescription }
        guard isHeldByScheduler else { return nil }
        return queueStatus?.pause?.reason
    }
}
