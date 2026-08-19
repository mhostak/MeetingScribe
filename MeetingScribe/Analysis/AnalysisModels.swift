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

    var authenticationStatusArguments: [String] {
        switch self {
        case .codex: return ["login", "status"]
        case .claude: return ["auth", "status"]
        }
    }

    var loginArguments: [String] {
        switch self {
        case .codex: return ["login"]
        case .claude: return ["auth", "login"]
        }
    }

    func loginCommand(executableURL: URL) -> String {
        let quotedPath = "'\(executableURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        return ([quotedPath] + loginArguments).joined(separator: " ")
    }
}

enum AnalysisModelSelection: String, Codable, Identifiable, Sendable {
    case automatic
    case codexTerra
    case codexSol
    case codexLuna
    case claudeSonnet
    case claudeOpus
    case custom

    var id: String { rawValue }

    static func options(for tool: AnalysisTool) -> [AnalysisModelSelection] {
        switch tool {
        case .codex:
            return [.automatic, .codexTerra, .codexSol, .codexLuna, .custom]
        case .claude:
            return [.automatic, .claudeSonnet, .claudeOpus, .custom]
        }
    }

    func isAvailable(for tool: AnalysisTool) -> Bool {
        Self.options(for: tool).contains(self)
    }

    var titleLocalizationKey: String {
        switch self {
        case .automatic: return "Automatic (tool default)"
        case .codexTerra: return "GPT-5.6 Terra — recommended"
        case .codexSol: return "GPT-5.6 Sol — highest quality"
        case .codexLuna: return "GPT-5.6 Luna — fastest"
        case .claudeSonnet: return "Claude Sonnet — recommended"
        case .claudeOpus: return "Claude Opus — highest quality"
        case .custom: return "Custom model…"
        }
    }

    var detailLocalizationKey: String {
        switch self {
        case .automatic:
            return "The selected tool chooses its configured or recommended model."
        case .codexTerra:
            return "Balanced quality, speed, and cost for meeting analysis."
        case .codexSol, .claudeOpus:
            return "Highest quality for complex or long meetings."
        case .codexLuna:
            return "Fast and efficient for repeatable analysis."
        case .claudeSonnet:
            return "Balanced quality and speed for meeting analysis."
        case .custom:
            return "Enter a model identifier supported by the selected tool."
        }
    }

    var modelIdentifier: String? {
        switch self {
        case .automatic, .custom: return nil
        case .codexTerra: return "gpt-5.6-terra"
        case .codexSol: return "gpt-5.6-sol"
        case .codexLuna: return "gpt-5.6-luna"
        case .claudeSonnet: return "sonnet"
        case .claudeOpus: return "opus"
        }
    }

    func resolvedModel(customModel: String) -> String? {
        if let modelIdentifier { return modelIdentifier }
        guard self == .custom else { return nil }
        let normalized = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func selection(for model: String, tool: AnalysisTool) -> AnalysisModelSelection {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .automatic }
        switch (tool, normalized) {
        case (.codex, "gpt-5.6-terra"): return .codexTerra
        case (.codex, "gpt-5.6-sol"), (.codex, "gpt-5.6"): return .codexSol
        case (.codex, "gpt-5.6-luna"): return .codexLuna
        case (.claude, "sonnet"): return .claudeSonnet
        case (.claude, "opus"): return .claudeOpus
        default: return .custom
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
    let preferredLanguage: OutputLanguage
    let userPrompt: String
    let content: String
}

enum AnalysisPrompt {
    static let legacySegmentReferenceTemplate = """
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
    Pri rozhodnutiach a úlohách uveď relevantný timestamp z meetingu. Nepoužívaj interné ID segmentov.
    """

    static func render(template: String, session: SessionMetadata) -> String {
        template
            .replacingOccurrences(
                of: "{{output_language}}",
                with: session.resolvedOutputLanguage.analysisLanguageDescription
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
