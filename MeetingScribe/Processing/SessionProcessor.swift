import Foundation

/// Resolves a model which has already been installed and validated.  The
/// processor deliberately does not observe UI model state: a missing model is
/// a result for this job alone.
protocol TranscriptionModelResolving: Sendable {
    func resolveTranscriptionModel() async throws -> ResolvedTranscriptionModel
}

struct ResolvedTranscriptionModel: Sendable {
    let reference: TranscriptionModelReference
    let descriptor: FluidAudioModelDescriptor
}

struct DefaultTranscriptionModelResolver: TranscriptionModelResolving {
    private let manager: any FluidAudioModelManaging
    private let descriptor: FluidAudioModelDescriptor

    init(
        manager: any FluidAudioModelManaging,
        descriptor: FluidAudioModelDescriptor = .parakeetV3
    ) {
        self.manager = manager
        self.descriptor = descriptor
    }

    func resolveTranscriptionModel() async throws -> ResolvedTranscriptionModel {
        switch await manager.status(for: descriptor) {
        case let .ready(bundleURL, _):
            return ResolvedTranscriptionModel(
                reference: .fluidAudioParakeetV3(
                    bundleURL: bundleURL,
                    descriptor: descriptor
                ),
                descriptor: descriptor
            )
        case .missing, .invalid:
            throw TranscriptionError.modelBundleCouldNotBeLoaded(
                name: descriptor.displayName
            )
        }
    }
}

/// The analysis boundary keeps the processor independent of AppState while
/// making command execution deterministic in tests.
protocol SessionAnalyzing: Sendable {
    func analyze(
        session: RecordingSession,
        transcript: MergedTranscript,
        configuration: SessionAnalysisConfiguration
    ) async throws -> SessionAnalysisRun
}

struct SessionAnalysisRun: Sendable {
    let metadata: SessionAnalysisMetadata
    let artifact: AIAnalysisArtifact
}

struct CLIAnalysisService: SessionAnalyzing {
    private let runner: any AnalysisCommandRunning

    init(runner: any AnalysisCommandRunning = AnalysisProcessRunner()) {
        self.runner = runner
    }

    func analyze(
        session: RecordingSession,
        transcript: MergedTranscript,
        configuration: SessionAnalysisConfiguration
    ) async throws -> SessionAnalysisRun {
        try Task.checkCancellation()
        let executablePath = configuration.executablePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executablePath.isEmpty else {
            throw AnalysisError.executableNotFound(
                path: configuration.tool.executableName
            )
        }

        let startedAt = Date()
        let provider = CLIAnalysisProvider(
            tool: configuration.tool,
            executableURL: URL(fileURLWithPath: executablePath),
            model: configuration.model,
            runner: runner
        )
        let toolVersion = try await provider.toolVersion()
        try Task.checkCancellation()
        let prompt = AnalysisPrompt.render(
            template: configuration.prompt,
            session: session.metadata
        )
        let run = try await MeetingAnalyzer(provider: provider).analyze(
            session: session.metadata,
            transcript: transcript,
            userPrompt: prompt
        )
        try Task.checkCancellation()
        let validated = try AnalysisMarkdownSchema.validate(run.analysis)
        let artifact = AIAnalysisArtifact(
            markdown: validated.markdown,
            tool: configuration.tool,
            model: configuration.model,
            toolVersion: toolVersion,
            prompt: prompt
        )
        return SessionAnalysisRun(
            metadata: SessionAnalysisMetadata(
                status: .completed,
                provider: configuration.tool.rawValue,
                model: configuration.model ?? "default",
                startedAt: startedAt,
                completedAt: Date(),
                transcriptChunkCount: run.transcriptChunkCount,
                requestCount: run.requestCount,
                promptHash: artifact.promptHash,
                toolVersion: toolVersion,
                failureReason: nil
            ),
            artifact: artifact
        )
    }
}

protocol SessionTranscriptionRevising: Sendable {
    func reprocess(
        session: RecordingSession,
        model: ResolvedTranscriptionModel,
        onStep: @escaping @Sendable (ProcessingStepID) async throws -> Void
    ) async throws -> TranscriptionRevisionResult
}

actor FluidAudioSessionTranscriptionRevisionService: SessionTranscriptionRevising {
    private let service: FluidAudioTranscriptionRevisionService

    init(service: FluidAudioTranscriptionRevisionService = .init()) {
        self.service = service
    }

    func reprocess(
        session: RecordingSession,
        model: ResolvedTranscriptionModel,
        onStep: @escaping @Sendable (ProcessingStepID) async throws -> Void
    ) async throws -> TranscriptionRevisionResult {
        try await service.reprocess(
            session: session,
            modelBundleURL: model.reference.location,
            descriptor: model.descriptor,
            onStep: { step in
                try Task.checkCancellation()
                try await onStep(step)
            }
        )
    }
}

struct SessionProcessingContext: Sendable {
    let session: RecordingSession
    let jobID: UUID
    let attemptID: UUID
    let kind: ProcessingJobKind
    let configuration: ProcessingJobConfiguration
    let diagnostics: CaptureSessionDiagnostics
    let endedAt: Date

    init(
        session: RecordingSession,
        jobID: UUID,
        attemptID: UUID,
        kind: ProcessingJobKind,
        configuration: ProcessingJobConfiguration,
        diagnostics: CaptureSessionDiagnostics,
        endedAt: Date
    ) {
        self.session = session
        self.jobID = jobID
        self.attemptID = attemptID
        self.kind = kind
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.endedAt = endedAt
    }
}

struct SessionProcessingEventIdentity: Equatable, Sendable {
    let sessionID: String
    let jobID: UUID
    let attemptID: UUID
}

struct SessionProcessingCheckpoint: Sendable {
    let identity: SessionProcessingEventIdentity
    let stage: ProcessingStepID
    let artifacts: ProcessingArtifactMetadata
    let revision: TranscriptionRevisionResult?
}

enum SessionProcessingEvent: Sendable {
    case stageStarted(SessionProcessingEventIdentity, ProcessingStepID)
    case checkpoint(SessionProcessingCheckpoint)
    case stageSkipped(SessionProcessingEventIdentity, ProcessingStepID)
    case stageFailed(SessionProcessingEventIdentity, ProcessingStepID, String)
}

struct SessionProcessingResult: Sendable {
    let artifacts: ProcessingArtifactMetadata
    let failedSteps: [ProcessingStepID]
    let failureDescription: String?
    let revision: TranscriptionRevisionResult?
}

private struct TranscriptionStepResult: Sendable {
    let metadata: SessionTranscriptionMetadata
    let transcript: MergedTranscript?
    let utterances: ContinuousUtteranceTranscript?
    let failureDescription: String?
}

private struct AnalysisStepResult: Sendable {
    let metadata: SessionAnalysisMetadata?
    let artifact: AIAnalysisArtifact?
    let failureDescription: String?
}

private struct ExportStepResult: Sendable {
    let metadata: SessionOutputMetadata?
    let failureDescription: String?
}

private actor ProcessingStepTracker {
    private var value: ProcessingStepID

    init(_ value: ProcessingStepID) {
        self.value = value
    }

    func set(_ value: ProcessingStepID) {
        self.value = value
    }

    func current() -> ProcessingStepID { value }
}

protocol SessionProcessing: Sendable {
    func process(
        _ context: SessionProcessingContext,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> SessionProcessingResult
}

/// A single immutable processing attempt.  Persistence is deliberately left
/// to the queue/repository through checkpoints so this actor never writes a
/// stale full `RecordingSession` back over a newer capture session.
actor SessionProcessor: SessionProcessing {
    private let audioFinalizer: any AudioFinalizing
    private let transcriber: any SessionTranscribing
    private let modelResolver: any TranscriptionModelResolving
    private let analyzer: any SessionAnalyzing
    private let processingFiles: any ProcessingFileServicing
    private let audioSourceCleaner: any AudioSourceCleaning
    private let revisionService: any SessionTranscriptionRevising
    private let recoveredAudioInspector: RecoveredAudioInspector
    private let logger: ProcessingLogger

    init(
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        transcriber: any SessionTranscribing = SessionTranscriber(),
        modelResolver: any TranscriptionModelResolving,
        analyzer: any SessionAnalyzing = CLIAnalysisService(),
        processingFiles: any ProcessingFileServicing = ProcessingFileService(),
        audioSourceCleaner: any AudioSourceCleaning = AudioSourceCleaner(),
        revisionService: any SessionTranscriptionRevising = FluidAudioSessionTranscriptionRevisionService(),
        recoveredAudioInspector: RecoveredAudioInspector = RecoveredAudioInspector(),
        logger: ProcessingLogger = ProcessingLogger()
    ) {
        self.audioFinalizer = audioFinalizer
        self.transcriber = transcriber
        self.modelResolver = modelResolver
        self.analyzer = analyzer
        self.processingFiles = processingFiles
        self.audioSourceCleaner = audioSourceCleaner
        self.revisionService = revisionService
        self.recoveredAudioInspector = recoveredAudioInspector
        self.logger = logger
    }

    /// Integration convenience initializer.  It preserves the injectable
    /// analysis boundary above while allowing AppState to provide its existing
    /// services without becoming part of the processor's lifetime.
    init(
        audioFinalizer: any AudioFinalizing,
        transcriber: any SessionTranscribing,
        fileService: any ProcessingFileServicing,
        modelResolver: any TranscriptionModelResolving,
        analysisCommandRunner: any AnalysisCommandRunning,
        audioSourceCleaner: any AudioSourceCleaning,
        logger: ProcessingLogger,
        revisionService: any SessionTranscriptionRevising = FluidAudioSessionTranscriptionRevisionService(),
        recoveredAudioInspector: RecoveredAudioInspector = RecoveredAudioInspector()
    ) {
        self.audioFinalizer = audioFinalizer
        self.transcriber = transcriber
        self.modelResolver = modelResolver
        analyzer = CLIAnalysisService(runner: analysisCommandRunner)
        processingFiles = fileService
        self.audioSourceCleaner = audioSourceCleaner
        self.revisionService = revisionService
        self.recoveredAudioInspector = recoveredAudioInspector
        self.logger = logger
    }

    func process(
        _ context: SessionProcessingContext,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> SessionProcessingResult {
        try Task.checkCancellation()
        switch context.kind {
        case .retranscribe:
            return try await processRetranscription(context, onEvent: onEvent)
        case .reanalyze:
            return try await processReanalysis(context, onEvent: onEvent)
        case .initial, .recovery:
            return try await processInitialOrRecovery(context, onEvent: onEvent)
        }
    }

    private func processInitialOrRecovery(
        _ context: SessionProcessingContext,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> SessionProcessingResult {
        let identity = identity(for: context)
        var artifacts = ProcessingArtifactMetadata()
        var failedSteps: [ProcessingStepID] = []

        let recoveredArtifacts = await processingFiles.loadRecoveredArtifacts(
            from: context.session
        )
        let canReuseTranscript = recoveredArtifacts != nil
        let shouldReuseTranscript = canReuseTranscript && (
            context.kind == .recovery
                || context.session.metadata.transcription?.status == .completed
        )

        let transcription: TranscriptionStepResult
        if shouldReuseTranscript, let recoveredArtifacts {
            let metadata = context.session.metadata.transcription.flatMap {
                $0.status == .completed ? $0 : nil
            } ?? recoveredTranscriptionMetadata(for: recoveredArtifacts.transcript)
            artifacts.audioFinalization = context.session.metadata.audioFinalization
            artifacts.transcription = metadata
            try await checkpoint(
                .transcribing, identity: identity, artifacts: artifacts,
                revision: nil, onEvent: onEvent
            )
            transcription = TranscriptionStepResult(
                metadata: metadata,
                transcript: recoveredArtifacts.transcript,
                utterances: recoveredArtifacts.utteranceTranscript,
                failureDescription: nil
            )
        } else {
            let finalization: AudioFinalizationMetadata
            if let existing = context.session.metadata.audioFinalization,
               validFinalizedAudio(existing, in: context.session) {
                finalization = existing
                artifacts.audioFinalization = existing
                try await checkpoint(
                    .preparingAudio, identity: identity, artifacts: artifacts,
                    revision: nil, onEvent: onEvent
                )
            } else {
            try await started(.preparingAudio, identity: identity, onEvent: onEvent)
            try? await logger.log(.finalizationStarted, for: context.session)
            do {
                let diagnostics: CaptureSessionDiagnostics
                if context.kind == .recovery,
                   context.session.metadata.systemAudio == nil,
                   context.session.metadata.microphoneAudio == nil {
                    diagnostics = try recoveredAudioInspector.inspect(session: context.session)
                } else {
                    diagnostics = context.diagnostics
                }
                finalization = try await audioFinalizer.finalize(
                    session: context.session,
                    diagnostics: diagnostics
                )
                try Task.checkCancellation()
                artifacts.audioFinalization = finalization
                try await checkpoint(
                    .preparingAudio, identity: identity, artifacts: artifacts,
                    revision: nil, onEvent: onEvent
                )
                try? await logger.log(
                    .finalizationCompleted,
                    for: context.session,
                    attributes: [.durationSeconds(
                        finalization.system?.durationSeconds
                            ?? finalization.microphone?.durationSeconds
                            ?? 0
                    )]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let description = error.localizedDescription
                failedSteps.append(.preparingAudio)
                try await failed(.preparingAudio, description, identity: identity, onEvent: onEvent)
                return SessionProcessingResult(
                    artifacts: artifacts,
                    failedSteps: failedSteps,
                    failureDescription: description,
                    revision: nil
                )
            }
            }

            transcription = try await transcribe(
                context.session, finalization: finalization, identity: identity,
                artifacts: artifacts, onEvent: onEvent
            )
        }
        artifacts.transcription = transcription.metadata
        if transcription.failureDescription != nil { failedSteps.append(.transcribing) }
        let analysis: AnalysisStepResult
        var generatedNewAnalysis = false
        if let previous = recoveredArtifacts?.analysis,
           let metadata = context.session.metadata.analysis,
           metadata.status == .completed,
           metadata.promptHash == previous.promptHash,
           shouldReuseTranscript {
            artifacts.analysis = metadata
            try await checkpoint(.analyzing, identity: identity, artifacts: artifacts,
                                 revision: nil, onEvent: onEvent)
            analysis = AnalysisStepResult(metadata: metadata, artifact: previous, failureDescription: nil)
        } else {
            analysis = try await analyze(
                context.session, transcript: transcription.transcript,
                configuration: context.session.metadata.analysisConfiguration,
                identity: identity, artifacts: artifacts, onEvent: onEvent
            )
            generatedNewAnalysis = analysis.artifact != nil
        }
        artifacts.analysis = analysis.metadata
        if analysis.failureDescription != nil { failedSteps.append(.analyzing) }
        let export: ExportStepResult
        if let priorOutput = context.session.metadata.output,
           priorOutput.status == .completed,
           shouldReuseTranscript,
           !generatedNewAnalysis,
           validExistingOutput(priorOutput, for: context.session) {
            artifacts.output = priorOutput
            try await checkpoint(.exporting, identity: identity, artifacts: artifacts,
                                 revision: nil, onEvent: onEvent)
            export = ExportStepResult(metadata: priorOutput, failureDescription: nil)
        } else {
            export = try await self.export(
                context.session, transcript: transcription.transcript,
                utterances: transcription.utterances, analysis: analysis.artifact,
                outputDirectory: resolvedOutputDirectory(for: context),
                identity: identity, artifacts: artifacts, onEvent: onEvent
            )
        }
        artifacts.output = export.metadata
        if export.failureDescription != nil { failedSteps.append(.exporting) }
        artifacts.audioSourceCleanup = try await cleanSourceAudioIfNeeded(
            context, identity: identity, artifacts: artifacts, onEvent: onEvent
        )
        return SessionProcessingResult(
            artifacts: artifacts,
            failedSteps: failedSteps,
            failureDescription: failedSteps.isEmpty ? nil : firstFailure(in: artifacts),
            revision: nil
        )
    }

    private func processRetranscription(
        _ context: SessionProcessingContext,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> SessionProcessingResult {
        let identity = identity(for: context)
        let stepTracker = ProcessingStepTracker(.preparingAudio)
        do {
            try Task.checkCancellation()
            let model = try await modelResolver.resolveTranscriptionModel()
            try Task.checkCancellation()
            let revision = try await revisionService.reprocess(
                session: context.session,
                model: model,
                onStep: { step in
                    await stepTracker.set(step)
                    try Task.checkCancellation()
                    try await onEvent(.stageStarted(identity, step))
                }
            )
            try Task.checkCancellation()
            // A revision lives under revisions/<id>.  Its metadata must never
            // be patched into the source session's original artifacts.
            let artifacts = ProcessingArtifactMetadata()
            try await checkpoint(
                .exporting, identity: identity, artifacts: artifacts,
                revision: revision, onEvent: onEvent
            )
            return SessionProcessingResult(
                artifacts: artifacts,
                failedSteps: [],
                failureDescription: nil,
                revision: revision
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let description = error.localizedDescription
            let currentStep = await stepTracker.current()
            try await failed(currentStep, description, identity: identity, onEvent: onEvent)
            return SessionProcessingResult(
                artifacts: ProcessingArtifactMetadata(),
                failedSteps: [currentStep],
                failureDescription: description,
                revision: nil
            )
        }
    }

    private func processReanalysis(
        _ context: SessionProcessingContext,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> SessionProcessingResult {
        let identity = identity(for: context)
        var artifacts = ProcessingArtifactMetadata()
        guard let recovered = await processingFiles.loadRecoveredArtifacts(from: context.session),
              !recovered.transcript.segments.isEmpty else {
            let description = AnalysisRevisionError.transcriptMissing.localizedDescription
            try await failed(.analyzing, description, identity: identity, onEvent: onEvent)
            return SessionProcessingResult(
                artifacts: artifacts, failedSteps: [.analyzing],
                failureDescription: description, revision: nil
            )
        }
        let configuration = context.configuration.analysisConfiguration
            ?? context.session.metadata.analysisConfiguration
        let analysis = try await analyze(
            context.session, transcript: recovered.transcript, configuration: configuration,
            identity: identity, artifacts: artifacts, onEvent: onEvent
        )
        artifacts.analysis = analysis.metadata
        guard let analysis = analysis.artifact else {
            return SessionProcessingResult(
                artifacts: artifacts, failedSteps: [.analyzing],
                failureDescription: firstFailure(in: artifacts), revision: nil
            )
        }

        guard let outputPath = context.session.metadata.output?.markdownPath,
              !outputPath.isEmpty else {
            let description = AnalysisRevisionError.markdownMissing.localizedDescription
            try await failed(.exporting, description, identity: identity, onEvent: onEvent)
            return SessionProcessingResult(
                artifacts: artifacts, failedSteps: [.exporting],
                failureDescription: description, revision: nil
            )
        }
        let markdownURL = URL(fileURLWithPath: outputPath)
        try await started(.exporting, identity: identity, onEvent: onEvent)
        do {
            let outputDirectory = resolvedOutputDirectory(for: context)
            let scopedDirectory = outputDirectory?.standardizedFileURL == markdownURL.deletingLastPathComponent().standardizedFileURL
                ? outputDirectory! : markdownURL.deletingLastPathComponent()
            try await withSecurityScopedAccess(to: scopedDirectory) {
                try MarkdownAnalysisUpdater().update(analysis, at: markdownURL)
            }
            try Task.checkCancellation()
            artifacts.output = context.session.metadata.output
            try await checkpoint(
                .exporting, identity: identity, artifacts: artifacts,
                revision: nil, onEvent: onEvent
            )
            return SessionProcessingResult(
                artifacts: artifacts, failedSteps: [], failureDescription: nil, revision: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let description = error.localizedDescription
            try await failed(.exporting, description, identity: identity, onEvent: onEvent)
            return SessionProcessingResult(
                artifacts: artifacts, failedSteps: [.exporting],
                failureDescription: description, revision: nil
            )
        }
    }

    private func transcribe(
        _ session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        identity: SessionProcessingEventIdentity,
        artifacts: ProcessingArtifactMetadata,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> TranscriptionStepResult {
        try await started(.transcribing, identity: identity, onEvent: onEvent)
        try? await logger.log(
            .transcriptionStarted,
            for: session,
            attributes: [.model(FluidAudioModelDescriptor.parakeetV3.repository)]
        )
        do {
            let model = try await modelResolver.resolveTranscriptionModel()
            try Task.checkCancellation()
            let result = try await transcriber.transcribe(
                session: session, finalization: finalization,
                model: model.reference, language: session.metadata.language
            )
            try Task.checkCancellation()
            var checkpointArtifacts = artifacts
            checkpointArtifacts.transcription = result.metadata
            try await checkpoint(.transcribing, identity: identity, artifacts: checkpointArtifacts, revision: nil, onEvent: onEvent)
            try? await logger.log(
                .transcriptionCompleted,
                for: session,
                attributes: [
                    .model(result.metadata.model),
                    .segmentCount(result.metadata.mergedSegmentCount ?? 0),
                ]
            )
            return TranscriptionStepResult(
                metadata: result.metadata, transcript: result.mergedTranscript,
                utterances: result.utteranceTranscript, failureDescription: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let description = error.localizedDescription
            let metadata = failedTranscriptionMetadata(description)
            try await failed(.transcribing, description, identity: identity, onEvent: onEvent)
            try? await logger.log(
                .transcriptionFailed,
                for: session,
                attributes: [.model(metadata.model)]
            )
            return TranscriptionStepResult(
                metadata: metadata, transcript: nil, utterances: nil,
                failureDescription: description
            )
        }
    }

    private func analyze(
        _ session: RecordingSession,
        transcript: MergedTranscript?,
        configuration: SessionAnalysisConfiguration?,
        identity: SessionProcessingEventIdentity,
        artifacts: ProcessingArtifactMetadata,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> AnalysisStepResult {
        guard let configuration, let transcript, !transcript.segments.isEmpty else {
            try Task.checkCancellation()
            try await onEvent(.stageSkipped(identity, .analyzing))
            return AnalysisStepResult(metadata: nil, artifact: nil, failureDescription: nil)
        }
        try await started(.analyzing, identity: identity, onEvent: onEvent)
        do {
            let run = try await analyzer.analyze(
                session: session, transcript: transcript, configuration: configuration
            )
            try Task.checkCancellation()
            try await processingFiles.persistAnalysis(run.artifact, to: session.analysisURL)
            try Task.checkCancellation()
            var checkpointArtifacts = artifacts
            checkpointArtifacts.analysis = run.metadata
            try await checkpoint(.analyzing, identity: identity, artifacts: checkpointArtifacts, revision: nil, onEvent: onEvent)
            try? await logger.log(
                .analysisCompleted,
                for: session,
                attributes: [.model(run.metadata.model)]
            )
            return AnalysisStepResult(metadata: run.metadata, artifact: run.artifact, failureDescription: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let description = error.localizedDescription
            try await failed(.analyzing, description, identity: identity, onEvent: onEvent)
            try? await logger.log(
                .analysisFailed,
                for: session,
                attributes: [.model(configuration.model ?? "default")]
            )
            return AnalysisStepResult(
                metadata: failedAnalysisMetadata(configuration, description: description),
                artifact: nil, failureDescription: description
            )
        }
    }

    private func export(
        _ session: RecordingSession,
        transcript: MergedTranscript?,
        utterances: ContinuousUtteranceTranscript?,
        analysis: AIAnalysisArtifact?,
        outputDirectory: URL?,
        identity: SessionProcessingEventIdentity,
        artifacts: ProcessingArtifactMetadata,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> ExportStepResult {
        guard let transcript else {
            try Task.checkCancellation()
            try await onEvent(.stageSkipped(identity, .exporting))
            return ExportStepResult(metadata: nil, failureDescription: nil)
        }
        try await started(.exporting, identity: identity, onEvent: onEvent)
        let destination = outputDirectory ?? session.directoryURL
        do {
            let output = try await withSecurityScopedAccess(to: destination) {
                try await self.processingFiles.exportMarkdown(
                    session: session.metadata, transcript: transcript,
                    utteranceTranscript: utterances, analysis: analysis, to: destination
                )
            }
            try Task.checkCancellation()
            let metadata = SessionOutputMetadata(
                status: .completed, markdownFileName: output.fileURL.lastPathComponent,
                markdownPath: output.fileURL.path, exportedAt: output.exportedAt,
                failureReason: nil
            )
            var checkpointArtifacts = artifacts
            checkpointArtifacts.output = metadata
            try await checkpoint(.exporting, identity: identity, artifacts: checkpointArtifacts, revision: nil, onEvent: onEvent)
            try? await logger.log(.exportCompleted, for: session)
            return ExportStepResult(metadata: metadata, failureDescription: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let description = error.localizedDescription
            let metadata = SessionOutputMetadata(
                status: .failed, markdownFileName: nil, markdownPath: nil,
                exportedAt: Date(), failureReason: description
            )
            try await failed(.exporting, description, identity: identity, onEvent: onEvent)
            try? await logger.log(.exportFailed, for: session)
            return ExportStepResult(metadata: metadata, failureDescription: description)
        }
    }

    private func cleanSourceAudioIfNeeded(
        _ context: SessionProcessingContext,
        identity: SessionProcessingEventIdentity,
        artifacts: ProcessingArtifactMetadata,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws -> AudioSourceCleanupMetadata? {
        guard context.configuration.automaticallyDeleteSourceCAF,
              !context.session.metadata.keepsRecordingAudio else { return nil }
        try Task.checkCancellation()
        do {
            let cleaner = audioSourceCleaner
            let session = sessionForCleanup(context.session, artifacts: artifacts)
            let cleanup = try await Task.detached(priority: .utility) {
                try cleaner.cleanupSourceCAFIfEligible(session: session)
            }.value
            try Task.checkCancellation()
            guard let cleanup else { return nil }
            // Cleanup has no ProcessingStepID.  It remains a checkpoint so the
            // repository can record it without making a successful export fail.
            try await onEvent(.checkpoint(SessionProcessingCheckpoint(
                identity: identity, stage: .exporting,
                artifacts: withCleanup(cleanup, in: artifacts), revision: nil
            )))
            try? await logger.log(.sourceAudioCleanupCompleted, for: context.session)
            return cleanup
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await logger.log(.sourceAudioCleanupFailed, for: context.session)
            return AudioSourceCleanupMetadata(
                status: .failed, completedAt: Date(), deletedFiles: [],
                failureReason: error.localizedDescription
            )
        }
    }

    private func identity(for context: SessionProcessingContext) -> SessionProcessingEventIdentity {
        SessionProcessingEventIdentity(
            sessionID: context.session.metadata.id,
            jobID: context.jobID,
            attemptID: context.attemptID
        )
    }

    private func started(
        _ step: ProcessingStepID,
        identity: SessionProcessingEventIdentity,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await onEvent(.stageStarted(identity, step))
        try Task.checkCancellation()
    }

    private func checkpoint(
        _ step: ProcessingStepID,
        identity: SessionProcessingEventIdentity,
        artifacts: ProcessingArtifactMetadata,
        revision: TranscriptionRevisionResult?,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await onEvent(.checkpoint(SessionProcessingCheckpoint(
            identity: identity, stage: step, artifacts: artifacts, revision: revision
        )))
        try Task.checkCancellation()
    }

    private func failed(
        _ step: ProcessingStepID,
        _ description: String,
        identity: SessionProcessingEventIdentity,
        onEvent: @escaping @Sendable (SessionProcessingEvent) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await onEvent(.stageFailed(identity, step, description))
    }

    private func failedTranscriptionMetadata(_ description: String) -> SessionTranscriptionMetadata {
        let descriptor = FluidAudioModelDescriptor.parakeetV3
        return SessionTranscriptionMetadata(
            status: .failed, model: descriptor.repository, startedAt: nil,
            completedAt: Date(), systemSegmentCount: nil,
            microphoneSegmentCount: nil, warnings: [], failureReason: description,
            provenance: .fluidAudioParakeetV3(descriptor: descriptor)
        )
    }

    private func recoveredTranscriptionMetadata(
        for transcript: MergedTranscript
    ) -> SessionTranscriptionMetadata {
        SessionTranscriptionMetadata(
            status: .completed,
            model: "recovered-transcript",
            startedAt: nil,
            completedAt: transcript.completedAt,
            systemSegmentCount: transcript.segments.filter { $0.source == .system }.count,
            microphoneSegmentCount: transcript.segments.filter { $0.source == .microphone }.count,
            mergedSegmentCount: transcript.segments.count,
            warnings: ["Reused a merged transcript found during session recovery."],
            failureReason: nil
        )
    }

    private func failedAnalysisMetadata(
        _ configuration: SessionAnalysisConfiguration,
        description: String
    ) -> SessionAnalysisMetadata {
        SessionAnalysisMetadata(
            status: .failed, provider: configuration.tool.rawValue,
            model: configuration.model ?? "default", startedAt: nil,
            completedAt: Date(), transcriptChunkCount: nil, requestCount: nil,
            promptHash: configuration.promptHash, toolVersion: nil,
            failureReason: description
        )
    }

    private func firstFailure(in artifacts: ProcessingArtifactMetadata) -> String? {
        artifacts.transcription?.failureReason
            ?? artifacts.analysis?.failureReason
            ?? artifacts.output?.failureReason
    }

    private func withCleanup(
        _ cleanup: AudioSourceCleanupMetadata,
        in artifacts: ProcessingArtifactMetadata
    ) -> ProcessingArtifactMetadata {
        var updated = artifacts
        updated.audioSourceCleanup = cleanup
        return updated
    }

    /// The cleaner validates durable downstream state from SessionMetadata.
    /// Build that snapshot from this attempt's already checkpointed artifacts
    /// without writing it back; the repository remains the sole manifest
    /// writer.
    private func sessionForCleanup(
        _ original: RecordingSession,
        artifacts: ProcessingArtifactMetadata
    ) -> RecordingSession {
        var session = original
        if let finalization = artifacts.audioFinalization {
            session.metadata.audioFinalization = finalization
        }
        if let transcription = artifacts.transcription {
            session.metadata.transcription = transcription
        }
        if let analysis = artifacts.analysis {
            session.metadata.analysis = analysis
        }
        if let output = artifacts.output {
            session.metadata.output = output
        }
        return session
    }

    private func resolvedOutputDirectory(for context: SessionProcessingContext) -> URL? {
        guard let path = context.configuration.outputDirectoryURL else { return nil }
        guard let bookmark = context.configuration.outputDirectoryBookmark else { return path }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                      options: [.withSecurityScope], relativeTo: nil,
                                      bookmarkDataIsStale: &stale),
              resolved.standardizedFileURL == path.standardizedFileURL else { return path }
        return resolved
    }

    private func validExistingOutput(_ output: SessionOutputMetadata, for session: RecordingSession) -> Bool {
        guard let path = output.markdownPath, !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return false }
        let frontmatter = text.components(separatedBy: "---").dropFirst().first ?? ""
        return frontmatter.split(separator: "\n").contains {
            $0 == Substring("recording_id: \"\(session.metadata.id)\"")
        }
    }

    private func validFinalizedAudio(
        _ finalization: AudioFinalizationMetadata, in session: RecordingSession
    ) -> Bool {
        let tracks = [finalization.system, finalization.microphone].compactMap { $0 }
        guard !tracks.isEmpty else { return false }
        return tracks.allSatisfy { track in
            let url = session.directoryURL.appendingPathComponent(track.fileName)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    private func withSecurityScopedAccess<T: Sendable>(
        to url: URL,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try await operation()
    }
}
