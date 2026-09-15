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
        sanitizedTitleCandidate(title) ?? "Meeting"
    }

    func sanitizedTitleCandidate(_ title: String) -> String? {
        sanitizedFilenameComponent(title, maximumBytes: 100)
    }

    private func sanitizedFilenameComponent(
        _ value: String,
        maximumBytes: Int
    ) -> String? {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        let scalars = value.unicodeScalars.map { scalar -> Character in
            invalidCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        let sanitized = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        guard !sanitized.isEmpty else { return nil }
        let truncated = utf8Prefix(sanitized, maximumBytes: maximumBytes)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return truncated.isEmpty ? nil : truncated
    }

    private func renderTemplate(_ template: String, values: [String: String]) -> String {
        var values = values
        if template.contains("{id}"), template.contains("{title}"),
           let title = values["{title}"],
           let identifier = values["{id}"], !identifier.isEmpty {
            // Sanitizing an empty title first loses adjacent separators (for
            // example in "{title}-{id}") and can therefore undercount the
            // space required for the identifier. Instead, accept the longest
            // title prefix whose *final* sanitized name still contains it.
            var prefix = ""
            for character in title {
                let candidate = prefix + String(character)
                values["{title}"] = candidate
                let rendered = sanitizedFilenameComponent(
                    renderTemplateUnbounded(template, values: values),
                    maximumBytes: 100
                ) ?? "Meeting"
                guard rendered.contains(identifier) else { break }
                prefix = candidate
            }
            values["{title}"] = prefix
        }
        return sanitizedFilenameComponent(
            renderTemplateUnbounded(template, values: values),
            maximumBytes: 100
        ) ?? "Meeting"
    }

    private func renderTemplateUnbounded(_ template: String, values: [String: String]) -> String {
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
        return mutable as String
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
