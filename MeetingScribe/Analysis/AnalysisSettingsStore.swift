import Foundation

struct OpenAIModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String

    static let supported = [
        OpenAIModelDescriptor(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna — efficient"),
        OpenAIModelDescriptor(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra — balanced"),
        OpenAIModelDescriptor(id: "gpt-5.6", displayName: "GPT-5.6 — highest quality"),
    ]
}

@MainActor
final class AnalysisSettingsStore {
    private enum Key {
        static let enabled = "aiAnalysisEnabled"
        static let model = "openAIAnalysisModel"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Key.enabled)
    }

    var model: String {
        defaults.string(forKey: Key.model) ?? OpenAIAnalysisProvider.defaultModel
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.enabled)
    }

    func setModel(_ model: String) {
        defaults.set(model, forKey: Key.model)
    }
}
