import CryptoKit
import Foundation

enum AnalysisTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }
}

struct AnalysisMarkdown: Codable, Equatable, Sendable {
    let markdown: String

    static let empty = AnalysisMarkdown(markdown: "")
}

struct AIAnalysisArtifact: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let markdown: String
    let tool: AnalysisTool
    let model: String?
    let toolVersion: String?
    let prompt: String
    let promptHash: String
    let generatedAt: Date

    init(
        schemaVersion: Int = 1,
        markdown: String,
        tool: AnalysisTool,
        model: String?,
        toolVersion: String?,
        prompt: String,
        generatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.markdown = markdown
        self.tool = tool
        self.model = model
        self.toolVersion = toolVersion
        self.prompt = prompt
        self.promptHash = AnalysisPrompt.hash(prompt)
        self.generatedAt = generatedAt
    }
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
    let userPrompt: String
    let content: String
}

enum AnalysisPrompt {
    static let defaultTemplate = """
    Analyzuj transcript pracovného meetingu.

    Výstup vytvor v jazyku {{output_language}} ako Markdown fragment.

    Použi túto štruktúru:
    1. stručný faktický súhrn,
    2. prijaté rozhodnutia,
    3. úlohy vrátane vlastníka a termínu,
    4. otvorené otázky,
    5. riziká a blokery,
    6. dôležité témy na ďalší meeting.

    Nevymýšľaj informácie, ktoré nie sú v transcripte.
    Návrhy neoznačuj ako rozhodnutia.
    Ak vlastník alebo termín nie sú explicitne uvedené, napíš „neurčené“.
    Pri rozhodnutiach a úlohách zachovaj timestamp alebo odkaz na relevantný segment.
    """

    static func render(template: String, session: SessionMetadata) -> String {
        template
            .replacingOccurrences(
                of: "{{output_language}}",
                with: session.resolvedOutputLanguage.rawValue
            )
            .replacingOccurrences(of: "{{meeting_title}}", with: session.title)
            .replacingOccurrences(of: "{{recording_id}}", with: session.id)
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum AnalysisMarkdownSchema {
    static let maximumMarkdownBytes = 1_000_000
    static let reservedMarkers = [
        "<!-- meetingscribe:ai-analysis:start -->",
        "<!-- meetingscribe:ai-analysis:end -->",
    ]

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "markdown": ["type": "string"],
            ],
            "required": ["markdown"],
            "additionalProperties": false,
        ]
    }

    static func validate(_ response: AnalysisMarkdown) throws -> AnalysisMarkdown {
        let normalized = response.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AnalysisError.emptyOutput }
        guard normalized.utf8.count <= maximumMarkdownBytes else {
            throw AnalysisError.outputTooLarge
        }
        guard !reservedMarkers.contains(where: normalized.contains) else {
            throw AnalysisError.reservedMarkerInOutput
        }
        return AnalysisMarkdown(markdown: normalized)
    }
}
