import AVFoundation
import CoreMedia
import Foundation

enum AudioClock {
    static func seconds(for sampleBuffer: CMSampleBuffer) -> Double {
        sampleBuffer.presentationTimeStamp.seconds
    }

    static func seconds(for audioTime: AVAudioTime) -> Double {
        guard audioTime.isHostTimeValid else {
            return ProcessInfo.processInfo.systemUptime
        }

        return AVAudioTime.seconds(forHostTime: audioTime.hostTime)
    }
}
