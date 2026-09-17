import Foundation

enum ProcessingStepID: String, Codable, CaseIterable, Identifiable, Sendable {
    case preparingAudio
    case transcribing
    case analyzing
    case exporting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preparingAudio: return "Preparing audio"
        case .transcribing: return "Transcribing"
        case .analyzing: return "AI analysis"
        case .exporting: return "Exporting Markdown"
        }
    }
}

enum ProcessingStepState: Equatable, Sendable {
    case pending
    case active
    case completed
    case skipped
    case failed
}

struct ProcessingStep: Identifiable, Equatable, Sendable {
    let id: ProcessingStepID
    var state: ProcessingStepState

    static var initial: [ProcessingStep] {
        ProcessingStepID.allCases.map { ProcessingStep(id: $0, state: .pending) }
    }
}
