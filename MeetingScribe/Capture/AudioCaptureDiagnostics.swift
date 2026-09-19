import Foundation

struct AudioLevelMeasurement: Equatable, Sendable {
    let rmsDecibels: Double
    let peakDecibels: Double

    var normalizedForDisplay: Double {
        // RMS keeps the display stable while a reduced peak contribution makes
        // short sounds visible. Map the useful speech range from -60 dBFS to 0.
        let displayDecibels = max(rmsDecibels, peakDecibels - 12)
        return min(1, max(0, (displayDecibels + 60) / 60))
    }
}

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
    var droppedBufferCount = 0
    var totalFrames: Int64 = 0
    var sampleRate: Double?
    var channelCount: Int?
    var firstPresentationTimestamp: Double?
    var lastPresentationTimestamp: Double?
    var lastBufferDurationSeconds: Double?
    var rmsDecibels: Double?
    var peakDecibels: Double?
    var recentNormalizedAudioLevels: [Double]?
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
        presentationTimestamp: Double?,
        audioLevel: AudioLevelMeasurement? = nil,
        receivedAt: Date = Date()
    ) {
        bufferCount += 1
        totalFrames += Int64(frameCount)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        lastBufferReceivedAt = receivedAt
        lastBufferDurationSeconds = sampleRate > 0 ? Double(frameCount) / sampleRate : nil

        if let audioLevel {
            rmsDecibels = audioLevel.rmsDecibels
            peakDecibels = audioLevel.peakDecibels
            var levels = recentNormalizedAudioLevels ?? []
            levels.append(audioLevel.normalizedForDisplay)
            if levels.count > Self.liveLevelHistoryLimit {
                levels.removeFirst(levels.count - Self.liveLevelHistoryLimit)
            }
            recentNormalizedAudioLevels = levels
        }

        if let presentationTimestamp {
            if firstPresentationTimestamp == nil {
                firstPresentationTimestamp = presentationTimestamp
            }
            lastPresentationTimestamp = presentationTimestamp
        }
    }

    mutating func registerDroppedBuffers(_ count: Int) {
        droppedBufferCount += max(0, count)
    }

    /// Records why capture failed, keeping the first reason given.
    ///
    /// A failure cascades: the write that ran out of disk space is followed by
    /// buffers that find no writer, and by a stop that reports the stream was
    /// never running. Those later reasons describe the wreckage, not the
    /// cause, and they arrive within milliseconds. Only the first one is
    /// worth showing the user or writing into the session manifest.
    ///
    /// An empty or whitespace-only reason is not a description of anything and
    /// is ignored, so it cannot claim the slot a real one needs.
    mutating func registerFailureReason(_ reason: String) {
        guard failureReason == nil else { return }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        failureReason = trimmed
    }

    func recentLiveAudioLevels(
        at date: Date = Date(),
        staleAfter: TimeInterval = 1,
        maximumCount: Int = 22
    ) -> [Double] {
        guard maximumCount > 0,
              let lastBufferReceivedAt,
              date.timeIntervalSince(lastBufferReceivedAt) <= staleAfter else {
            return []
        }
        return Array((recentNormalizedAudioLevels ?? []).suffix(maximumCount))
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

    private static let liveLevelHistoryLimit = 64
}

struct CaptureSessionDiagnostics: Codable, Equatable, Sendable {
    static let empty = CaptureSessionDiagnostics(
        systemAudio: .empty,
        microphone: .empty
    )

    var systemAudio: AudioCaptureDiagnostics
    var microphone: AudioCaptureDiagnostics

    func combinedRecentAudioLevels(
        at date: Date = Date(),
        staleAfter: TimeInterval = 1,
        maximumCount: Int = 22
    ) -> [Double] {
        let systemLevels = systemAudio.recentLiveAudioLevels(
            at: date,
            staleAfter: staleAfter,
            maximumCount: maximumCount
        )
        let microphoneLevels = microphone.recentLiveAudioLevels(
            at: date,
            staleAfter: staleAfter,
            maximumCount: maximumCount
        )
        let resultCount = max(systemLevels.count, microphoneLevels.count)
        guard resultCount > 0 else { return [] }

        return (0..<resultCount).map { index in
            let systemIndex = index - (resultCount - systemLevels.count)
            let microphoneIndex = index - (resultCount - microphoneLevels.count)
            let systemLevel = systemIndex >= 0 ? systemLevels[systemIndex] : 0
            let microphoneLevel = microphoneIndex >= 0 ? microphoneLevels[microphoneIndex] : 0
            return max(systemLevel, microphoneLevel)
        }
    }
}
