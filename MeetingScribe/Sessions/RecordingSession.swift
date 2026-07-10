import Foundation

struct RecordingSession: Equatable, Sendable {
    var metadata: SessionMetadata
    let directoryURL: URL

    var manifestURL: URL {
        directoryURL.appendingPathComponent("session.json", isDirectory: false)
    }

    var systemAudioURL: URL {
        directoryURL.appendingPathComponent(metadata.audioFiles.system, isDirectory: false)
    }

    var microphoneAudioURL: URL {
        directoryURL.appendingPathComponent(metadata.audioFiles.microphone, isDirectory: false)
    }
}
