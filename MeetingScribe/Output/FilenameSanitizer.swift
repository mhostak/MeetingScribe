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
        let rendered = renderTemplate(
            MarkdownFileNameTemplate.normalized(template),
            values: values
        )
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
        return utf8Prefix(sanitized, maximumBytes: 100)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private func renderTemplate(_ template: String, values: [String: String]) -> String {
        let expression = try? NSRegularExpression(pattern: #"\{(?:date|time|title|id)\}"#)
        let mutable = NSMutableString(string: template)
        let matches = expression?.matches(
            in: template,
            range: NSRange(template.startIndex..., in: template)
        ) ?? []
        for match in matches.reversed() {
            let token = mutable.substring(with: match.range)
            if let value = values[token] {
                mutable.replaceCharacters(in: match.range, with: value)
            }
        }
        return sanitizedTitle(mutable as String)
    }

    private func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumBytes else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
