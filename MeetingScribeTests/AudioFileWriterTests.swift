import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingScribe

final class AudioFileWriterTests: XCTestCase {
    func testWritesPCMBufferToReadableCAFFile() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeAudioWriter-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = AudioFileWriter(outputURL: outputURL)
        let result = try writer.write(makeSampleBuffer(frameCount: 480))
        writer.finish()

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(result.frameCount, 480)
        XCTAssertEqual(result.sampleRate, 48_000)
        XCTAssertEqual(result.channelCount, 2)
        XCTAssertEqual(file.length, 480)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }

    func testWritesAVAudioPCMBufferToReadableCAFFile() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeMicrophoneWriter-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 480
        ))
        buffer.frameLength = 480
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = 0.25
        }

        let writer = AudioFileWriter(outputURL: outputURL)
        let result = try writer.write(buffer)
        writer.finish()

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(result.frameCount, 480)
        XCTAssertEqual(result.channelCount, 1)
        XCTAssertEqual(file.length, 480)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
    }

    func testConvertsChangedMicrophoneFormatIntoOriginalCAFFormat() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeRouteChange-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let original = try makePCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800
        )
        let changedRoute = try makePCMBuffer(
            sampleRate: 24_000,
            channels: 1,
            frameCount: 2_400
        )

        let writer = AudioFileWriter(outputURL: outputURL)
        let first = try writer.write(original)
        let second = try writer.write(changedRoute)
        writer.finish()

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(first.sampleRate, 48_000)
        XCTAssertEqual(second.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 48_000, 0.2, accuracy: 0.01)
    }

    func testConvertsChangedSystemSampleBufferFormatIntoOriginalCAFFormat() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeSystemRouteChange-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = AudioFileWriter(outputURL: outputURL)
        let first = try writer.write(makeSampleBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 2
        ))
        let second = try writer.write(makeSampleBuffer(
            frameCount: 2_400,
            sampleRate: 24_000,
            channelCount: 1
        ))
        writer.finish()

        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(first.sampleRate, 48_000)
        XCTAssertEqual(second.sampleRate, 48_000)
        XCTAssertEqual(first.channelCount, 2)
        XCTAssertEqual(second.channelCount, 2)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length) / 48_000, 0.2, accuracy: 0.01)
    }

    private func makePCMBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        for channelIndex in 0..<Int(channels) {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channelIndex])
            for frameIndex in 0..<Int(frameCount) {
                samples[frameIndex] = sin(Float(frameIndex) * 0.02) * 0.25
            }
        }
        return buffer
    }

    private func makeSampleBuffer(
        frameCount: Int,
        sampleRate: Double = 48_000,
        channelCount: Int = 2
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        let byteCount = frameCount * bytesPerFrame
        let samples = [Float](repeating: 0.25, count: frameCount * channelCount)

        var blockBuffer: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ))
        let unwrappedBlockBuffer = try XCTUnwrap(blockBuffer)

        try samples.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: unwrappedBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            ))
        }

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ))

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: unwrappedBlockBuffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ))

        return try XCTUnwrap(sampleBuffer)
    }

    private func check(
        _ status: OSStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard status == noErr else {
            XCTFail("CoreMedia returned OSStatus \(status)", file: file, line: line)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
