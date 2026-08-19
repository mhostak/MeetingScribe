import Foundation

enum AudioRetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case keepForever
    case sevenDays
    case thirtyDays
    case immediately

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepForever: return "Keep forever"
        case .sevenDays: return "Delete after 7 days"
        case .thirtyDays: return "Delete after 30 days"
        case .immediately: return "Delete after successful processing"
        }
    }

    func cutoffDate(now: Date) -> Date? {
        let age: TimeInterval
        switch self {
        case .keepForever:
            return nil
        case .sevenDays:
            age = 7 * 24 * 60 * 60
        case .thirtyDays:
            age = 30 * 24 * 60 * 60
        case .immediately:
            age = 0
        }
        return now.addingTimeInterval(-age)
    }
}

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
        static let policy = "recordingAudioRetentionPolicy"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var automaticallyDeleteSourceCAF: Bool {
        defaults.bool(forKey: Key.automaticallyDeleteSourceCAF)
    }

    var policy: AudioRetentionPolicy {
        guard let value = defaults.string(forKey: Key.policy),
              let policy = AudioRetentionPolicy(rawValue: value) else {
            return .keepForever
        }
        return policy
    }

    func setAutomaticallyDeleteSourceCAF(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.automaticallyDeleteSourceCAF)
    }

    func setPolicy(_ policy: AudioRetentionPolicy) {
        defaults.set(policy.rawValue, forKey: Key.policy)
    }
}
