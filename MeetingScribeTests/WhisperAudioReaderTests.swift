import AVFoundation
import XCTest
@testable import MeetingScribe

final class WhisperAudioReaderTests: XCTestCase {
    func testBatchPlannerCompactsShortActivityChunksIntoFiveMinuteBatches() {
        let chunks = (0..<10).map { index in
            let start = index * 2 * 60 * 16_000
            return WhisperAudioChunk(
                sampleRange: start..<(start + 60 * 16_000),
                ownershipRange: start..<(start + 60 * 16_000)
            )
        }

        let batches = WhisperInferenceBatchPlanner().batches(for: chunks)

        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches.map { $0.chunks.count }, [4, 4, 2])
        XCTAssertTrue(batches.allSatisfy { $0.inferenceSampleCount <= 5 * 60 * 16_000 })
    }

    func testActivityPlanSkipsSilentTrackBeforeInference() {
        let plan = WhisperAudioActivityDetector().activityPlan(
            for: [Float](repeating: 0, count: 32_000)
        )

        XCTAssertEqual(plan.totalDurationSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(plan.activeDurationSeconds, 0)
        XCTAssertEqual(plan.skippedDurationSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(plan.inferenceDurationSeconds, 0)
        XCTAssertTrue(plan.chunks.isEmpty)
    }

    func testActivityPlanRejectsIsolatedShortNoise() {
        var samples = [Float](repeating: 0, count: 32_000)
        for index in 8_000..<9_024 {
            samples[index] = 0.1
        }

        let plan = WhisperAudioActivityDetector().activityPlan(for: samples)

        XCTAssertTrue(plan.chunks.isEmpty)
        XCTAssertEqual(plan.activeSampleCount, 0)
    }

    func testActivityPlanCreatesOverlappingInferenceChunksWithExclusiveOwnership() {
        let sampleCount = 10 * 60 * 16_000
        var samples = [Float](repeating: 0, count: sampleCount)
        for index in 0..<(6 * 60 * 16_000) {
            samples[index] = 0.05
        }

        let plan = WhisperAudioActivityDetector().activityPlan(for: samples)

        XCTAssertEqual(plan.chunks.count, 2)
        XCTAssertGreaterThan(plan.activeSampleCount, 6 * 60 * 16_000)
        XCTAssertLessThan(plan.activeSampleCount, (6 * 60 + 1) * 16_000)
        XCTAssertEqual(plan.chunks[0].ownershipRange, 0..<(5 * 60 * 16_000))
        XCTAssertEqual(plan.chunks[1].ownershipRange.lowerBound, 5 * 60 * 16_000)
        XCTAssertEqual(plan.chunks[0].sampleRange.lowerBound, 0)
        XCTAssertEqual(plan.chunks[0].sampleRange.upperBound, 5 * 60 * 16_000 + 8_000)
        XCTAssertEqual(plan.chunks[1].sampleRange.lowerBound, 5 * 60 * 16_000 - 8_000)
        XCTAssertEqual(plan.chunks[1].sampleRange.upperBound, plan.activeSampleCount)
        XCTAssertEqual(plan.inferenceSampleCount, plan.activeSampleCount + 16_000)
    }

    func testActivityPlanPreservesSeparatedSpeechIntervalsAndSkipsGap() {
        var samples = [Float](repeating: 0, count: 10 * 16_000)
        for index in (1 * 16_000)..<(2 * 16_000) {
            samples[index] = sin(Float(index) * 0.08) * 0.05
        }
        for index in (7 * 16_000)..<(8 * 16_000) {
            samples[index] = sin(Float(index) * 0.08) * 0.05
        }

        let plan = WhisperAudioActivityDetector().activityPlan(for: samples)

        XCTAssertEqual(plan.chunks.count, 2)
        XCTAssertLessThan(plan.activeDurationSeconds, 5)
        XCTAssertGreaterThan(plan.skippedDurationSeconds, 5)
        XCTAssertLessThan(plan.chunks[0].ownershipRange.upperBound, plan.chunks[1].ownershipRange.lowerBound)
    }

    func testActivityDetectorRejectsSilentAndLowEnergySegments() {
        let detector = WhisperAudioActivityDetector()
        let silentSamples = [Float](repeating: 0, count: 16_000)
        let lowEnergySamples = [Float](repeating: 0.001, count: 16_000)

        XCTAssertFalse(detector.hasMeaningfulActivity(
            in: silentSamples,
            startTime: 0,
            endTime: 1
        ))
        XCTAssertFalse(detector.hasMeaningfulActivity(
            in: lowEnergySamples,
            startTime: 0,
            endTime: 1
        ))
        XCTAssertFalse(detector.hasMeaningfulActivity(
            in: lowEnergySamples,
            startTime: .nan,
            endTime: 1
        ))
    }

    func testActivityDetectorAcceptsSpeechLikeSegment() {
        let detector = WhisperAudioActivityDetector()
        var samples = [Float](repeating: 0, count: 16_000)
        for index in 3_200..<6_400 {
            samples[index] = sin(Float(index) * 0.08) * 0.05
        }

        XCTAssertTrue(detector.hasMeaningfulActivity(
            in: samples,
            startTime: 0,
            endTime: 1
        ))
    }

    func testActivityDetectorRejectsSparseNoiseInLongSegment() {
        let detector = WhisperAudioActivityDetector()
        var samples = [Float](repeating: 0, count: 16_000 * 30)
        for index in 0..<16_000 {
            samples[index] = sin(Float(index) * 0.08) * 0.05
        }

        XCTAssertFalse(detector.hasMeaningfulActivity(
            in: samples,
            startTime: 0,
            endTime: 30
        ))
    }

    func testActivityDetectorUsesTrackLocalTimes() {
        let detector = WhisperAudioActivityDetector()
        var samples = [Float](repeating: 0, count: 32_000)
        for index in 16_000..<24_000 {
            samples[index] = sin(Float(index) * 0.08) * 0.05
        }

        XCTAssertTrue(detector.hasMeaningfulActivity(
            in: samples,
            startTime: 1,
            endTime: 1.5
        ))
        XCTAssertFalse(detector.hasMeaningfulActivity(
            in: samples,
            startTime: 0,
            endTime: 0.5
        ))
    }

    func testReadsSamplesFromFinalizedWaveWithoutAssumingHeaderSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeWhisperReader-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWave(to: url, sampleRate: 16_000, channels: 1, frameCount: 1_600)

        let samples = try WhisperAudioReader().readSamples(from: url)

        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(samples[100], 0.25, accuracy: 0.001)
    }

    func testRejectsNonWhisperAudioFormat() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeWhisperReader-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWave(to: url, sampleRate: 48_000, channels: 2, frameCount: 480)

        XCTAssertThrowsError(try WhisperAudioReader().readSamples(from: url)) { error in
            guard case TranscriptionError.invalidAudioFormat = error else {
                return XCTFail("Expected invalidAudioFormat, received \(error)")
            }
        }
    }

    func testDecodesVersionOneTrackTranscriptWithoutPerformanceMetrics() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "source": "system",
          "model": "ggml-test.bin",
          "requestedLanguage": "auto",
          "detectedLanguage": "sk",
          "completedAt": "2026-07-13T09:00:00Z",
          "segments": []
        }
        """.utf8)

        let transcript = try TranscriptJSONCoder.makeDecoder().decode(
            TrackTranscript.self,
            from: data
        )

        XCTAssertEqual(transcript.schemaVersion, 1)
        XCTAssertNil(transcript.performance)
    }

    private func writeWave(
        to url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: AVAudioFrameCount
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for index in 0..<(Int(frameCount) * Int(channels)) {
            samples[index] = 8_192
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }
}
