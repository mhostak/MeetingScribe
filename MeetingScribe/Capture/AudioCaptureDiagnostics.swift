import Foundation

enum AudioCaptureHealth: String, Codable, Equatable, Sendable {
    case idle
    case waitingForData
    case active
    case stalled
    case failed
}

struct AudioCaptureDiagnostics: Codable, Equatable, Sendable {
    static let empty = AudioCaptureDiagnostics()

    var fileName = ""
    var startedAt: Date?
    var lastBufferReceivedAt: Date?
    var bufferCount = 0
    var totalFrames: Int64 = 0
    var sampleRate: Double?
    var channelCount: Int?
    var firstPresentationTimestamp: Double?
    var lastPresentationTimestamp: Double?
    var lastBufferDurationSeconds: Double?
    var failureReason: String?

    var capturedDurationSeconds: Double? {
        guard
            let firstPresentationTimestamp,
            let lastPresentationTimestamp
        else {
            return nil
        }

        return max(
            0,
            lastPresentationTimestamp - firstPresentationTimestamp + (lastBufferDurationSeconds ?? 0)
        )
    }

    func health(at date: Date = Date(), stallThreshold: TimeInterval = 10) -> AudioCaptureHealth {
        if failureReason != nil {
            return .failed
        }

        guard let startedAt else {
            return .idle
        }

        guard let lastBufferReceivedAt else {
            return date.timeIntervalSince(startedAt) >= stallThreshold ? .stalled : .waitingForData
        }

        return date.timeIntervalSince(lastBufferReceivedAt) >= stallThreshold ? .stalled : .active
    }

    mutating func registerBuffer(
        frameCount: Int,
        sampleRate: Double,
        channelCount: Int,
        presentationTimestamp: Double,
        receivedAt: Date = Date()
    ) {
        bufferCount += 1
        totalFrames += Int64(frameCount)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        lastBufferReceivedAt = receivedAt
        lastBufferDurationSeconds = sampleRate > 0 ? Double(frameCount) / sampleRate : nil

        if firstPresentationTimestamp == nil {
            firstPresentationTimestamp = presentationTimestamp
        }
        lastPresentationTimestamp = presentationTimestamp
    }

    var sessionMetadata: AudioTrackMetadata {
        AudioTrackMetadata(
            fileName: fileName,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bufferCount: bufferCount,
            totalFrames: totalFrames,
            firstPresentationTimestamp: firstPresentationTimestamp,
            lastPresentationTimestamp: lastPresentationTimestamp,
            capturedDurationSeconds: capturedDurationSeconds,
            failureReason: failureReason
        )
    }
}

struct CaptureSessionDiagnostics: Codable, Equatable, Sendable {
    static let empty = CaptureSessionDiagnostics(
        systemAudio: .empty,
        microphone: .empty
    )

    var systemAudio: AudioCaptureDiagnostics
    var microphone: AudioCaptureDiagnostics
}
