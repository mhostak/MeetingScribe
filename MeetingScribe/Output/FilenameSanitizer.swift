import Foundation

struct FilenameSanitizer: Sendable {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func markdownFileName(title: String, startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "\(formatter.string(from: startedAt)) - \(sanitizedTitle(title)).md"
    }

    func sanitizedTitle(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        let scalars = title.unicodeScalars.map { scalar -> Character in
            invalidCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        var sanitized = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))

        if sanitized.isEmpty {
            sanitized = "Meeting"
        }
        return String(sanitized.prefix(100))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}
