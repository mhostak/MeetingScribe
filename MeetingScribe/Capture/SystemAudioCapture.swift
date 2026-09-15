import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, AudioCaptureService, @unchecked Sendable {
    private struct State {
        var isCapturing = false
        var isStarting = false
        var stream: SCStream?
        var writer: AudioFileWriter?
        var diagnostics = AudioCaptureDiagnostics.empty
    }

    private let callbackQueue = DispatchQueue(
        label: "com.martinhostak.MeetingScribe.system-audio",
        qos: .userInitiated
    )
    private var state = State()

    func start(outputURL: URL) async throws {
        let reservedStart = callbackQueue.sync {
            guard !state.isCapturing, !state.isStarting else { return false }
            state.isStarting = true
            return true
        }
        guard reservedStart else {
            throw AudioCaptureServiceError.alreadyCapturing
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            callbackQueue.sync { state.isStarting = false }
            throw AudioCaptureServiceError.screenRecordingPermissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            callbackQueue.sync { state.isStarting = false }
            throw Self.startError(for: error)
        }
        guard let display = preferredDisplay(from: content.displays) else {
            callbackQueue.sync { state.isStarting = false }
            throw AudioCaptureServiceError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = makeConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
        } catch {
            callbackQueue.sync { state.isStarting = false }
            throw error
        }

        callbackQueue.sync {
            state = State(
                isCapturing: true,
                isStarting: false,
                stream: stream,
                writer: AudioFileWriter(outputURL: outputURL),
                diagnostics: AudioCaptureDiagnostics(
                    fileName: outputURL.lastPathComponent,
                    startedAt: Date()
                )
            )
        }
        do {
            try await stream.startCapture()
        } catch {
            let startError = Self.startError(for: error)
            callbackQueue.sync {
                finishWriter()
                state.isCapturing = false
                state.isStarting = false
                state.stream = nil
                state.diagnostics.failureReason = startError.localizedDescription
            }
            throw startError
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        guard let stream = callbackQueue.sync(execute: { state.stream }) else {
            return callbackQueue.sync { state.diagnostics }
        }

        do {
            try await stream.stopCapture()
        } catch {
            if !Self.isBenignStopError(error) {
                callbackQueue.sync {
                    state.diagnostics.failureReason = error.localizedDescription
                }
            }
        }

        return callbackQueue.sync {
            guard state.stream === stream else { return state.diagnostics }
            finishWriter()
            state.isCapturing = false
            state.stream = nil
            return state.diagnostics
        }
    }

    func diagnostics() async -> AudioCaptureDiagnostics {
        callbackQueue.sync { state.diagnostics }
    }

    private func preferredDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        return configuration
    }

    static func isBenignStopError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else { return false }

        // -3808: stop requested for an already stopped stream.
        // -3817: the user stopped capture through the system capture control.
        return error.code == -3_808 || error.code == -3_817
    }

    static func startError(for error: Error) -> Error {
        let error = error as NSError

        // SCStreamErrorUserDeclined (-3801) can be returned while loading
        // shareable content or while starting the stream, even after preflight.
        guard error.domain == SCStreamErrorDomain, error.code == -3_801 else {
            return error
        }
        return AudioCaptureServiceError.screenRecordingPermissionDenied
    }

    private func finishWriter() {
        guard let writer = state.writer else { return }
        do {
            try writer.finish()
        } catch {
            if state.diagnostics.failureReason == nil {
                state.diagnostics.failureReason = error.localizedDescription
            }
        }
        state.writer = nil
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, state.isCapturing else { return }

        let presentationTimestamp = AudioClock.seconds(for: sampleBuffer)

        do {
            guard let writer = state.writer else {
                throw AudioCaptureServiceError.notCapturing
            }

            let result = try writer.write(sampleBuffer)
            guard result.frameCount > 0 else { return }
            state.diagnostics.registerBuffer(
                frameCount: result.frameCount,
                sampleRate: result.sampleRate,
                channelCount: result.channelCount,
                presentationTimestamp: presentationTimestamp,
                audioLevel: result.audioLevel
            )
        } catch {
            state.diagnostics.failureReason = error.localizedDescription
            finishWriter()
        }
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            if !Self.isBenignStopError(error) {
                self.state.diagnostics.failureReason = error.localizedDescription
            }
            self.finishWriter()
            self.state.isCapturing = false
            self.state.stream = nil
        }
    }
}
