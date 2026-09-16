import Foundation
import XCTest
@testable import MeetingScribe

final class SessionProcessorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SessionProcessorTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoveryReusesTranscriptWithoutAudioOrModel() async throws {
        let session = makeSession()
        let files = FakeFiles(recovered: recoveredArtifacts())
        let finalizer = FakeFinalizer(error: TestError.unexpectedCall)
        let resolver = FakeResolver(error: TestError.unexpectedCall)
        let processor = SessionProcessor(
            audioFinalizer: finalizer,
            transcriber: FakeTranscriber(),
            modelResolver: resolver,
            analyzer: FakeAnalyzer(),
            processingFiles: files,
            audioSourceCleaner: FakeCleaner(),
            revisionService: FakeRevisionService()
        )

        let events = EventRecorder()
        let result = try await processor.process(
            context(session, kind: .recovery),
            onEvent: { await events.append($0) }
        )

        let finalizerCalls = await finalizer.callCount()
        let resolverCalls = await resolver.callCount()
        let exports = await files.exportCount()
        let hadCheckpoint = await events.containsCheckpoint(.transcribing)
        XCTAssertEqual(finalizerCalls, 0)
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(result.artifacts.transcription?.status, .completed)
        XCTAssertTrue(hadCheckpoint)
    }

    func testPartialFailuresKeepAttemptIdentityAndContinueToExport() async throws {
        var session = makeSession()
        session.metadata.analysisConfiguration = SessionAnalysisConfiguration(
            tool: .codex, executablePath: "/unused", model: nil, prompt: "Prompt"
        )
        let files = FakeFiles()
        let processor = SessionProcessor(
            audioFinalizer: FakeFinalizer(),
            transcriber: FakeTranscriber(error: TestError.transcription),
            modelResolver: FakeResolver(),
            analyzer: FakeAnalyzer(error: TestError.analysis),
            processingFiles: files,
            audioSourceCleaner: FakeCleaner(),
            revisionService: FakeRevisionService()
        )
        let context = context(session)
        let events = EventRecorder()
        let result = try await processor.process(context, onEvent: { await events.append($0) })

        XCTAssertEqual(result.failedSteps, [.transcribing])
        let exports = await files.exportCount()
        let identitiesMatch = await events.allIdentitiesMatch(
            sessionID: session.metadata.id, jobID: context.jobID, attemptID: context.attemptID
        )
        XCTAssertEqual(exports, 0)
        XCTAssertTrue(identitiesMatch)
    }

    func testCancellationThrownByEventPropagates() async throws {
        let processor = SessionProcessor(
            audioFinalizer: FakeFinalizer(),
            transcriber: FakeTranscriber(),
            modelResolver: FakeResolver(),
            analyzer: FakeAnalyzer(),
            processingFiles: FakeFiles(),
            audioSourceCleaner: FakeCleaner(),
            revisionService: FakeRevisionService()
        )

        do {
            _ = try await processor.process(context(makeSession()), onEvent: { event in
                if case .stageStarted = event { throw CancellationError() }
            })
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: event persistence cancellation is not a normal failure.
        }
    }

    func testCleanupReceivesCurrentArtifactSnapshot() async throws {
        let cleaner = FakeCleaner(cleanup: AudioSourceCleanupMetadata(
            status: .completed, completedAt: Date(), deletedFiles: ["system.caf"], failureReason: nil
        ))
        let processor = SessionProcessor(
            audioFinalizer: FakeFinalizer(), transcriber: FakeTranscriber(),
            modelResolver: FakeResolver(), analyzer: FakeAnalyzer(),
            processingFiles: FakeFiles(), audioSourceCleaner: cleaner,
            revisionService: FakeRevisionService()
        )
        let result = try await processor.process(context(makeSession()), onEvent: { _ in })
        let cleaned = try XCTUnwrap(cleaner.receivedSession())

        XCTAssertEqual(cleaned.metadata.transcription?.status, .completed)
        XCTAssertEqual(cleaned.metadata.output?.status, .completed)
        XCTAssertEqual(result.artifacts.audioSourceCleanup?.status, .completed)
    }

    func testReanalyzeLeavesOriginalTranscriptUntouched() async throws {
        var session = makeSession()
        let outputURL = root.appendingPathComponent("meeting.md")
        try validMarkdown().write(to: outputURL, atomically: true, encoding: .utf8)
        session.metadata.output = SessionOutputMetadata(
            status: .completed, markdownFileName: "meeting.md", markdownPath: outputURL.path,
            exportedAt: Date(), failureReason: nil
        )
        let transcript = makeTranscript()
        let originalData = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        try originalData.write(to: session.mergedTranscriptURL, options: .atomic)
        let files = FakeFiles(recovered: RecoveredProcessingArtifacts(
            transcript: transcript, utteranceTranscript: nil, analysis: nil
        ))
        let processor = SessionProcessor(
            audioFinalizer: FakeFinalizer(), transcriber: FakeTranscriber(),
            modelResolver: FakeResolver(), analyzer: FakeAnalyzer(), processingFiles: files,
            audioSourceCleaner: FakeCleaner(), revisionService: FakeRevisionService()
        )
        var config = ProcessingJobConfiguration(outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false)
        config.analysisConfiguration = SessionAnalysisConfiguration(
            tool: .codex, executablePath: "/unused", model: nil, prompt: "Prompt"
        )
        _ = try await processor.process(context(session, kind: .reanalyze, configuration: config), onEvent: { _ in })

        XCTAssertEqual(try Data(contentsOf: session.mergedTranscriptURL), originalData)
        let persistedAnalyses = await files.persistedAnalysisCount()
        XCTAssertEqual(persistedAnalyses, 1)
    }

    func testRetranscribeDoesNotPatchSourceTranscriptionMetadata() async throws {
        var session = makeSession()
        session.metadata.transcription = SessionTranscriptionMetadata(
            status: .completed, model: "original", startedAt: nil, completedAt: Date(),
            systemSegmentCount: 1, microphoneSegmentCount: nil, warnings: [], failureReason: nil
        )
        let revision = makeRevision(for: session)
        let processor = SessionProcessor(
            audioFinalizer: FakeFinalizer(), transcriber: FakeTranscriber(),
            modelResolver: FakeResolver(), analyzer: FakeAnalyzer(), processingFiles: FakeFiles(),
            audioSourceCleaner: FakeCleaner(), revisionService: FakeRevisionService(result: revision)
        )
        let result = try await processor.process(context(session, kind: .retranscribe), onEvent: { _ in })

        XCTAssertNil(result.artifacts.transcription)
        XCTAssertEqual(result.revision, revision)
    }

    private func context(
        _ session: RecordingSession,
        kind: ProcessingJobKind = .initial,
        configuration: ProcessingJobConfiguration = ProcessingJobConfiguration(
            outputDirectoryURL: nil, automaticallyDeleteSourceCAF: false
        )
    ) -> SessionProcessingContext {
        SessionProcessingContext(
            session: session, jobID: UUID(), attemptID: UUID(), kind: kind,
            configuration: configuration, diagnostics: .empty, endedAt: Date()
        )
    }

    private func makeSession() -> RecordingSession {
        RecordingSession(metadata: SessionMetadata(
            id: "session", title: "Meeting", status: .recorded, createdAt: Date(), endedAt: Date()
        ), directoryURL: root)
    }

    private func makeTranscript() -> MergedTranscript {
        MergedTranscript(
            sessionID: "session", title: "Meeting", completedAt: Date(), tracks: [],
            segments: [TranscriptSegment(
                id: "segment", source: .system, speaker: "Other", start: 0, end: 1,
                language: "en", text: "Transcript", confidence: nil
            )]
        )
    }

    private func recoveredArtifacts() -> RecoveredProcessingArtifacts {
        RecoveredProcessingArtifacts(transcript: makeTranscript(), utteranceTranscript: nil, analysis: nil)
    }

    private func validMarkdown() -> String {
        "---\ntitle: Meeting\n---\n<!-- meetingscribe:analysis:start -->\n\n<!-- meetingscribe:analysis:end -->\n"
    }

    private func makeRevision(for session: RecordingSession) -> TranscriptionRevisionResult {
        let manifest = TranscriptionRevisionManifest(
            schemaVersion: 2, id: "revision", sourceSessionID: session.metadata.id,
            createdAt: Date(), completedAt: Date(), status: .completed,
            provenance: .fluidAudioParakeetV3(), sourceAudioFingerprints: [:],
            transcriptFiles: SessionTranscriptFiles(), transcription: nil, diarization: nil,
            markdownFileName: "revision.md", failureReason: nil
        )
        return TranscriptionRevisionResult(directoryURL: root, manifest: manifest)
    }
}

private enum TestError: Error { case unexpectedCall, transcription, analysis }

private actor FakeFinalizer: AudioFinalizing {
    private let error: Error?
    private var calls = 0
    init(error: Error? = nil) { self.error = error }
    func finalize(session: RecordingSession, diagnostics: CaptureSessionDiagnostics) async throws -> AudioFinalizationMetadata {
        calls += 1
        if let error { throw error }
        return AudioFinalizationMetadata(completedAt: Date(), timelineOrigin: 0, system: nil, microphone: nil, warnings: [])
    }
    func callCount() -> Int { calls }
}

private actor FakeResolver: TranscriptionModelResolving {
    private let error: Error?
    private var calls = 0
    init(error: Error? = nil) { self.error = error }
    func resolveTranscriptionModel() async throws -> ResolvedTranscriptionModel {
        calls += 1
        if let error { throw error }
        return ResolvedTranscriptionModel(
            reference: .fluidAudioParakeetV3(bundleURL: FileManager.default.temporaryDirectory),
            descriptor: .parakeetV3
        )
    }
    func callCount() -> Int { calls }
}

private struct FakeTranscriber: SessionTranscribing {
    let error: Error?
    init(error: Error? = nil) { self.error = error }
    func transcribe(session: RecordingSession, finalization: AudioFinalizationMetadata, model: TranscriptionModelReference, language: TranscriptionLanguage) async throws -> SessionTranscriptionResult {
        if let error { throw error }
        let transcript = MergedTranscript(sessionID: session.metadata.id, title: session.metadata.title, completedAt: Date(), tracks: [], segments: [])
        return SessionTranscriptionResult(
            metadata: SessionTranscriptionMetadata(status: .completed, model: "fake", startedAt: nil, completedAt: Date(), systemSegmentCount: 0, microphoneSegmentCount: 0, warnings: [], failureReason: nil),
            systemTranscript: nil, microphoneTranscript: nil, mergedTranscript: transcript
        )
    }
}

private struct FakeAnalyzer: SessionAnalyzing {
    let error: Error?
    init(error: Error? = nil) { self.error = error }
    func analyze(session: RecordingSession, transcript: MergedTranscript, configuration: SessionAnalysisConfiguration) async throws -> SessionAnalysisRun {
        if let error { throw error }
        let artifact = AIAnalysisArtifact(markdown: "## Analysis", tool: .codex, model: nil, toolVersion: "test", prompt: configuration.prompt)
        return SessionAnalysisRun(
            metadata: SessionAnalysisMetadata(status: .completed, provider: "codex", model: "default", startedAt: nil, completedAt: Date(), transcriptChunkCount: 1, requestCount: 1, failureReason: nil), artifact: artifact
        )
    }
}

private actor FakeFiles: ProcessingFileServicing {
    private let recovered: RecoveredProcessingArtifacts?
    private var exports = 0
    private var analyses = 0
    init(recovered: RecoveredProcessingArtifacts? = nil) { self.recovered = recovered }
    func loadRecoveredArtifacts(from session: RecordingSession) async -> RecoveredProcessingArtifacts? { recovered }
    func persistAnalysis(_ analysis: AIAnalysisArtifact, to url: URL) async throws { analyses += 1 }
    func exportMarkdown(session: SessionMetadata, transcript: MergedTranscript, utteranceTranscript: ContinuousUtteranceTranscript?, analysis: AIAnalysisArtifact?, to directoryURL: URL) async throws -> MarkdownExportResult {
        exports += 1
        return MarkdownExportResult(fileURL: directoryURL.appendingPathComponent("meeting.md"), exportedAt: Date())
    }
    func exportCount() -> Int { exports }
    func persistedAnalysisCount() -> Int { analyses }
}

private final class FakeCleaner: AudioSourceCleaning, @unchecked Sendable {
    private let cleanup: AudioSourceCleanupMetadata?
    private var received: RecordingSession?
    private let lock = NSLock()
    init(cleanup: AudioSourceCleanupMetadata? = nil) { self.cleanup = cleanup }
    func cleanupSourceCAFIfEligible(session: RecordingSession) throws -> AudioSourceCleanupMetadata? {
        lock.lock()
        received = session
        lock.unlock()
        return cleanup
    }
    func receivedSession() -> RecordingSession? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private actor FakeRevisionService: SessionTranscriptionRevising {
    private let result: TranscriptionRevisionResult?
    init(result: TranscriptionRevisionResult? = nil) { self.result = result }
    func reprocess(session: RecordingSession, model: ResolvedTranscriptionModel, onStep: @escaping @Sendable (ProcessingStepID) async throws -> Void) async throws -> TranscriptionRevisionResult {
        try await onStep(.transcribing)
        return result ?? TranscriptionRevisionResult(directoryURL: session.directoryURL, manifest: TranscriptionRevisionManifest(schemaVersion: 2, id: "default", sourceSessionID: session.metadata.id, createdAt: Date(), completedAt: Date(), status: .completed, provenance: .fluidAudioParakeetV3(), sourceAudioFingerprints: [:], transcriptFiles: SessionTranscriptFiles(), transcription: nil, diarization: nil, markdownFileName: nil, failureReason: nil))
    }
}

private actor EventRecorder {
    private var events: [SessionProcessingEvent] = []
    func append(_ event: SessionProcessingEvent) { events.append(event) }
    func containsCheckpoint(_ step: ProcessingStepID) -> Bool {
        events.contains { if case let .checkpoint(checkpoint) = $0 { checkpoint.stage == step } else { false } }
    }
    func allIdentitiesMatch(sessionID: String, jobID: UUID, attemptID: UUID) -> Bool {
        events.allSatisfy { event in
            let identity: SessionProcessingEventIdentity
            switch event {
            case let .stageStarted(value, _), let .stageSkipped(value, _), let .stageFailed(value, _, _): identity = value
            case let .checkpoint(checkpoint): identity = checkpoint.identity
            }
            return identity.sessionID == sessionID && identity.jobID == jobID && identity.attemptID == attemptID
        }
    }
}
