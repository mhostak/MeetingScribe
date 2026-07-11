import Foundation

protocol AnalysisProvider: Sendable {
    func analyze(_ request: AnalysisRequest) async throws -> MeetingAnalysis
}

enum AnalysisError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case transcriptChunkTooLarge
    case invalidHTTPResponse
    case apiError(statusCode: Int, message: String)
    case incompleteResponse(status: String)
    case refusal(String)
    case missingStructuredOutput
    case invalidStructuredOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key before enabling AI analysis."
        case .transcriptChunkTooLarge:
            return "A transcript segment or partial analysis is too large to process safely."
        case .invalidHTTPResponse:
            return "OpenAI returned an invalid HTTP response."
        case let .apiError(statusCode, message):
            return "OpenAI API error \(statusCode): \(message)"
        case let .incompleteResponse(status):
            return "OpenAI analysis did not complete (status: \(status))."
        case let .refusal(message):
            return "OpenAI declined the analysis: \(message)"
        case .missingStructuredOutput:
            return "OpenAI returned no structured meeting analysis."
        case let .invalidStructuredOutput(reason):
            return "The structured meeting analysis could not be decoded: \(reason)"
        }
    }
}
