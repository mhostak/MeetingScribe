import Foundation

struct ObsidianService: Sendable {
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
        var directory = markdownURL.deletingLastPathComponent().standardizedFileURL
        while directory.path != "/" {
            let marker = directory.appendingPathComponent(".obsidian", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
