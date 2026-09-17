import Foundation

@MainActor
final class OutputFolderStore {
    private enum Key {
        static let bookmark = "outputFolderBookmark"
        static let fallbackPath = "outputFolderFallbackPath"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restoreFolder() -> URL? {
        if let data = defaults.data(forKey: Key.bookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStart {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    try? selectFolder(url)
                }
                return url
            }
        }
        guard let path = defaults.string(forKey: Key.fallbackPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func bookmark(for url: URL?) -> Data? {
        guard let url, let selected = restoreFolder(),
              selected.standardizedFileURL == url.standardizedFileURL else { return nil }
        return defaults.data(forKey: Key.bookmark)
    }

    func selectFolder(_ url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        let bookmark = try standardizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Key.bookmark)
        defaults.set(standardizedURL.path, forKey: Key.fallbackPath)
    }

    func clearFolder() {
        defaults.removeObject(forKey: Key.bookmark)
        defaults.removeObject(forKey: Key.fallbackPath)
    }

    func withAccess<T>(to url: URL, operation: () throws -> T) rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    func withAccess<T: Sendable>(
        to url: URL,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }
}
