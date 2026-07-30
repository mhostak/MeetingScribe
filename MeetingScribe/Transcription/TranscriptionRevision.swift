import Foundation

enum TranscriptionRevisionStatus: String, Codable, Sendable {
    case completed
    case failed
}

struct TranscriptionRevisionManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let sourceSessionID: String
    let createdAt: Date
    let completedAt: Date
    let status: TranscriptionRevisionStatus
    let provenance: TranscriptionProvenance
    let sourceAudioFingerprints: [String: String]
    let transcriptFiles: SessionTranscriptFiles
    let transcription: SessionTranscriptionMetadata?
    let diarization: SessionDiarizationMetadata?
    let markdownFileName: String?
    let failureReason: String?
}

struct TranscriptionRevisionResult: Equatable, Sendable {
    let directoryURL: URL
    let manifest: TranscriptionRevisionManifest
}

enum TranscriptionRevisionError: Error, LocalizedError {
    case finalizedAudioMissing
    case applicationBusy
    case revisionAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .finalizedAudioMissing:
            return "The recording has no finalized audio that can be reprocessed."
        case .applicationBusy:
            return "Wait for the current recording or processing task to finish before reprocessing."
        case let .revisionAlreadyExists(id):
            return "The transcription revision \(id) already exists."
        }
    }
}

actor FluidAudioTranscriptionRevisionService {
    private let transcriber: any SessionTranscribing
    private let processingFileService: any ProcessingFileServicing
    private let audioFinalizer: any AudioFinalizing
    private let recoveredAudioInspector: RecoveredAudioInspector
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String

    init(
        transcriber: any SessionTranscribing = SessionTranscriber(
            service: FluidAudioTranscriptionService()
        ),
        processingFileService: any ProcessingFileServicing = ProcessingFileService(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        recoveredAudioInspector: RecoveredAudioInspector = RecoveredAudioInspector(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> String = {
            let stamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            return "\(stamp)-fluidaudio-\(UUID().uuidString.prefix(8).lowercased())"
        }
    ) {
        self.transcriber = transcriber
        self.processingFileService = processingFileService
        self.audioFinalizer = audioFinalizer
        self.recoveredAudioInspector = recoveredAudioInspector
        self.fileManager = fileManager
        self.now = now
        self.makeID = makeID
    }

    func reprocess(
        session: RecordingSession,
        modelBundleURL: URL,
        descriptor: FluidAudioModelDescriptor = .parakeetV3
    ) async throws -> TranscriptionRevisionResult {
        let finalization = try await finalizationForReprocessing(session)
        try Task.checkCancellation()

        let fingerprintStore = UtteranceArtifactStore()
        var sourceAudioFingerprints = [
            "system": try fingerprintStore.audioFingerprint(
                at: session.directoryURL.appendingPathComponent(finalization.system.fileName)
            )
        ]
        if let microphone = finalization.microphone {
            sourceAudioFingerprints["microphone"] = try fingerprintStore.audioFingerprint(
                at: session.directoryURL.appendingPathComponent(microphone.fileName)
            )
        }
        let createdAt = now()
        let revisionID = makeID()
        let relativeDirectory = "revisions/\(revisionID)"
        let directoryURL = session.directoryURL.appendingPathComponent(
            relativeDirectory,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            throw TranscriptionRevisionError.revisionAlreadyExists(revisionID)
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let transcriptFiles = SessionTranscriptFiles(
            systemTrack: "\(relativeDirectory)/system-transcript.json",
            microphoneTrack: "\(relativeDirectory)/microphone-transcript.json",
            merged: "\(relativeDirectory)/transcript.json",
            speakerTurns: nil,
            utterances: "\(relativeDirectory)/utterance-transcript.json",
            speakerDiarization: nil,
            resolved: nil,
            analysis: nil
        )
        var revisionMetadata = session.metadata
        revisionMetadata.transcriptFiles = transcriptFiles
        revisionMetadata.transcription = nil
        revisionMetadata.analysis = nil
        revisionMetadata.output = nil
        let revisionSession = RecordingSession(
            metadata: revisionMetadata,
            directoryURL: session.directoryURL
        )
        let provenance = TranscriptionProvenance.fluidAudioParakeetV3(
            descriptor: descriptor
        )

        do {
            let result = try await transcriber.transcribe(
                session: revisionSession,
                finalization: finalization,
                model: .fluidAudioParakeetV3(
                    bundleURL: modelBundleURL,
                    descriptor: descriptor
                ),
                language: session.metadata.language
            )
            try Task.checkCancellation()
            let markdown = try await processingFileService.exportMarkdown(
                session: revisionMetadata,
                transcript: result.mergedTranscript,
                utteranceTranscript: result.utteranceTranscript,
                resolvedTranscript: nil,
                analysis: nil,
                to: directoryURL
            )
            let manifest = TranscriptionRevisionManifest(
                schemaVersion: 2,
                id: revisionID,
                sourceSessionID: session.metadata.id,
                createdAt: createdAt,
                completedAt: now(),
                status: .completed,
                provenance: provenance,
                sourceAudioFingerprints: sourceAudioFingerprints,
                transcriptFiles: transcriptFiles,
                transcription: result.metadata,
                diarization: result.diarizationMetadata,
                markdownFileName: markdown.fileURL.lastPathComponent,
                failureReason: nil
            )
            try persist(manifest, to: directoryURL)
            return TranscriptionRevisionResult(
                directoryURL: directoryURL,
                manifest: manifest
            )
        } catch {
            let manifest = TranscriptionRevisionManifest(
                schemaVersion: 2,
                id: revisionID,
                sourceSessionID: session.metadata.id,
                createdAt: createdAt,
                completedAt: now(),
                status: .failed,
                provenance: provenance,
                sourceAudioFingerprints: sourceAudioFingerprints,
                transcriptFiles: transcriptFiles,
                transcription: SessionTranscriptionMetadata(
                    status: .failed,
                    model: descriptor.repository,
                    startedAt: createdAt,
                    completedAt: now(),
                    systemSegmentCount: nil,
                    microphoneSegmentCount: nil,
                    warnings: [],
                    failureReason: error.localizedDescription,
                    provenance: provenance
                ),
                diarization: nil,
                markdownFileName: nil,
                failureReason: error.localizedDescription
            )
            try? persist(manifest, to: directoryURL)
            throw error
        }
    }

    private func finalizationForReprocessing(
        _ session: RecordingSession
    ) async throws -> AudioFinalizationMetadata {
        if let finalization = session.metadata.audioFinalization {
            return finalization
        }
        let diagnostics = try recoveredAudioInspector.inspect(session: session)
        return try await audioFinalizer.finalize(
            session: session,
            diagnostics: diagnostics
        )
    }

    private func persist(
        _ manifest: TranscriptionRevisionManifest,
        to directoryURL: URL
    ) throws {
        let data = try SessionJSONCoder.makeEncoder().encode(manifest)
        try data.write(
            to: directoryURL.appendingPathComponent("revision.json"),
            options: .atomic
        )
    }
}
