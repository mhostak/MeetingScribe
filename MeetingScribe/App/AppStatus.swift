import Foundation

enum AppStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case preparing
    case recording
    case stopping
    case transcribing
    case analyzing
    case exporting
    case completed
    case failed

    var menuBarSystemImage: String {
        switch self {
        case .recording:
            return "record.circle.fill"
        case .preparing, .stopping, .transcribing, .analyzing, .exporting:
            return "clock.arrow.circlepath"
        case .failed:
            return "exclamationmark.triangle"
        case .idle, .completed:
            return "waveform"
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .stopping: return "Stopping"
        case .transcribing: return "Transcribing"
        case .analyzing: return "Analyzing"
        case .exporting: return "Exporting"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

struct AppStateMachine: Sendable {
    private(set) var status: AppStatus

    init(status: AppStatus = .idle) {
        self.status = status
    }

    mutating func transition(to nextStatus: AppStatus) throws {
        guard Self.allowedTransitions[status, default: []].contains(nextStatus) else {
            throw AppStateTransitionError.invalidTransition(from: status, to: nextStatus)
        }

        status = nextStatus
    }

    private static let allowedTransitions: [AppStatus: Set<AppStatus>] = [
        .idle: [.preparing, .failed],
        .preparing: [.recording, .failed],
        .recording: [.stopping, .failed],
        .stopping: [.transcribing, .analyzing, .exporting, .completed, .failed],
        .transcribing: [.analyzing, .exporting, .failed],
        .analyzing: [.exporting, .failed],
        .exporting: [.completed, .failed],
        .completed: [.idle, .preparing, .failed],
        .failed: [.idle, .preparing]
    ]
}

enum AppStateTransitionError: Error, Equatable, LocalizedError {
    case invalidTransition(from: AppStatus, to: AppStatus)

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, to):
            return "Invalid application state transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
}
