import Foundation
import XCTest
@testable import MeetingScribe

/// Guards the one failure mode a string catalog cannot report by itself.
///
/// A SwiftUI string literal with no entry in `Localizable.xcstrings` does not
/// warn and does not crash. It renders in English, under every language,
/// forever — which is how an entire recovery card stayed English for Slovak
/// and Czech users while the catalog reported 100% translated.
///
/// Only literals without interpolation are checked. Their catalog keys are
/// exactly the source text, so the comparison is unambiguous; an interpolated
/// literal becomes a `%@`/`%lld` format string whose reconstruction here would
/// be a second, drifting implementation of what Xcode already does.
final class LocalizationCatalogTests: XCTestCase {
    /// Text that is a name rather than a phrase to translate.
    private static let untranslated: Set<String> = ["MeetingScribe", "FluidAudio", "Markdown"]

    private static let textBearingInitializers = [
        "Text", "Label", "Button", "Section", "Toggle", "Picker", "Stepper", "Link",
        "confirmationDialog", "navigationTitle", "help", "accessibilityLabel",
        "LabeledContent",
    ]

    func testEverySupportedLanguageTranslatesEveryCatalogKey() throws {
        let catalog = try loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty)

        var untranslated: [String] = []
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["sk", "cs"] {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"]
                    as? [String: Any]
                let translation = unit?["value"] as? String
                if translation?.isEmpty ?? true {
                    untranslated.append("\(language): \(key)")
                }
            }
        }

        XCTAssertEqual(
            untranslated.sorted(), [],
            "Catalog keys without a translation:\n" + untranslated.sorted().joined(separator: "\n")
        )
    }

    func testEveryPlainUIStringLiteralHasACatalogEntry() throws {
        let catalog = try loadCatalog()
        let keys = Set((catalog["strings"] as? [String: Any] ?? [:]).keys)
        let sourceRoot = Self.repositoryRoot.appendingPathComponent("MeetingScribe")

        var missing: [String] = []
        for file in try swiftFiles(in: sourceRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in Self.plainUILiterals(in: source) where !keys.contains(literal) {
                missing.append("\(file.lastPathComponent): \(literal)")
            }
        }

        XCTAssertEqual(
            missing.sorted(), [],
            "User-visible strings with no catalog entry render in English under every "
                + "language:\n" + missing.sorted().joined(separator: "\n")
        )
    }

    // MARK: - Scanning

    /// Literals passed directly to a text-bearing SwiftUI initializer, with no
    /// interpolation and at least one word in them.
    static func plainUILiterals(in source: String) -> [String] {
        var found: [String] = []
        for initializer in textBearingInitializers {
            var searchRange = source.startIndex..<source.endIndex
            while let call = source.range(
                of: "\(initializer)(", options: .literal, range: searchRange
            ) {
                searchRange = call.upperBound..<source.endIndex
                var index = call.upperBound
                // Allow whitespace between the parenthesis and the literal.
                while index < source.endIndex, source[index] == " " || source[index] == "\n" {
                    index = source.index(after: index)
                }
                guard index < source.endIndex, source[index] == "\"" else { continue }
                // `Text("""` is a multi-line literal; leave those alone.
                let afterQuote = source.index(after: index)
                guard afterQuote < source.endIndex, source[afterQuote] != "\"" else { continue }
                guard let literal = Self.literal(in: source, startingAt: index) else { continue }
                guard !literal.contains("\\("),
                      literal.contains(where: { $0.isLetter }) else { continue }
                guard !untranslated.contains(literal) else { continue }
                found.append(literal)
            }
        }
        return found
    }

    /// Reads a single-line Swift string literal whose opening quote is at
    /// `start`, honouring backslash escapes. Returns nil for an unterminated
    /// literal, which the compiler would have rejected anyway.
    private static func literal(in source: String, startingAt start: String.Index) -> String? {
        var index = source.index(after: start)
        var value = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                let next = source.index(after: index)
                guard next < source.endIndex else { return nil }
                // Keep the escape so an interpolation marker stays detectable.
                value.append(character)
                value.append(source[next])
                index = source.index(after: next)
                continue
            }
            if character == "\"" { return value }
            if character == "\n" { return nil }
            value.append(character)
            index = source.index(after: index)
        }
        return nil
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func loadCatalog() throws -> [String: Any] {
        let url = Self.repositoryRoot
            .appendingPathComponent("MeetingScribe")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
