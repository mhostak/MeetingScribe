import Foundation

protocol AnalysisProvider: Sendable {
    func analyze(_ request: AnalysisRequest) async throws -> AnalysisMarkdown
}

enum AnalysisError: Error, Equatable, LocalizedError {
    case executableNotFound(path: String)
    case executableNotRunnable(path: String)
    case processLaunchFailed(tool: AnalysisTool, message: String)
    case processFailed(tool: AnalysisTool, exitCode: Int32, message: String)
    case processTimedOut(tool: AnalysisTool)
    case transcriptChunkTooLarge
    case emptyOutput
    case outputTooLarge
    case reservedMarkerInOutput
    case invalidStructuredOutput(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "The AI tool executable was not found at \(path)."
        case let .executableNotRunnable(path):
            return "The selected AI tool is not executable: \(path)."
        case let .processLaunchFailed(tool, message):
            return "\(tool.displayName) could not be started: \(message)"
        case let .processFailed(tool, exitCode, message):
            let detail = message.isEmpty ? "No diagnostic output." : message
            return "\(tool.displayName) failed with exit code \(exitCode): \(detail)"
        case let .processTimedOut(tool):
            return "\(tool.displayName) analysis timed out."
        case .transcriptChunkTooLarge:
            return "A transcript segment or partial analysis is too large to process safely."
        case .emptyOutput:
            return "The AI tool returned an empty analysis."
        case .outputTooLarge:
            return "The AI tool returned an analysis that is too large."
        case .reservedMarkerInOutput:
            return "The AI analysis contains a reserved MeetingScribe marker."
        case let .invalidStructuredOutput(reason):
            return "The structured AI analysis could not be decoded: \(reason)"
        }
    }
}
