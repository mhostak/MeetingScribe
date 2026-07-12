import AVFoundation
import CoreMedia
import Foundation

/// Normalizes capture timestamps without mixing clock domains.
///
/// ScreenCaptureKit supplies the system track as a Core Media presentation
/// timestamp. The microphone track is accepted only when `AVAudioTime` carries
/// a valid mach host-time value. Missing timestamps remain `nil`; sample time
/// and `systemUptime` are deliberately not substituted because their origins
/// cannot be compared safely with the capture presentation timeline.
enum AudioClock {
    /// Returns a finite presentation timestamp without inventing a value when
    /// Core Media marks the sample time as invalid.
    static func seconds(for sampleBuffer: CMSampleBuffer) -> Double? {
        seconds(for: sampleBuffer.presentationTimeStamp)
    }

    static func seconds(for time: CMTime) -> Double? {
        guard time.isValid else { return nil }
        let value = time.seconds
        return value.isFinite ? value : nil
    }

    /// Converts only a valid mach host-time value. A sample-time-only
    /// `AVAudioTime` has a different origin and must not be substituted into
    /// the shared capture timeline.
    static func seconds(for audioTime: AVAudioTime) -> Double? {
        guard audioTime.isHostTimeValid else { return nil }
        let value = AVAudioTime.seconds(forHostTime: audioTime.hostTime)
        return value.isFinite ? value : nil
    }
}
