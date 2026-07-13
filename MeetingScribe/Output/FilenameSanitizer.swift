import Foundation

struct FilenameSanitizer: Sendable {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func markdownFileName(
        title: String,
        sessionID: String = "meeting",
        startedAt: Date,
        template: String = MarkdownFileNameTemplate.defaultValue
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: startedAt)
        formatter.dateFormat = "HH-mm"
        let time = formatter.string(from: startedAt)
        let values = [
            "{date}": date,
            "{time}": time,
            "{title}": sanitizedTitle(title),
            "{id}": sanitizedTitle(sessionID),
        ]
        var rendered = MarkdownFileNameTemplate.normalized(template)
        for (token, value) in values {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }
        rendered = sanitizedTitle(rendered)
        return "\(rendered).md"
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
