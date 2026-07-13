import Foundation

enum AppLanguage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case slovak = "sk"
    case czech = "cs"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .slovak: return "Slovenčina"
        case .czech: return "Čeština"
        case .english: return "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .slovak: return Locale(identifier: "sk")
        case .czech: return Locale(identifier: "cs")
        case .english: return Locale(identifier: "en")
        }
    }
}

enum OutputLanguage: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case slovak = "sk"
    case czech = "cs"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slovak: return "Slovenčina"
        case .czech: return "Čeština"
        case .english: return "English"
        }
    }
}

enum MarkdownFileNameTemplate {
    static let defaultValue = "{date} {time} - {title}"
    static let supportedTokens = ["{date}", "{time}", "{title}", "{id}"]

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    static func unsupportedTokens(in value: String) -> [String] {
        let expression = try? NSRegularExpression(pattern: #"\{[^{}]+\}"#)
        let range = NSRange(value.startIndex..., in: value)
        let tokens = expression?.matches(in: value, range: range).compactMap { match -> String? in
            guard let tokenRange = Range(match.range, in: value) else { return nil }
            return String(value[tokenRange])
        } ?? []
        return Array(Set(tokens.filter { !supportedTokens.contains($0) })).sorted()
    }
}

@MainActor
final class ApplicationSettingsStore {
    private enum Key {
        static let appLanguage = "applicationLanguage"
        static let outputLanguage = "meetingOutputLanguage"
        static let markdownFileNameTemplate = "markdownFileNameTemplate"
        static let minimumStorageBytes = "minimumRecordingStorageBytes"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appLanguage: AppLanguage {
        defaults.string(forKey: Key.appLanguage)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var outputLanguage: OutputLanguage {
        defaults.string(forKey: Key.outputLanguage)
            .flatMap(OutputLanguage.init(rawValue:)) ?? .slovak
    }

    var markdownFileNameTemplate: String {
        MarkdownFileNameTemplate.normalized(
            defaults.string(forKey: Key.markdownFileNameTemplate)
                ?? MarkdownFileNameTemplate.defaultValue
        )
    }

    var minimumStorageBytes: Int64 {
        let value = defaults.object(forKey: Key.minimumStorageBytes) as? NSNumber
        return max(value?.int64Value ?? StorageGuard.defaultMinimumBytes, 1)
    }

    func setAppLanguage(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Key.appLanguage)
    }

    func setOutputLanguage(_ language: OutputLanguage) {
        defaults.set(language.rawValue, forKey: Key.outputLanguage)
    }

    func setMarkdownFileNameTemplate(_ template: String) {
        defaults.set(MarkdownFileNameTemplate.normalized(template), forKey: Key.markdownFileNameTemplate)
    }

    func setMinimumStorageBytes(_ bytes: Int64) {
        defaults.set(max(bytes, 1), forKey: Key.minimumStorageBytes)
    }
}
