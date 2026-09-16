import Foundation

extension ProcessingJob {
    var displayName: String {
        switch state {
        case .queued: return "Queued"
        case .running: return stage?.displayName ?? "Processing"
        case .pauseRequested: return "Pausing processing"
        case .paused: return "Waiting for available resources"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}
