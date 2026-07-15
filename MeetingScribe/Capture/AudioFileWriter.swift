import AVFoundation
import CoreMedia
import Foundation

/// Incrementally converts capture buffers into transcription-ready PCM and stores
/// them in a crash-recoverable WAV file.
///
/// AVAudioFile only finalizes the WAV length fields when it is closed. A hard
/// process termination can therefore leave all PCM bytes on disk behind a
/// zero-length header. This writer owns the minimal PCM WAV container itself,
/// checkpoints its length fields once per second, and lets recovery repair the
/// header from the physical file length.
final class AudioFileWriter {
    private final class ConversionInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var wasSupplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    struct WriteResult: Equatable {
        let frameCount: Int
        let sampleRate: Double
        let channelCount: Int
    }

    static let targetSampleRate = 16_000.0
    static let targetChannelCount: AVAudioChannelCount = 1
    static let targetBitsPerChannel: UInt16 = 16

    private static let headerSize: UInt64 = 44
    private static let checkpointFrameInterval = UInt64(targetSampleRate)
    private static let maximumEmptyDrainCycles = 2

    private let outputURL: URL
    private let fileManager: FileManager
    private let outputFormat: AVAudioFormat
    private var fileHandle: FileHandle?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var totalFrames: UInt64 = 0
    private var framesAtLastCheckpoint: UInt64 = 0
    private var isFinished = false

    init(outputURL: URL, fileManager: FileManager = .default) {
        self.outputURL = outputURL
        self.fileManager = fileManager
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: true
        )!
    }

    func write(_ sampleBuffer: CMSampleBuffer) throws -> WriteResult {
        guard
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        return try sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: audioBufferList.unsafePointer,
                deallocator: nil
            ) else {
                throw AudioCaptureServiceError.unableToCreateAudioBuffer
            }

            pcmBuffer.frameLength = min(AVAudioFrameCount(frameCount), pcmBuffer.frameCapacity)
            return try write(pcmBuffer)
        }
    }

    func write(_ pcmBuffer: AVAudioPCMBuffer) throws -> WriteResult {
        guard !isFinished else { throw PCMFileWriterError.writerFinished }
        guard pcmBuffer.frameLength > 0,
              pcmBuffer.format.sampleRate > 0,
              pcmBuffer.format.channelCount > 0 else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }

        try prepareFileIfNeeded()
        try prepareConverter(for: pcmBuffer.format)
        guard let converter else { throw AudioCaptureServiceError.invalidAudioFormat }

        let writtenFrames = try convertAndWrite(pcmBuffer, using: converter)
        try checkpointIfNeeded()
        return WriteResult(
            frameCount: writtenFrames,
            sampleRate: Self.targetSampleRate,
            channelCount: Int(Self.targetChannelCount)
        )
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        do {
            try drainConverter()
            try checkpoint(force: true)
            try fileHandle?.close()
        } catch {
            try? fileHandle?.close()
        }
        fileHandle = nil
        converter = nil
        inputFormat = nil
    }

    private func prepareFileIfNeeded() throws {
        guard fileHandle == nil else { return }
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try Self.makeHeader(dataByteCount: 0).write(to: outputURL, options: .atomic)
        let handle = try FileHandle(forUpdating: outputURL)
        try handle.seekToEnd()
        fileHandle = handle
    }

    private func prepareConverter(for format: AVAudioFormat) throws {
        if inputFormat == format, converter != nil { return }
        if converter != nil {
            try drainConverter()
        }
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw AudioCaptureServiceError.invalidAudioFormat
        }
        self.converter = converter
        inputFormat = format
    }

    private func convertAndWrite(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) throws -> Int {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let estimatedFrames = ceil(Double(inputBuffer.frameLength) * ratio)
        let outputCapacity = AVAudioFrameCount(max(256, estimatedFrames + 64))
        let input = ConversionInput(buffer: inputBuffer)
        var writtenFrames = 0

        for _ in 0..<16 {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw AudioCaptureServiceError.unableToCreateAudioBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                guard !input.wasSupplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                input.wasSupplied = true
                inputStatus.pointee = .haveData
                return input.buffer
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                try append(outputBuffer)
                writtenFrames += Int(outputBuffer.frameLength)
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return writtenFrames
            case .error:
                throw AudioCaptureServiceError.invalidAudioFormat
            @unknown default:
                throw AudioCaptureServiceError.invalidAudioFormat
            }
        }
        throw AudioCaptureServiceError.invalidAudioFormat
    }

    private func drainConverter() throws {
        guard let converter else { return }
        var emptyCycles = 0

        for _ in 0..<16 {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 4_096
            ) else {
                throw AudioCaptureServiceError.unableToCreateAudioBuffer
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                try append(outputBuffer)
                emptyCycles = 0
            } else {
                emptyCycles += 1
            }

            if status == .endOfStream
                || (status == .inputRanDry && emptyCycles >= Self.maximumEmptyDrainCycles) {
                break
            }
            if status == .error { throw AudioCaptureServiceError.invalidAudioFormat }
        }
        self.converter = nil
        inputFormat = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let fileHandle,
              let data = buffer.audioBufferList.pointee.mBuffers.mData else {
            throw PCMFileWriterError.unavailablePCMData
        }
        let byteCount = Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        let expectedByteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount >= expectedByteCount else {
            throw PCMFileWriterError.unavailablePCMData
        }
        let nextDataByteCount = try Self.checkedDataByteCount(
            frameCount: totalFrames + UInt64(buffer.frameLength)
        )
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data(bytes: data, count: expectedByteCount))
        totalFrames = UInt64(nextDataByteCount) / UInt64(MemoryLayout<Int16>.size)
    }

    private func checkpointIfNeeded() throws {
        guard totalFrames - framesAtLastCheckpoint >= Self.checkpointFrameInterval else { return }
        try checkpoint(force: false)
    }

    private func checkpoint(force: Bool) throws {
        guard let fileHandle else { return }
        guard force || totalFrames != framesAtLastCheckpoint else { return }
        let dataByteCount = try Self.checkedDataByteCount(frameCount: totalFrames)
        let endOffset = try fileHandle.seekToEnd()
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.makeHeader(dataByteCount: dataByteCount))
        try fileHandle.seek(toOffset: endOffset)
        try fileHandle.synchronize()
        framesAtLastCheckpoint = totalFrames
    }

    fileprivate static func checkedDataByteCount(frameCount: UInt64) throws -> UInt32 {
        let byteCount = frameCount * UInt64(MemoryLayout<Int16>.size)
        guard byteCount <= UInt64(UInt32.max) - 36 else {
            throw PCMFileWriterError.fileTooLarge
        }
        return UInt32(byteCount)
    }

    fileprivate static func makeHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append(Data("RIFF".utf8))
        appendLittleEndian(36 + dataByteCount, to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(targetChannelCount), to: &data)
        appendLittleEndian(UInt32(targetSampleRate), to: &data)
        appendLittleEndian(UInt32(targetSampleRate) * UInt32(MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(UInt16(MemoryLayout<Int16>.size), to: &data)
        appendLittleEndian(targetBitsPerChannel, to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(dataByteCount, to: &data)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

struct PCMRecordingFileRepairer: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Repairs only MeetingScribe's canonical 44-byte PCM WAV header. Other WAV
    /// layouts are left untouched and will be validated by AVAudioFile later.
    @discardableResult
    func repairIfNeeded(at url: URL) throws -> Bool {
        guard url.pathExtension.lowercased() == "wav",
              fileManager.fileExists(atPath: url.path) else { return false }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value >= 44 else { return false }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 44),
              header.count == 44,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE",
              String(data: header[12..<16], encoding: .ascii) == "fmt ",
              String(data: header[36..<40], encoding: .ascii) == "data",
              readLittleEndian(UInt16.self, from: header, at: 20) == 1,
              readLittleEndian(UInt16.self, from: header, at: 22) == 1,
              readLittleEndian(UInt32.self, from: header, at: 24) == 16_000,
              readLittleEndian(UInt16.self, from: header, at: 32) == 2,
              readLittleEndian(UInt16.self, from: header, at: 34) == 16
        else { return false }

        let alignedSize = size.uint64Value - ((size.uint64Value - 44) % 2)
        if alignedSize != size.uint64Value {
            try handle.truncate(atOffset: alignedSize)
        }
        let dataByteCount = alignedSize - 44
        guard dataByteCount <= UInt64(UInt32.max) - 36 else {
            throw PCMFileWriterError.fileTooLarge
        }
        let expectedHeader = AudioFileWriter.makeHeader(dataByteCount: UInt32(dataByteCount))
        guard header != expectedHeader else { return false }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: expectedHeader)
        try handle.synchronize()
        return true
    }

    private func readLittleEndian<T: FixedWidthInteger>(
        _ type: T.Type,
        from data: Data,
        at offset: Int
    ) -> T {
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(littleEndian: raw)
    }
}

enum PCMFileWriterError: Error, LocalizedError {
    case writerFinished
    case unavailablePCMData
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .writerFinished:
            return "The audio writer has already finished."
        case .unavailablePCMData:
            return "The converted PCM buffer has no readable sample data."
        case .fileTooLarge:
            return "The PCM WAV file exceeded the supported RIFF size."
        }
    }
}
