import Foundation

struct RecordingSession: Equatable, Sendable {
    var metadata: SessionMetadata
    let directoryURL: URL

    var manifestURL: URL {
        directoryURL.appendingPathComponent("session.json", isDirectory: false)
    }
}
