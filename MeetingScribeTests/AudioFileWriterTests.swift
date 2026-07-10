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

    private func makeSampleBuffer(frameCount: Int) throws -> CMSampleBuffer {
        let channelCount = 2
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
            mSampleRate: 48_000,
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
            duration: CMTime(value: 1, timescale: 48_000),
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
