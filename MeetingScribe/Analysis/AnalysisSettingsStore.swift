import Foundation

@MainActor
final class AnalysisSettingsStore {
    private enum Key {
        static let enabled = "aiAnalysisEnabled"
        static let legacyModel = "openAIAnalysisModel"
        static let tool = "aiAnalysisTool"
        static let model = "aiAnalysisModel"
        static let prompt = "aiAnalysisPrompt"
        static let codexExecutable = "aiAnalysisCodexExecutable"
        static let claudeExecutable = "aiAnalysisClaudeExecutable"
        static let migrationCompleted = "aiAnalysisCLIMigrationCompleted"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacySettingsIfNeeded()
    }

    var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }

    var tool: AnalysisTool {
        defaults.string(forKey: Key.tool).flatMap(AnalysisTool.init(rawValue:)) ?? .codex
    }

    var model: String { defaults.string(forKey: Key.model) ?? "" }

    var prompt: String { defaults.string(forKey: Key.prompt) ?? AnalysisPrompt.defaultTemplate }

    func executablePath(for tool: AnalysisTool) -> String {
        defaults.string(forKey: executableKey(for: tool)) ?? ""
    }

    func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: Key.enabled) }
    func setTool(_ tool: AnalysisTool) { defaults.set(tool.rawValue, forKey: Key.tool) }
    func setModel(_ model: String) { defaults.set(model, forKey: Key.model) }
    func setPrompt(_ prompt: String) { defaults.set(prompt, forKey: Key.prompt) }

    func setExecutablePath(_ path: String, for tool: AnalysisTool) {
        defaults.set(path, forKey: executableKey(for: tool))
    }

    private func executableKey(for tool: AnalysisTool) -> String {
        switch tool {
        case .codex: return Key.codexExecutable
        case .claude: return Key.claudeExecutable
        }
    }

    private func migrateLegacySettingsIfNeeded() {
        guard !defaults.bool(forKey: Key.migrationCompleted) else { return }
        // The removed provider could be enabled without ever persisting its default model.
        // Require an explicit opt-in after upgrading so the newly selected CLI is never run
        // merely because the old implementation had been enabled.
        defaults.set(false, forKey: Key.enabled)
        defaults.removeObject(forKey: Key.legacyModel)
        defaults.set(true, forKey: Key.migrationCompleted)
    }
}
