import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingScribe

final class AudioClockTests: XCTestCase {
    func testConvertsValidHostTimeToFiniteSeconds() throws {
        let hostTime: UInt64 = 1_000_000_000
        let audioTime = AVAudioTime(hostTime: hostTime)

        let seconds = try XCTUnwrap(AudioClock.seconds(for: audioTime))

        XCTAssertEqual(
            seconds,
            AVAudioTime.seconds(forHostTime: hostTime),
            accuracy: 0.000_000_1
        )
    }

    func testRejectsAudioTimeWithoutHostClockInsteadOfUsingSystemUptime() {
        let sampleTimeOnly = AVAudioTime(sampleTime: 42, atRate: 48_000)

        XCTAssertNil(AudioClock.seconds(for: sampleTimeOnly))
    }

    func testRejectsInvalidAndNonfiniteCoreMediaTimes() {
        XCTAssertNil(AudioClock.seconds(for: CMTime.invalid))
        XCTAssertNil(AudioClock.seconds(for: CMTime.indefinite))
        XCTAssertEqual(AudioClock.seconds(for: CMTime(seconds: 12.5, preferredTimescale: 600)), 12.5)
    }
}
