import Foundation

protocol TranscriptionService: Sendable {
    func transcribe(
        audioURL: URL,
        modelURL: URL,
        options: TranscriptionOptions
    ) async throws -> TrackTranscript
}

enum TranscriptionError: Error, LocalizedError {
    case invalidAudioFormat(sampleRate: Double, channelCount: Int)
    case emptyAudio
    case modelCouldNotBeLoaded(fileName: String)
    case inferenceFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case let .invalidAudioFormat(sampleRate, channelCount):
            return "Whisper requires 16 kHz mono audio, but received \(sampleRate) Hz with \(channelCount) channels."
        case .emptyAudio:
            return "The working audio file contains no samples."
        case let .modelCouldNotBeLoaded(fileName):
            return "The Whisper model \(fileName) could not be loaded."
        case let .inferenceFailed(code):
            return "Whisper transcription failed with code \(code)."
        }
    }
}
