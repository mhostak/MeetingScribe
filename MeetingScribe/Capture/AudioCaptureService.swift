import Foundation

protocol AudioCaptureService: Sendable {
    func start(outputURL: URL) async throws
    func stop() async -> AudioCaptureDiagnostics
    func diagnostics() async -> AudioCaptureDiagnostics
}

enum AudioCaptureServiceError: Error, Equatable, LocalizedError {
    case alreadyCapturing
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case microphoneUnavailable
    case noDisplayAvailable
    case invalidAudioFormat
    case unableToCreateAudioBuffer
    case notCapturing

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "System audio capture is already running."
        case .screenRecordingPermissionDenied:
            return "MeetingScribe does not have Screen Recording permission. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen MeetingScribe."
        case .microphonePermissionDenied:
            return "MeetingScribe does not have Microphone permission. Enable it in System Settings → Privacy & Security → Microphone, then quit and reopen MeetingScribe. System audio recording can continue."
        case .microphoneUnavailable:
            return "No usable microphone input is available. System audio recording can continue."
        case .noDisplayAvailable:
            return "No display is available for system audio capture."
        case .invalidAudioFormat:
            return "ScreenCaptureKit returned an unsupported audio format."
        case .unableToCreateAudioBuffer:
            return "ScreenCaptureKit returned audio data that could not be written."
        case .notCapturing:
            return "System audio capture is not running."
        }
    }
}
