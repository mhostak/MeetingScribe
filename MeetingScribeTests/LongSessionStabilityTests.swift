import AVFoundation
import Foundation
import XCTest
@testable import MeetingScribe

final class LongSessionStabilityTests: XCTestCase {
    func testWritesOneHourIncrementallyWhenStressTestIsEnabled() throws {
        guard ProcessInfo.processInfo.environment["MEETINGSCRIBE_STRESS_TEST"] == "1" else {
            throw XCTSkip("Set MEETINGSCRIBE_STRESS_TEST=1 for the one-hour incremental audio test.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeLongSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputURL = root.appendingPathComponent("one-hour.wav")
        let sampleRate = 8_000.0
        let seconds = 3_600
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate)
            )
        )
        buffer.frameLength = AVAudioFrameCount(sampleRate)
        if let samples = buffer.int16ChannelData?[0] {
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        let writer = AudioFileWriter(outputURL: outputURL)

        for _ in 0..<seconds {
            _ = try writer.write(buffer)
        }
        writer.finish()

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(
            file.length,
            AVAudioFramePosition(AudioFileWriter.targetSampleRate * Double(seconds))
        )
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 3_600, accuracy: 0.001)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
        )
        XCTAssertGreaterThan(size.int64Value, 110_000_000)
    }
}
