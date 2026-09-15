import Foundation

protocol AnalysisProvider: Sendable {
    func analyze(_ request: AnalysisRequest) async throws -> AnalysisMarkdown
}

enum AnalysisError: Error, Equatable, LocalizedError {
    case executableNotFound(path: String)
    case executableNotRunnable(path: String)
    case processLaunchFailed(tool: AnalysisTool, message: String)
    case processFailed(tool: AnalysisTool, exitCode: Int32, message: String)
    case authenticationRequired(tool: AnalysisTool, loginCommand: String)
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
        case let .authenticationRequired(tool, loginCommand):
            return "\(tool.displayName) sign-in has expired or is invalid. Open Terminal and run:\n\(loginCommand)\nComplete sign-in, then retry AI analysis. Your recording and transcript are saved."
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

enum AnalysisRevisionError: Error, Equatable, LocalizedError {
    case applicationBusy
    case transcriptMissing
    case markdownMissing

    var errorDescription: String? {
        switch self {
        case .applicationBusy:
            return "Wait for the current recording or processing task to finish before running AI analysis."
        case .transcriptMissing:
            return "The recording has no transcript that can be analyzed."
        case .markdownMissing:
            return "The recording's Markdown file is missing or unavailable."
        }
    }
}
