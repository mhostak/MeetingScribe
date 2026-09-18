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

/// Where one processing attempt stands in its own pipeline, for the stage bar
/// in the menu bar popover.
struct ProcessingStageProgress: Equatable, Sendable {
    let steps: [ProcessingStepID]
    let completedCount: Int
    let activeIndex: Int?
    let failedIndex: Int?

    /// The 1-based number of the step the attempt is on, or nil while nothing
    /// is running.
    var currentStepNumber: Int? {
        (activeIndex ?? failedIndex).map { $0 + 1 }
    }

    var isInFlight: Bool {
        activeIndex != nil || failedIndex != nil
    }
}

extension ProcessingJob {
    /// The steps this attempt actually runs. A retranscription never analyzes
    /// and a reanalysis never touches audio, so a fixed four-step bar would
    /// promise work that is not going to happen.
    func plannedSteps(analysisConfigured: Bool) -> [ProcessingStepID] {
        switch kind {
        case .initial, .recovery:
            return analysisConfigured
                ? [.preparingAudio, .transcribing, .analyzing, .exporting]
                : [.preparingAudio, .transcribing, .exporting]
        case .retranscribe:
            return [.preparingAudio, .transcribing, .exporting]
        case .reanalyze:
            return [.analyzing, .exporting]
        }
    }

    /// `checkpoint` is committed after a step finishes and `stage` is the step
    /// in flight, so completion comes from one and the active segment from the
    /// other. A retranscription checkpoints only at the very end, so anything
    /// before the running step counts as done as well.
    func stageProgress(analysisConfigured: Bool) -> ProcessingStageProgress {
        let steps = plannedSteps(analysisConfigured: analysisConfigured)
        let stageIndex = stage.flatMap { steps.firstIndex(of: $0) }
        let activeIndex = (state == .running || state == .pauseRequested) ? stageIndex : nil
        let failedIndex = state == .failed ? stageIndex : nil
        let checkpointCount = checkpoint
            .flatMap { steps.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        return ProcessingStageProgress(
            steps: steps,
            completedCount: max(checkpointCount, activeIndex ?? failedIndex ?? checkpointCount),
            activeIndex: activeIndex,
            failedIndex: failedIndex
        )
    }
}
