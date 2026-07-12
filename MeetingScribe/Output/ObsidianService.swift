import Foundation

/// Builds a best-effort Obsidian handoff URI for the most recently exported note.
///
/// The URI identifies a vault by its directory name and a note by its relative
/// path. It cannot disambiguate two registered vaults with the same name or
/// prove that Obsidian is installed. Normal file opening remains the fallback.
@MainActor
final class ObsidianService {
    private let isDirectory: (URL) -> Bool
    private var cachedMarkdownURL: URL?
    private var cachedVaultRoot: URL?
    private var hasCachedLookup = false

    init(isDirectory: @escaping (URL) -> Bool = ObsidianService.defaultIsDirectory) {
        self.isDirectory = isDirectory
    }

    func openURL(for markdownURL: URL) -> URL? {
        guard let vaultRoot = vaultRoot(containing: markdownURL) else { return nil }
        let rootPath = vaultRoot.standardizedFileURL.path
        let filePath = markdownURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }

        let relativePath = String(filePath.dropFirst(rootPath.count + 1))
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultRoot.lastPathComponent),
            URLQueryItem(name: "file", value: relativePath),
        ]
        return components.url
    }

    func vaultRoot(containing markdownURL: URL) -> URL? {
        let standardizedMarkdownURL = markdownURL.standardizedFileURL
        if hasCachedLookup, cachedMarkdownURL == standardizedMarkdownURL {
            return cachedVaultRoot
        }

        let result = findVaultRoot(containing: standardizedMarkdownURL)
        cachedMarkdownURL = standardizedMarkdownURL
        cachedVaultRoot = result
        hasCachedLookup = true
        return result
    }

    private func findVaultRoot(containing markdownURL: URL) -> URL? {
        var directory = markdownURL.deletingLastPathComponent()
        while directory.path != "/" {
            let marker = directory.appendingPathComponent(".obsidian", isDirectory: true)
            if isDirectory(marker) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated private static func defaultIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
