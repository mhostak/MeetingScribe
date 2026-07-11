import Foundation

struct AnalysisReference: Codable, Equatable, Sendable {
    let text: String
    let timestampSeconds: Double?
    let segmentID: String?
}

struct AnalysisActionItem: Codable, Equatable, Sendable {
    let text: String
    let owner: String?
    let dueDate: String?
    let timestampSeconds: Double?
    let segmentID: String?
}

struct MeetingAnalysis: Codable, Equatable, Sendable {
    let summary: String
    let decisions: [AnalysisReference]
    let actionItems: [AnalysisActionItem]
    let openQuestions: [AnalysisReference]
    let risksAndBlockers: [AnalysisReference]
    let nextMeetingTopics: [AnalysisReference]

    static let empty = MeetingAnalysis(
        summary: "",
        decisions: [],
        actionItems: [],
        openQuestions: [],
        risksAndBlockers: [],
        nextMeetingTopics: []
    )
}

enum AnalysisRequestMode: String, Sendable {
    case transcript
    case consolidation
}

struct AnalysisRequest: Equatable, Sendable {
    let mode: AnalysisRequestMode
    let meetingTitle: String
    let recordingID: String
    let preferredLanguage: String
    let content: String
}

enum MeetingAnalysisJSONSchema {
    static var responseFormat: [String: Any] {
        [
            "type": "json_schema",
            "name": "meeting_analysis",
            "strict": true,
            "schema": schema,
        ]
    }

    private static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "decisions": [
                    "type": "array",
                    "items": referencedItemSchema,
                ],
                "actionItems": [
                    "type": "array",
                    "items": actionItemSchema,
                ],
                "openQuestions": [
                    "type": "array",
                    "items": referencedItemSchema,
                ],
                "risksAndBlockers": [
                    "type": "array",
                    "items": referencedItemSchema,
                ],
                "nextMeetingTopics": [
                    "type": "array",
                    "items": referencedItemSchema,
                ],
            ],
            "required": [
                "summary",
                "decisions",
                "actionItems",
                "openQuestions",
                "risksAndBlockers",
                "nextMeetingTopics",
            ],
            "additionalProperties": false,
        ]
    }

    private static var referencedItemSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "timestampSeconds": ["type": ["number", "null"]],
                "segmentID": ["type": ["string", "null"]],
            ],
            "required": ["text", "timestampSeconds", "segmentID"],
            "additionalProperties": false,
        ]
    }

    private static var actionItemSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "owner": ["type": ["string", "null"]],
                "dueDate": ["type": ["string", "null"]],
                "timestampSeconds": ["type": ["number", "null"]],
                "segmentID": ["type": ["string", "null"]],
            ],
            "required": [
                "text",
                "owner",
                "dueDate",
                "timestampSeconds",
                "segmentID",
            ],
            "additionalProperties": false,
        ]
    }
}
