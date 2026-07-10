import AVFoundation
import Foundation

final class MicrophoneCapture: AudioCaptureService, @unchecked Sendable {
    private struct TransferredPCMBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
    }

    private struct State {
        var isCapturing = false
        var writer: AudioFileWriter?
        var diagnostics = AudioCaptureDiagnostics.empty
    }

    private let engine: AVAudioEngine
    private let writerQueue = DispatchQueue(
        label: "com.martinhostak.MeetingScribe.microphone-audio",
        qos: .userInitiated
    )
    private var state = State()

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    func start(outputURL: URL) async throws {
        let isAlreadyCapturing = writerQueue.sync { state.isCapturing }
        guard !isAlreadyCapturing else {
            throw AudioCaptureServiceError.alreadyCapturing
        }

        do {
            try await requestPermissionIfNeeded()
        } catch {
            setStartupFailure(error, outputURL: outputURL)
            throw error
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            let error = AudioCaptureServiceError.microphoneUnavailable
            setStartupFailure(error, outputURL: outputURL)
            throw error
        }

        writerQueue.sync {
            state = State(
                isCapturing: true,
                writer: AudioFileWriter(outputURL: outputURL),
                diagnostics: AudioCaptureDiagnostics(
                    fileName: outputURL.lastPathComponent,
                    startedAt: Date()
                )
            )
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format
        ) { [weak self] buffer, time in
            guard
                let self,
                let copiedBuffer = Self.copy(buffer)
            else {
                return
            }

            let timestamp = AudioClock.seconds(for: time)
            let transferredBuffer = TransferredPCMBuffer(value: copiedBuffer)
            self.writerQueue.async { [weak self] in
                self?.write(
                    transferredBuffer.value,
                    presentationTimestamp: timestamp
                )
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            writerQueue.sync {
                state.diagnostics.failureReason = error.localizedDescription
                state.writer?.finish()
                state.writer = nil
                state.isCapturing = false
            }
            throw error
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        let wasCapturing = writerQueue.sync { state.isCapturing }
        guard wasCapturing else {
            return writerQueue.sync { state.diagnostics }
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        return writerQueue.sync {
            state.writer?.finish()
            state.writer = nil
            state.isCapturing = false
            return state.diagnostics
        }
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        writerQueue.sync { state.diagnostics }
    }

    private func requestPermissionIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw AudioCaptureServiceError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw AudioCaptureServiceError.microphonePermissionDenied
        @unknown default:
            throw AudioCaptureServiceError.microphonePermissionDenied
        }
    }

    private func setStartupFailure(_ error: Error, outputURL: URL) {
        writerQueue.sync {
            state = State(
                isCapturing: false,
                writer: nil,
                diagnostics: AudioCaptureDiagnostics(
                    fileName: outputURL.lastPathComponent,
                    startedAt: Date(),
                    failureReason: error.localizedDescription
                )
            )
        }
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        presentationTimestamp: Double
    ) {
        guard state.isCapturing, let writer = state.writer else { return }

        do {
            let result = try writer.write(buffer)
            state.diagnostics.registerBuffer(
                frameCount: result.frameCount,
                sampleRate: result.sampleRate,
                channelCount: result.channelCount,
                presentationTimestamp: presentationTimestamp
            )
        } catch {
            state.diagnostics.failureReason = error.localizedDescription
            state.writer?.finish()
            state.writer = nil
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            guard
                let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else {
                return nil
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copy
    }
}
