import AVFoundation
import FluidAudio
import Foundation

struct FluidAudioDiarizationConfiguration: Codable, Equatable, Sendable {
    static let sdkVersion = "0.15.5"
    static let current = FluidAudioDiarizationConfiguration(
        revision: "community-1-offline-v1"
    )

    let revision: String
}

protocol FluidAudioDiarizationRunning: Sendable {
    func diarize(
        audioURL: URL,
        modelBundleURL: URL,
        options: SpeakerDiarizationOptions
    ) async throws -> [RawSpeakerDiarizationSegment]

    func releaseResources() async
}

actor ProductionFluidAudioDiarizationRunner: FluidAudioDiarizationRunning {
    private final class ManagerBox: @unchecked Sendable {
        let value: OfflineDiarizerManager

        init(_ value: OfflineDiarizerManager) {
            self.value = value
        }
    }

    private var managerBox: ManagerBox?
    private var loadedModelsRoot: URL?
    private var loadedOptions: SpeakerDiarizationOptions?

    func diarize(
        audioURL: URL,
        modelBundleURL: URL,
        options: SpeakerDiarizationOptions
    ) async throws -> [RawSpeakerDiarizationSegment] {
        try Task.checkCancellation()
        let managerBox = try await preparedManager(
            modelBundleURL: modelBundleURL,
            options: options
        )
        do {
            let result = try await managerBox.value.process(audioURL)
            try Task.checkCancellation()
            return result.segments.map { segment in
                RawSpeakerDiarizationSegment(
                    speakerID: segment.speakerId,
                    start: Double(segment.startTimeSeconds),
                    end: Double(segment.endTimeSeconds),
                    confidence: Double(segment.qualityScore)
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        } catch {
            throw FluidAudioDiarizationError.inferenceFailed(error.localizedDescription)
        }
    }

    func releaseResources() async {
        managerBox = nil
        loadedModelsRoot = nil
        loadedOptions = nil
    }

    private func preparedManager(
        modelBundleURL: URL,
        options: SpeakerDiarizationOptions
    ) async throws -> ManagerBox {
        let modelsRoot = modelBundleURL.deletingLastPathComponent().standardizedFileURL
        if let managerBox,
           loadedModelsRoot == modelsRoot,
           loadedOptions == options {
            return managerBox
        }

        await releaseResources()
        ModelHub.offlineMode = true
        var config = OfflineDiarizerConfig.default
        if let exact = options.exactSpeakerCount {
            config = config.withSpeakers(exactly: exact)
        } else if options.minimumSpeakers != nil || options.maximumSpeakers != nil {
            config = config.withSpeakers(
                min: options.minimumSpeakers,
                max: options.maximumSpeakers
            )
        }
        let models: OfflineDiarizerModels
        do {
            models = try await OfflineDiarizerModels.load(from: modelsRoot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FluidAudioDiarizationError.modelCouldNotBeLoaded(
                modelBundleURL.lastPathComponent
            )
        }
        try Task.checkCancellation()
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let managerBox = ManagerBox(manager)
        self.managerBox = managerBox
        loadedModelsRoot = modelsRoot
        loadedOptions = options
        return managerBox
    }
}

actor FluidAudioDiarizationService: SpeakerDiarizing {
    private let runner: any FluidAudioDiarizationRunning
    private let configuration: FluidAudioDiarizationConfiguration
    private let audioDuration: @Sendable (URL) throws -> Double

    init(
        runner: any FluidAudioDiarizationRunning = ProductionFluidAudioDiarizationRunner(),
        configuration: FluidAudioDiarizationConfiguration = .current,
        audioDuration: @escaping @Sendable (URL) throws -> Double = { url in
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate > 0 else { return 0 }
            return Double(file.length) / file.processingFormat.sampleRate
        }
    ) {
        self.runner = runner
        self.configuration = configuration
        self.audioDuration = audioDuration
    }

    func diarize(
        _ request: SpeakerDiarizationRequest
    ) async throws -> SpeakerDiarizationResult {
        try Task.checkCancellation()
        let duration = try audioDuration(request.audioURL)
        guard duration > 0, duration.isFinite else {
            throw FluidAudioDiarizationError.invalidAudioDuration
        }
        let segments = try await runner.diarize(
            audioURL: request.audioURL,
            modelBundleURL: request.modelBundleURL,
            options: request.options
        )
        try Task.checkCancellation()
        if segments.isEmpty {
            return SpeakerDiarizationResult(
                engine: "FluidAudio",
                engineVersion: FluidAudioDiarizationConfiguration.sdkVersion,
                model: "community-1",
                audioDurationSeconds: duration,
                segments: []
            )
        }
        return try SpeakerDiarizationNormalizer().normalize(
            engine: "FluidAudio",
            engineVersion: FluidAudioDiarizationConfiguration.sdkVersion,
            model: "community-1",
            audioDurationSeconds: duration,
            segments: segments
        )
    }

    func releaseResources() async {
        await runner.releaseResources()
    }
}

enum FluidAudioDiarizationError: Error, Equatable, LocalizedError {
    case invalidAudioDuration
    case modelCouldNotBeLoaded(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudioDuration:
            return "The system audio duration is invalid for speaker diarization."
        case let .modelCouldNotBeLoaded(name):
            return "The FluidAudio diarization model \(name) could not be loaded offline."
        case let .inferenceFailed(detail):
            return "FluidAudio speaker diarization failed: \(detail)"
        }
    }
}
