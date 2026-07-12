import Foundation

@MainActor
final class WhisperSettingsStore {
    private enum Key {
        static let selectedModelID = "selectedWhisperModelID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedModelID: String {
        defaults.string(forKey: Key.selectedModelID)
            ?? WhisperModelDescriptor.largeV3Turbo.id
    }

    func setSelectedModelID(_ modelID: String) {
        defaults.set(modelID, forKey: Key.selectedModelID)
    }
}
