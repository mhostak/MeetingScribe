import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCapture: NSObject, AudioCaptureService, @unchecked Sendable {
    private struct State {
        var isCapturing = false
        var writer: AudioFileWriter?
        var diagnostics = AudioCaptureDiagnostics.empty
    }

    private let callbackQueue = DispatchQueue(
        label: "com.martinhostak.MeetingScribe.system-audio",
        qos: .userInitiated
    )
    private var state = State()
    private var stream: SCStream?

    func start(outputURL: URL) async throws {
        let isAlreadyCapturing = callbackQueue.sync { state.isCapturing }
        guard !isAlreadyCapturing else {
            throw AudioCaptureServiceError.alreadyCapturing
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw AudioCaptureServiceError.screenRecordingPermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = preferredDisplay(from: content.displays) else {
            throw AudioCaptureServiceError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = makeConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)

        callbackQueue.sync {
            state = State(
                isCapturing: true,
                writer: AudioFileWriter(outputURL: outputURL),
                diagnostics: AudioCaptureDiagnostics(
                    fileName: outputURL.lastPathComponent,
                    startedAt: Date()
                )
            )
        }
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            callbackQueue.sync {
                finishWriter()
                state.isCapturing = false
                state.diagnostics.failureReason = error.localizedDescription
            }
            self.stream = nil
            throw error
        }
    }

    func stop() async -> AudioCaptureDiagnostics {
        guard let stream else {
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

        self.stream = nil
        return callbackQueue.sync {
            finishWriter()
            state.isCapturing = false
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
                presentationTimestamp: presentationTimestamp
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
        }
    }
}
