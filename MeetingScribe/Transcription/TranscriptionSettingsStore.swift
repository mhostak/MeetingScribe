import Foundation

@MainActor
final class TranscriptionSettingsStore {
    private enum Key {
        static let selectedLanguage = "selectedTranscriptionLanguage"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedLanguage: TranscriptionLanguage {
        guard
            let rawValue = defaults.string(forKey: Key.selectedLanguage),
            let language = TranscriptionLanguage(rawValue: rawValue)
        else {
            return .automatic
        }
        return language
    }

    func setSelectedLanguage(_ language: TranscriptionLanguage) {
        defaults.set(language.rawValue, forKey: Key.selectedLanguage)
    }
}

@MainActor
final class AudioRetentionSettingsStore {
    private enum Key {
        static let automaticallyDeleteSourceCAF = "automaticallyDeleteSourceCAFAfterExport"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var automaticallyDeleteSourceCAF: Bool {
        defaults.bool(forKey: Key.automaticallyDeleteSourceCAF)
    }

    func setAutomaticallyDeleteSourceCAF(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.automaticallyDeleteSourceCAF)
    }
}
