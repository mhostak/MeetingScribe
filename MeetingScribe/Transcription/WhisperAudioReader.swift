import AVFoundation
import Foundation

struct WhisperAudioChunk: Equatable, Sendable {
    let sampleRange: Range<Int>
    let ownershipRange: Range<Int>
}

struct WhisperAudioActivityPlan: Equatable, Sendable {
    let totalSampleCount: Int
    let activeSampleCount: Int
    let inferenceSampleCount: Int
    let chunks: [WhisperAudioChunk]

    var totalDurationSeconds: Double {
        Double(totalSampleCount) / WhisperAudioActivityDetector.sampleRate
    }

    var activeDurationSeconds: Double {
        Double(activeSampleCount) / WhisperAudioActivityDetector.sampleRate
    }

    var inferenceDurationSeconds: Double {
        Double(inferenceSampleCount) / WhisperAudioActivityDetector.sampleRate
    }

    var skippedDurationSeconds: Double {
        if chunks.count == 1,
           chunks[0].sampleRange.lowerBound == 0,
           chunks[0].sampleRange.upperBound == totalSampleCount {
            return 0
        }
        return max(0, totalDurationSeconds - activeDurationSeconds)
    }
}

struct WhisperInferenceBatch: Equatable, Sendable {
    let chunks: [WhisperAudioChunk]
    let separatorSampleCount: Int

    var inferenceSampleCount: Int {
        chunks.reduce(0) { $0 + $1.sampleRange.count }
            + max(0, chunks.count - 1) * separatorSampleCount
    }
}

struct WhisperInferenceBatchPlanner: Sendable {
    private let maximumBatchSampleCount = 5 * 60 * 16_000
    private let separatorSampleCount = 4_000

    func batches(for chunks: [WhisperAudioChunk]) -> [WhisperInferenceBatch] {
        var batches: [WhisperInferenceBatch] = []
        var current: [WhisperAudioChunk] = []
        var currentSampleCount = 0

        for chunk in chunks {
            let addedSampleCount = chunk.sampleRange.count
                + (current.isEmpty ? 0 : separatorSampleCount)
            if !current.isEmpty,
               currentSampleCount + addedSampleCount > maximumBatchSampleCount {
                batches.append(WhisperInferenceBatch(
                    chunks: current,
                    separatorSampleCount: separatorSampleCount
                ))
                current = []
                currentSampleCount = 0
            }
            if !current.isEmpty {
                currentSampleCount += separatorSampleCount
            }
            current.append(chunk)
            currentSampleCount += chunk.sampleRange.count
        }

        if !current.isEmpty {
            batches.append(WhisperInferenceBatch(
                chunks: current,
                separatorSampleCount: separatorSampleCount
            ))
        }
        return batches
    }
}

struct WhisperAudioActivityDetector: Sendable {
    static let sampleRate = 16_000.0

    // The same 64 ms energy windows are used both to plan inference before the
    // model runs and to validate the segments it proposes afterwards.
    private let windowSampleCount = 1_024
    private let minimumWindowRMS = pow(10.0, -45.0 / 20.0)
    private let minimumActiveWindowRatio = 0.08
    private let minimumActiveWindowCount = 3
    private let maximumInactiveGapWindowCount = 47
    private let paddingSampleCount = 8_000
    private let maximumChunkSampleCount = 5 * 60 * 16_000
    private let chunkOverlapSampleCount = 8_000
    private let wholeTrackActivityRatio = 0.85

    func activityPlan(for samples: [Float]) -> WhisperAudioActivityPlan {
        guard !samples.isEmpty else {
            return WhisperAudioActivityPlan(
                totalSampleCount: 0,
                activeSampleCount: 0,
                inferenceSampleCount: 0,
                chunks: []
            )
        }

        var activeWindows: [Int] = []
        activeWindows.reserveCapacity(samples.count / windowSampleCount)
        var windowIndex = 0
        var windowStart = 0
        while windowStart < samples.count {
            let windowEnd = min(samples.count, windowStart + windowSampleCount)
            if windowIsActive(samples[windowStart..<windowEnd]) {
                activeWindows.append(windowIndex)
            }
            windowIndex += 1
            windowStart = windowEnd
        }

        let activityRanges = paddedActivityRanges(
            activeWindows: activeWindows,
            totalSampleCount: samples.count
        )
        let activeSampleCount = activityRanges.reduce(0) { $0 + $1.count }
        let chunks: [WhisperAudioChunk]
        if Double(activeSampleCount) / Double(samples.count) >= wholeTrackActivityRatio {
            chunks = [WhisperAudioChunk(
                sampleRange: samples.indices,
                ownershipRange: samples.indices
            )]
        } else {
            chunks = activityRanges.flatMap { makeChunks(for: $0) }
        }
        return WhisperAudioActivityPlan(
            totalSampleCount: samples.count,
            activeSampleCount: activeSampleCount,
            inferenceSampleCount: chunks.reduce(0) { $0 + $1.sampleRange.count },
            chunks: chunks
        )
    }

    func hasMeaningfulActivity(
        in samples: [Float],
        startTime: Double,
        endTime: Double
    ) -> Bool {
        guard
            !samples.isEmpty,
            startTime.isFinite,
            endTime.isFinite,
            endTime > startTime
        else {
            return false
        }

        let startIndex = max(0, min(samples.count, Int(startTime * Self.sampleRate)))
        let endIndex = max(startIndex, min(samples.count, Int(ceil(endTime * Self.sampleRate))))
        guard endIndex > startIndex else { return false }

        var activeWindowCount = 0
        var totalWindowCount = 0
        var windowStart = startIndex

        while windowStart < endIndex {
            let windowEnd = min(endIndex, windowStart + windowSampleCount)
            if windowIsActive(samples[windowStart..<windowEnd]) {
                activeWindowCount += 1
            }
            totalWindowCount += 1
            windowStart = windowEnd
        }

        return Double(activeWindowCount) / Double(totalWindowCount)
            >= minimumActiveWindowRatio
    }

    private func windowIsActive(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return false }
        var squaredSum = 0.0
        for sample in samples where sample.isFinite {
            let value = Double(sample)
            squaredSum += value * value
        }
        let rms = sqrt(squaredSum / Double(samples.count))
        return rms >= minimumWindowRMS
    }

    private func paddedActivityRanges(
        activeWindows: [Int],
        totalSampleCount: Int
    ) -> [Range<Int>] {
        guard let firstWindow = activeWindows.first else { return [] }

        var groupedWindows: [(first: Int, last: Int, count: Int)] = []
        var group = (first: firstWindow, last: firstWindow, count: 1)
        for window in activeWindows.dropFirst() {
            if window - group.last - 1 <= maximumInactiveGapWindowCount {
                group.last = window
                group.count += 1
            } else {
                groupedWindows.append(group)
                group = (first: window, last: window, count: 1)
            }
        }
        groupedWindows.append(group)

        let padded = groupedWindows.compactMap { group -> Range<Int>? in
            guard group.count >= minimumActiveWindowCount else { return nil }
            let rawStart = group.first * windowSampleCount
            let rawEnd = min(totalSampleCount, (group.last + 1) * windowSampleCount)
            let paddedStart = max(0, rawStart - paddingSampleCount)
            let paddedEnd = min(totalSampleCount, rawEnd + paddingSampleCount)
            return paddedStart..<paddedEnd
        }

        var merged: [Range<Int>] = []
        for range in padded {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func makeChunks(for activityRange: Range<Int>) -> [WhisperAudioChunk] {
        var result: [WhisperAudioChunk] = []
        var ownershipStart = activityRange.lowerBound
        while ownershipStart < activityRange.upperBound {
            let ownershipEnd = min(
                activityRange.upperBound,
                ownershipStart + maximumChunkSampleCount
            )
            let sampleStart = ownershipStart == activityRange.lowerBound
                ? ownershipStart
                : max(activityRange.lowerBound, ownershipStart - chunkOverlapSampleCount)
            let sampleEnd = ownershipEnd == activityRange.upperBound
                ? ownershipEnd
                : min(activityRange.upperBound, ownershipEnd + chunkOverlapSampleCount)
            result.append(WhisperAudioChunk(
                sampleRange: sampleStart..<sampleEnd,
                ownershipRange: ownershipStart..<ownershipEnd
            ))
            ownershipStart = ownershipEnd
        }
        return result
    }
}

struct WhisperAudioReader: Sendable {
    func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.fileFormat
        guard
            abs(fileFormat.sampleRate - WorkingAudioConverter.targetSampleRate) < 0.5,
            fileFormat.channelCount == WorkingAudioConverter.targetChannelCount
        else {
            throw TranscriptionError.invalidAudioFormat(
                sampleRate: fileFormat.sampleRate,
                channelCount: Int(fileFormat.channelCount)
            )
        }

        let processingFormat = file.processingFormat
        guard processingFormat.commonFormat == .pcmFormatFloat32 else {
            throw TranscriptionError.invalidAudioFormat(
                sampleRate: processingFormat.sampleRate,
                channelCount: Int(processingFormat.channelCount)
            )
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let chunkSize: AVAudioFrameCount = 65_536

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frameCount = min(chunkSize, AVAudioFrameCount(remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: frameCount
            ) else {
                throw TranscriptionError.emptyAudio
            }

            try file.read(into: buffer, frameCount: frameCount)
            guard let channel = buffer.floatChannelData?[0] else {
                throw TranscriptionError.invalidAudioFormat(
                    sampleRate: processingFormat.sampleRate,
                    channelCount: Int(processingFormat.channelCount)
                )
            }
            samples.append(contentsOf: UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            ))
        }

        guard !samples.isEmpty else {
            throw TranscriptionError.emptyAudio
        }
        return samples
    }
}
