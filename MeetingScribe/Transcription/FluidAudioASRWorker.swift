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

/// Why a worker run failed, carried back across the process boundary.
///
/// An exit code alone cannot tell a missing model bundle apart from a
/// corrupted one, and those need different things from the user: install the
/// model, or repair it. The worker therefore writes the description of the
/// error it caught, and only that description — it carries engine and model
/// identifiers, never audio or transcript text.
struct FluidAudioASRWorkerFailure: Codable, Sendable {
    static let schemaVersion = 1
    /// Long enough for a Core ML load failure, short enough that a runaway
    /// description cannot become the recording's error message.
    static let maximumDescriptionLength = 600

    let schemaVersion: Int
    let description: String

    init(description: String) {
        self.schemaVersion = Self.schemaVersion
        self.description = String(description.prefix(Self.maximumDescriptionLength))
    }
}

enum FluidAudioASRWorkerError: Error, LocalizedError {
    case executableUnavailable
    case workerAlreadyRunning
    case workerFailed(exitCode: Int32, reason: String?)
    case invalidWorkerRequest

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "The transcription worker executable is unavailable."
        case .workerAlreadyRunning:
            return "The transcription worker is already running."
        case let .workerFailed(exitCode, reason):
            guard let reason, !reason.isEmpty else {
                return "The transcription worker stopped with exit code \(exitCode)."
            }
            return reason
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
        let failureURL = directory.appendingPathComponent("failure.json")
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
                    "--failure", failureURL.path,
                ]
            )
        } onCancel: {
            controller.cancel()
        }
        try Task.checkCancellation()
        guard exitCode == 0 else {
            throw FluidAudioASRWorkerError.workerFailed(
                exitCode: exitCode,
                reason: Self.reportedFailure(at: failureURL)
            )
        }
        return try JSONDecoder().decode(
            FluidAudioASROutput.self,
            from: Data(contentsOf: responseURL)
        )
    }

    /// A worker that died before it could write the file, or wrote something
    /// unreadable, leaves the exit code as the only thing to report. That is
    /// the same outcome as before this file existed, so a missing or damaged
    /// report is not itself an error.
    private static func reportedFailure(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let failure = try? JSONDecoder().decode(FluidAudioASRWorkerFailure.self, from: data),
              failure.schemaVersion == FluidAudioASRWorkerFailure.schemaVersion
        else {
            return nil
        }
        let trimmed = failure.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        guard payload.count >= 4,
              payload[0] == "--request",
              payload[2] == "--response" else {
            return 64
        }

        let requestURL = URL(fileURLWithPath: payload[1])
        let responseURL = URL(fileURLWithPath: payload[3])
        // A parent from an older build does not pass this argument. The worker
        // stays usable for it and simply reports nothing beyond its exit code.
        let failureURL: URL? = payload.count >= 6 && payload[4] == "--failure"
            ? URL(fileURLWithPath: payload[5])
            : nil
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
                // Without this the parent could only say "exit code 1", which
                // cannot distinguish a model that is missing from one that is
                // corrupted — and those need opposite things from the user.
                report(error, to: failureURL)
                return 1
            }
        } catch {
            report(error, to: failureURL)
            return 64
        }
    }

    private static func report(_ error: Error, to url: URL?) {
        guard let url else { return }
        let failure = FluidAudioASRWorkerFailure(
            description: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        )
        // The worker is already failing; a failure to describe the failure
        // must not change its exit code.
        try? JSONEncoder().encode(failure).write(to: url, options: .atomic)
    }
}

/// Owns the worker process for one transcription at a time.
///
/// Cancellation is scoped to a single run. A latched flag used to outlive its
/// run: a cancellation that arrived while no process was attached stayed set and
/// terminated the *next* worker within a second of starting it. Because the new
/// run's task was no longer cancelled, that SIGTERM surfaced as
/// `workerFailed(exitCode: 15)` and the queue recorded a permanent failure
/// instead of a pause.
final class FluidAudioASRWorkerProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let terminationGracePeriod: TimeInterval
    private var process: Process?
    private var generation = 0
    private var cancelledGeneration: Int?

    init(terminationGracePeriod: TimeInterval) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
    }

    func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
        let generation = beginRun()
        return try await Task.detached(priority: .utility) { [self] in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard attach(process, generation: generation) else {
                // Cancelled before the worker existed: never spawn it.
                throw CancellationError()
            }
            do {
                try process.run()
                terminateIfRequested(process, generation: generation)
                process.waitUntilExit()
                let status = process.terminationStatus
                // A termination this controller asked for is a cancellation, not
                // a worker failure, and must not be reported as an exit code.
                if detach(process, generation: generation) { throw CancellationError() }
                return status
            } catch {
                _ = detach(process, generation: generation)
                throw error
            }
        }.value
    }

    func cancel() {
        lock.lock()
        cancelledGeneration = generation
        let process = process
        lock.unlock()
        terminate(process)
    }

    /// Starts a new cancellation scope, discarding any cancellation that
    /// belonged to a finished run.
    private func beginRun() -> Int {
        lock.lock()
        generation += 1
        cancelledGeneration = nil
        let generation = generation
        lock.unlock()
        return generation
    }

    private func attach(_ process: Process, generation: Int) -> Bool {
        lock.lock()
        let isCancelled = cancelledGeneration == generation
        if !isCancelled { self.process = process }
        lock.unlock()
        return !isCancelled
    }

    /// Detaches and reports whether this run was cancelled.
    private func detach(_ process: Process, generation: Int) -> Bool {
        lock.lock()
        if self.process === process { self.process = nil }
        let wasCancelled = cancelledGeneration == generation
        lock.unlock()
        return wasCancelled
    }

    private func terminateIfRequested(_ process: Process, generation: Int) {
        lock.lock()
        let shouldCancel = cancelledGeneration == generation && self.process === process
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
