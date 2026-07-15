import Foundation

struct TranscriptionProvenance: Codable, Equatable, Sendable {
    let engine: String
    let engineVersion: String?
    let model: String
    let modelRevision: String?
    let modelVariant: String?
    let configurationRevision: String?

    init(
        engine: String,
        engineVersion: String?,
        model: String,
        modelRevision: String?,
        modelVariant: String? = nil,
        configurationRevision: String?
    ) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.model = model
        self.modelRevision = modelRevision
        self.modelVariant = modelVariant
        self.configurationRevision = configurationRevision
    }

    static func fluidAudioParakeetV3(
        descriptor: FluidAudioModelDescriptor = .parakeetV3
    ) -> TranscriptionProvenance {
        TranscriptionProvenance(
            engine: "FluidAudio",
            engineVersion: FluidAudioTranscriptionConfiguration.sdkVersion,
            model: descriptor.repository,
            modelRevision: descriptor.revision,
            modelVariant: descriptor.variant,
            configurationRevision: FluidAudioTranscriptionConfiguration.current.revision
        )
    }
}

/// Runtime-only reference to a prepared engine model or model bundle.
///
/// Persisted code consumes `provenance`, never the device-specific bundle path.
struct TranscriptionModelReference: Equatable, Sendable {
    let location: URL
    let provenance: TranscriptionProvenance

    static func fluidAudioParakeetV3(
        bundleURL: URL,
        descriptor: FluidAudioModelDescriptor = .parakeetV3
    ) -> TranscriptionModelReference {
        TranscriptionModelReference(
            location: bundleURL,
            provenance: .fluidAudioParakeetV3(descriptor: descriptor)
        )
    }
}

struct SpeechTranscriptionRequest: Equatable, Sendable {
    let audioURL: URL
    let model: TranscriptionModelReference
    let options: TranscriptionOptions
}

protocol SpeechTranscribing: Sendable {
    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> TrackTranscript

    func releaseResources() async
}

extension SpeechTranscribing {
    func releaseResources() async {}
}

enum TranscriptSanitizer {
    private static let nonSpeechMarkers: Set<String> = [
        "[blank_audio]",
        "[silence]",
        "(silence)",
    ]

    static func meaningfulText(from rawText: String) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !nonSpeechMarkers.contains(text.lowercased()) else { return nil }
        return text
    }
}

enum TranscriptionError: Error, LocalizedError {
    case invalidAudioFormat(sampleRate: Double, channelCount: Int)
    case emptyAudio
    case modelBundleCouldNotBeLoaded(name: String)
    case engineInferenceFailed(engine: String, detail: String)
    case unsupportedEngine(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAudioFormat(sampleRate, channelCount):
            return "Transcription requires 16 kHz mono audio, but received \(sampleRate) Hz with \(channelCount) channels."
        case .emptyAudio:
            return "The working audio file contains no samples."
        case let .modelBundleCouldNotBeLoaded(name):
            return "The transcription model bundle \(name) could not be loaded."
        case let .engineInferenceFailed(engine, detail):
            return "\(engine) transcription failed: \(detail)"
        case let .unsupportedEngine(engine):
            return "The transcription engine \(engine) is not supported by this service."
        }
    }
}
