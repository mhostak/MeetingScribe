import Foundation

protocol OnboardingTestDelaying: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

struct DefaultOnboardingTestDelay: OnboardingTestDelaying {
    func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(duration))
    }
}

enum OnboardingTestPhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case processing
    case completed
    case failed
}

struct OnboardingTestTrackResult: Equatable, Identifiable, Sendable {
    let id: String
    let bufferCount: Int
    let totalFrames: Int64
    let capturedDurationSeconds: Double?
    let activityDetected: Bool
    let failureReason: String?

    init(
        id: String,
        diagnostics: AudioCaptureDiagnostics
    ) {
        self.id = id
        self.bufferCount = diagnostics.bufferCount
        self.totalFrames = diagnostics.totalFrames
        self.capturedDurationSeconds = diagnostics.capturedDurationSeconds
        self.activityDetected = (diagnostics.recentNormalizedAudioLevels ?? [])
            .contains { $0 > 0 }
        self.failureReason = diagnostics.failureReason
    }
}

struct OnboardingTestResult: Equatable, Sendable {
    let sessionID: String
    let title: String
    let systemAudio: OnboardingTestTrackResult
    let microphone: OnboardingTestTrackResult
    let transcriptionStatus: SessionTranscriptionStatus?
    let transcriptionFailureReason: String?
    let markdownURL: URL?
    let sessionDirectoryURL: URL
    let error: String?
}
