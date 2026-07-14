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
        "waveform"
    }

    var isProcessing: Bool {
        switch self {
        case .preparing, .stopping, .transcribing, .analyzing, .exporting:
            return true
        case .idle, .recording, .completed, .failed:
            return false
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

enum MenuBarIconState: String, Equatable, Sendable {
    case idle
    case recording
    case processing
    case attention

    init(status: AppStatus, hasRecovery: Bool) {
        if status == .recording {
            self = .recording
        } else if status.isProcessing {
            self = .processing
        } else if status == .failed || hasRecovery {
            self = .attention
        } else {
            self = .idle
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "MeetingScribe ready"
        case .recording: return "MeetingScribe recording"
        case .processing: return "MeetingScribe processing"
        case .attention: return "MeetingScribe needs attention"
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
