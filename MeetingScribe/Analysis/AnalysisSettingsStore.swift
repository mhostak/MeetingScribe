import Foundation

@MainActor
final class AnalysisSettingsStore {
    private enum Key {
        static let enabled = "aiAnalysisEnabled"
        static let legacyModel = "openAIAnalysisModel"
        static let tool = "aiAnalysisTool"
        static let legacyCLIModel = "aiAnalysisModel"
        static let codexModelSelection = "aiAnalysisCodexModelSelection"
        static let claudeModelSelection = "aiAnalysisClaudeModelSelection"
        static let codexCustomModel = "aiAnalysisCodexCustomModel"
        static let claudeCustomModel = "aiAnalysisClaudeCustomModel"
        static let prompt = "aiAnalysisPrompt"
        static let codexExecutable = "aiAnalysisCodexExecutable"
        static let claudeExecutable = "aiAnalysisClaudeExecutable"
        static let migrationCompleted = "aiAnalysisCLIMigrationCompleted"
        static let modelPickerMigrationCompleted = "aiAnalysisModelPickerMigrationCompleted"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacySettingsIfNeeded()
        migrateModelPickerSettingsIfNeeded()
    }

    var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }

    var tool: AnalysisTool {
        defaults.string(forKey: Key.tool).flatMap(AnalysisTool.init(rawValue:)) ?? .codex
    }

    var prompt: String { defaults.string(forKey: Key.prompt) ?? AnalysisPrompt.defaultTemplate }

    func modelSelection(for tool: AnalysisTool) -> AnalysisModelSelection {
        guard let rawValue = defaults.string(forKey: modelSelectionKey(for: tool)),
              let selection = AnalysisModelSelection(rawValue: rawValue),
              selection.isAvailable(for: tool) else {
            return .automatic
        }
        return selection
    }

    func customModel(for tool: AnalysisTool) -> String {
        defaults.string(forKey: customModelKey(for: tool)) ?? ""
    }

    func resolvedModel(for tool: AnalysisTool) -> String? {
        modelSelection(for: tool).resolvedModel(customModel: customModel(for: tool))
    }

    func executablePath(for tool: AnalysisTool) -> String {
        defaults.string(forKey: executableKey(for: tool)) ?? ""
    }

    func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: Key.enabled) }
    func setTool(_ tool: AnalysisTool) { defaults.set(tool.rawValue, forKey: Key.tool) }
    func setPrompt(_ prompt: String) { defaults.set(prompt, forKey: Key.prompt) }

    func setModelSelection(_ selection: AnalysisModelSelection, for tool: AnalysisTool) {
        let validSelection = selection.isAvailable(for: tool) ? selection : .automatic
        defaults.set(validSelection.rawValue, forKey: modelSelectionKey(for: tool))
    }

    func setCustomModel(_ model: String, for tool: AnalysisTool) {
        defaults.set(model, forKey: customModelKey(for: tool))
    }

    func setExecutablePath(_ path: String, for tool: AnalysisTool) {
        defaults.set(path, forKey: executableKey(for: tool))
    }

    private func executableKey(for tool: AnalysisTool) -> String {
        switch tool {
        case .codex: return Key.codexExecutable
        case .claude: return Key.claudeExecutable
        }
    }

    private func modelSelectionKey(for tool: AnalysisTool) -> String {
        switch tool {
        case .codex: return Key.codexModelSelection
        case .claude: return Key.claudeModelSelection
        }
    }

    private func customModelKey(for tool: AnalysisTool) -> String {
        switch tool {
        case .codex: return Key.codexCustomModel
        case .claude: return Key.claudeCustomModel
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

    private func migrateModelPickerSettingsIfNeeded() {
        guard !defaults.bool(forKey: Key.modelPickerMigrationCompleted) else { return }
        if let legacyModel = defaults.string(forKey: Key.legacyCLIModel) {
            let selectedTool = tool
            let normalizedModel = legacyModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let selection = AnalysisModelSelection.selection(
                for: normalizedModel,
                tool: selectedTool
            )
            setModelSelection(selection, for: selectedTool)
            if selection == .custom {
                setCustomModel(normalizedModel, for: selectedTool)
            }
        }
        defaults.removeObject(forKey: Key.legacyCLIModel)
        defaults.set(true, forKey: Key.modelPickerMigrationCompleted)
    }
}
