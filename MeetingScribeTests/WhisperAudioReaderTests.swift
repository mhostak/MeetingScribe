import AVFoundation
import XCTest
@testable import MeetingScribe

final class WhisperAudioReaderTests: XCTestCase {
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
