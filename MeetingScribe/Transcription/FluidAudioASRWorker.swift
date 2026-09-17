import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The parent application launches this helper using its own executable. The
/// protocol intentionally contains only paths and ASR configuration, never a
/// transcript or UI state. A response is atomically written only after a whole
/// track completed, so cancellation has a whole-track checkpoint.
private struct FluidAudioASRWorkerRequest: Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let audioPath: String
    let modelBundlePath: String
    let language: TranscriptionLanguage
    let configuration: FluidAudioTranscriptionConfiguration
}

enum FluidAudioASRWorkerError: Error, LocalizedError {
    case executableUnavailable
    case workerAlreadyRunning
    case workerFailed(exitCode: Int32)
    case invalidWorkerRequest

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "The transcription worker executable is unavailable."
        case .workerAlreadyRunning:
            return "The transcription worker is already running."
        case let .workerFailed(exitCode):
            return "The transcription worker stopped with exit code \(exitCode)."
        case .invalidWorkerRequest:
            return "The transcription worker received an invalid request."
        }
    }
}

protocol FluidAudioASRWorkerRunning: Sendable {
    func transcribe(
        audioURL: URL,
        modelBundleURL: URL,
        language: TranscriptionLanguage,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> FluidAudioASROutput

    /// Cancellation is synchronous because it may be called by a task
    /// cancellation handler. It only signals a process owned by this runner.
    func releaseResources() async
}

/// Production isolation boundary for Core ML. The app process never creates an
/// AsrManager; killing this worker releases model memory even when the SDK is
/// currently inside a non-preemptible prediction call.
actor ProductionFluidAudioASRRunner: FluidAudioASRRunning {
    private let worker: any FluidAudioASRWorkerRunning

    init(worker: any FluidAudioASRWorkerRunning = FluidAudioASRWorkerProcessRunner()) {
        self.worker = worker
    }

    func transcribe(
        audioURL: URL,
        modelBundleURL: URL,
        language: TranscriptionLanguage,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> FluidAudioASROutput {
        try await worker.transcribe(
            audioURL: audioURL,
            modelBundleURL: modelBundleURL,
            language: language,
            configuration: configuration
        )
    }

    func releaseResources() async {
        await worker.releaseResources()
    }
}

actor FluidAudioASRWorkerProcessRunner: FluidAudioASRWorkerRunning {
    private let executableURL: @Sendable () -> URL?
    private let controller: FluidAudioASRWorkerProcessController
    private var isRunning = false

    init(
        executableURL: @escaping @Sendable () -> URL? = { Bundle.main.executableURL },
        terminationGracePeriod: TimeInterval = 2
    ) {
        self.executableURL = executableURL
        self.controller = FluidAudioASRWorkerProcessController(
            terminationGracePeriod: terminationGracePeriod
        )
    }

    func transcribe(
        audioURL: URL,
        modelBundleURL: URL,
        language: TranscriptionLanguage,
        configuration: FluidAudioTranscriptionConfiguration
    ) async throws -> FluidAudioASROutput {
        guard !isRunning else { throw FluidAudioASRWorkerError.workerAlreadyRunning }
        guard let executableURL = executableURL() else {
            throw FluidAudioASRWorkerError.executableUnavailable
        }
        isRunning = true
        defer { isRunning = false }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingScribe-ASRWorker-\(UUID().uuidString)",
            isDirectory: true
        )
        let requestURL = directory.appendingPathComponent("request.json")
        let responseURL = directory.appendingPathComponent("response.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let request = FluidAudioASRWorkerRequest(
            schemaVersion: FluidAudioASRWorkerRequest.schemaVersion,
            audioPath: audioURL.standardizedFileURL.path,
            modelBundlePath: modelBundleURL.standardizedFileURL.path,
            language: language,
            configuration: configuration
        )
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)

        let exitCode = try await withTaskCancellationHandler {
            try await controller.run(
                executableURL: executableURL,
                arguments: [
                    FluidAudioASRWorker.argument,
                    "--request", requestURL.path,
                    "--response", responseURL.path,
                ]
            )
        } onCancel: {
            controller.cancel()
        }
        try Task.checkCancellation()
        guard exitCode == 0 else {
            throw FluidAudioASRWorkerError.workerFailed(exitCode: exitCode)
        }
        return try JSONDecoder().decode(
            FluidAudioASROutput.self,
            from: Data(contentsOf: responseURL)
        )
    }

    func releaseResources() async {
        // The queue must await the cancelled transcription task before marking
        // a job paused. This signal alone is intentionally not a pause claim.
        controller.cancel()
    }
}

/// This function is called before SwiftUI creates AppState. Returning `nil`
/// means that the executable was launched normally rather than as a worker.
enum FluidAudioASRWorker {
    static let argument = "--meetingscribe-fluid-audio-worker"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) async -> Int32? {
        guard let argumentIndex = arguments.firstIndex(of: argument) else { return nil }
        let payload = Array(arguments.dropFirst(argumentIndex + 1))
        guard payload.count == 4,
              payload[0] == "--request",
              payload[2] == "--response" else {
            return 64
        }

        let requestURL = URL(fileURLWithPath: payload[1])
        let responseURL = URL(fileURLWithPath: payload[3])
        do {
            let request = try JSONDecoder().decode(
                FluidAudioASRWorkerRequest.self,
                from: Data(contentsOf: requestURL)
            )
            guard request.schemaVersion == FluidAudioASRWorkerRequest.schemaVersion else {
                throw FluidAudioASRWorkerError.invalidWorkerRequest
            }
            let runner = InProcessFluidAudioASRRunner()
            do {
                let output = try await runner.transcribe(
                    audioURL: URL(fileURLWithPath: request.audioPath),
                    modelBundleURL: URL(fileURLWithPath: request.modelBundlePath),
                    language: request.language,
                    configuration: request.configuration
                )
                await runner.releaseResources()
                try JSONEncoder().encode(output).write(to: responseURL, options: .atomic)
                return 0
            } catch {
                await runner.releaseResources()
                return 1
            }
        } catch {
            return 64
        }
    }
}

private final class FluidAudioASRWorkerProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let terminationGracePeriod: TimeInterval
    private var process: Process?
    private var cancellationRequested = false

    init(terminationGracePeriod: TimeInterval) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
    }

    func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
        try await Task.detached(priority: .utility) { [self] in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            attach(process)
            do {
                try process.run()
                terminateIfRequested(process)
                process.waitUntilExit()
                detach(process)
                return process.terminationStatus
            } catch {
                detach(process)
                throw error
            }
        }.value
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = process
        lock.unlock()
        terminate(process)
    }

    private func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { terminate(process) }
    }

    private func detach(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        cancellationRequested = false
        lock.unlock()
    }

    private func terminateIfRequested(_ process: Process) {
        lock.lock()
        let shouldCancel = cancellationRequested && self.process === process
        lock.unlock()
        if shouldCancel { terminate(process) }
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(
            deadline: .now() + terminationGracePeriod
        ) { [weak self, weak process] in
            self?.forceKillIfStillOwned(process)
        }
    }

    private func forceKillIfStillOwned(_ process: Process?) {
        guard let process, process.isRunning else { return }
        lock.lock()
        let isOwned = self.process === process
        lock.unlock()
        guard isOwned else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #endif
    }
}
