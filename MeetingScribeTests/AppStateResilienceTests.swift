import Foundation
import XCTest
@testable import MeetingScribe

@MainActor
final class AppStateResilienceTests: XCTestCase {
    func testAudioRetentionSettingDefaultsOffAndPersistsOptIn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = AudioRetentionSettingsStore(defaults: fixture.defaults)
        XCTAssertFalse(store.automaticallyDeleteSourceCAF)
        store.setAutomaticallyDeleteSourceCAF(true)

        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            modelManager: WhisperModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            defaults: fixture.defaults
        )
        await appState.prepareStorage()

        XCTAssertTrue(appState.automaticallyDeleteSourceCAF)
        appState.automaticallyDeleteSourceCAF = false
        appState.persistAudioRetentionSettings()
        XCTAssertFalse(store.automaticallyDeleteSourceCAF)
    }

    func testSelectedLanguageIsRestoredAndStoredInNewSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        WhisperSettingsStore(defaults: fixture.defaults).setSelectedLanguage(.czech)
        let applicationSettings = ApplicationSettingsStore(defaults: fixture.defaults)
        applicationSettings.setOutputLanguage(.english)
        applicationSettings.setMarkdownFileNameTemplate("{date} - {title} - {id}")

        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            modelManager: WhisperModelManager(modelsRoot: modelsRoot),
            monitoring: CaptureMonitoringConfiguration(interval: .seconds(60)),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        XCTAssertEqual(appState.selectedTranscriptionLanguage, .czech)
        XCTAssertEqual(appState.selectedOutputLanguage, .english)
        XCTAssertEqual(appState.markdownFileNameTemplate, "{date} - {title} - {id}")
        XCTAssertTrue(appState.canEditSessionConfiguration)

        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        XCTAssertFalse(appState.canEditSessionConfiguration)
        XCTAssertEqual(session.metadata.language, .czech)
        XCTAssertEqual(session.metadata.resolvedOutputLanguage, .english)
        XCTAssertEqual(
            session.metadata.resolvedOutputFileNameTemplate,
            "{date} - {title} - {id}"
        )
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.language, .czech)
        XCTAssertEqual(persisted.resolvedOutputLanguage, .english)

        await appState.stopRecording()
        XCTAssertNotEqual(appState.status, .recording)
        XCTAssertTrue(appState.canEditSessionConfiguration)
    }

    func testPrepareStorageRunsInitializationOnlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let apiKeyStore = CountingResilienceAPIKeyStore()
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            modelManager: WhisperModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            apiKeyStore: apiKeyStore,
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.prepareStorage()

        let loadCount = await apiKeyStore.loadCount()
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(appState.status, .idle)
    }

    func testPrepareStorageTreatsKeychainFailureAsNonfatal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let appState = makeAppState(
            sessionManager: makeSessionManager(
                root: fixture.root.appendingPathComponent("Recordings", isDirectory: true)
            ),
            modelManager: WhisperModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            apiKeyStore: FailingResilienceAPIKeyStore(),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()

        XCTAssertEqual(appState.status, .idle)
        XCTAssertTrue(appState.lastError?.contains("API key could not be loaded") == true)
        XCTAssertFalse(appState.hasOpenAIAPIKey)
    }

    func testAppStateRecoversInterruptedSessionFromMergedTranscriptEndToEnd() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let sessionDirectory = recordingsRoot.appendingPathComponent("crashed-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let metadata = SessionMetadata(
            id: "crashed-session",
            title: "Recovered meeting",
            status: .recording,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = RecordingSession(metadata: metadata, directoryURL: sessionDirectory)
        try SessionJSONCoder.makeEncoder().encode(metadata)
            .write(to: session.manifestURL, options: .atomic)
        let transcript = makeTranscript(sessionID: metadata.id, title: metadata.title)
        try TranscriptJSONCoder.makeEncoder().encode(transcript)
            .write(to: session.mergedTranscriptURL, options: .atomic)

        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            modelManager: WhisperModelManager(modelsRoot: modelsRoot),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        let candidate = try XCTUnwrap(appState.recoveryCandidates.first)
        await appState.recoverSession(candidate)

        XCTAssertEqual(appState.status, .completed)
        XCTAssertTrue(appState.recoveryCandidates.isEmpty)
        let markdownURL = try XCTUnwrap(appState.lastMarkdownURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Recovered transcript text"))
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.status, .recorded)
        XCTAssertEqual(persisted.recovery?.status, .completed)
        XCTAssertEqual(persisted.recovery?.attemptCount, 1)
        XCTAssertEqual(persisted.output?.status, .completed)
        let log = try String(contentsOf: session.processingLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains(#""event":"recoveryCompleted""#))
    }

    func testMarkdownExportDoesNotBlockMainActorDuringRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let sessionDirectory = recordingsRoot.appendingPathComponent("background-export", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let metadata = SessionMetadata(
            id: "background-export",
            title: "Background export",
            status: .recording,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = RecordingSession(metadata: metadata, directoryURL: sessionDirectory)
        try SessionJSONCoder.makeEncoder().encode(metadata)
            .write(to: session.manifestURL, options: .atomic)
        try TranscriptJSONCoder.makeEncoder().encode(
            makeTranscript(sessionID: metadata.id, title: metadata.title)
        ).write(to: session.mergedTranscriptURL, options: .atomic)

        let gate = BlockingFileServiceGate()
        let fileService = BlockingExportProcessingFileService(gate: gate)
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            modelManager: WhisperModelManager(
                modelsRoot: fixture.root.appendingPathComponent("Models", isDirectory: true)
            ),
            processingFileService: fileService,
            defaults: fixture.defaults
        )
        await appState.prepareStorage()
        let candidate = try XCTUnwrap(appState.recoveryCandidates.first)

        let recoveryTask = Task { await appState.recoverSession(candidate) }
        let didReachBackgroundExport = await gate.waitUntilBlocked()

        XCTAssertTrue(didReachBackgroundExport)
        XCTAssertEqual(appState.status, .exporting)
        gate.release()
        await recoveryTask.value
        XCTAssertEqual(appState.status, .completed)
    }

    func testRequiredSystemCaptureFailureTriggersSafeAutomaticStop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let modelURL = modelsRoot.appendingPathComponent(WhisperModelDescriptor.largeV3Turbo.fileName)
        try Data(repeating: 0x42, count: 2_048).write(to: modelURL)

        let systemCapture = ResilienceCaptureService()
        let microphoneCapture = ResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: microphoneCapture
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            modelManager: WhisperModelManager(modelsRoot: modelsRoot),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1_000
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        XCTAssertEqual(appState.status, .recording)
        let session = try XCTUnwrap(appState.currentSession)

        await systemCapture.fail(reason: "Simulated required capture failure")
        try await waitUntil { appState.status != .recording }
        try await waitUntil { appState.status == .completed || appState.status == .failed }

        XCTAssertEqual(appState.status, .completed)
        XCTAssertTrue(appState.lastError?.contains("stopped safely") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.systemAudio?.failureReason, "Simulated required capture failure")
        XCTAssertEqual(persisted.output?.status, .completed)
    }

    func testCancelledLowStorageCheckDoesNotStopRecordingTwice() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let modelURL = modelsRoot.appendingPathComponent(WhisperModelDescriptor.largeV3Turbo.fileName)
        try Data(repeating: 0x42, count: 2_048).write(to: modelURL)

        let storageCheck = SuspendedLowStorageCheck()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: ResilienceCaptureService(),
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            modelManager: WhisperModelManager(modelsRoot: modelsRoot),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1
            ),
            storageStatusProvider: { await storageCheck.status() },
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        await storageCheck.waitUntilRequested()

        let stopTask = Task { await appState.stopRecording() }
        try await waitUntil { appState.status != .recording }
        await storageCheck.resume()
        await stopTask.value
        try await waitUntil { appState.status == .completed || appState.status == .failed }

        XCTAssertEqual(appState.status, .completed)
        XCTAssertFalse(appState.lastError?.contains("Invalid state transition") == true)
    }

    func testTransientSystemAudioStallRecoversWithoutStoppingRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let modelURL = modelsRoot.appendingPathComponent(WhisperModelDescriptor.largeV3Turbo.fileName)
        try Data(repeating: 0x42, count: 2_048).write(to: modelURL)

        let systemCapture = ResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            modelManager: WhisperModelManager(modelsRoot: modelsRoot),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1_000,
                stalledSystemAudioCheckCount: 20
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        await systemCapture.stall()
        try await waitUntil { appState.captureDiagnostics.systemAudio.health() == .stalled }

        await systemCapture.resumeBuffers()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(appState.status, .recording)
        await appState.stopRecording()
        XCTAssertEqual(appState.status, .completed)
    }

    func testPersistentSystemAudioStallTriggersSafeAutomaticStop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recordingsRoot = fixture.root.appendingPathComponent("Recordings", isDirectory: true)
        let modelsRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let modelURL = modelsRoot.appendingPathComponent(WhisperModelDescriptor.largeV3Turbo.fileName)
        try Data(repeating: 0x42, count: 2_048).write(to: modelURL)

        let systemCapture = ResilienceCaptureService()
        let appState = makeAppState(
            sessionManager: makeSessionManager(root: recordingsRoot),
            captureCoordinator: CaptureCoordinator(
                systemAudioCapture: systemCapture,
                microphoneCapture: ResilienceCaptureService()
            ),
            audioFinalizer: ResilienceAudioFinalizer(),
            modelManager: WhisperModelManager(modelsRoot: modelsRoot),
            sessionTranscriber: ResilienceSessionTranscriber(),
            monitoring: CaptureMonitoringConfiguration(
                interval: .milliseconds(5),
                storageCheckEveryTicks: 1_000,
                stalledSystemAudioCheckCount: 2
            ),
            defaults: fixture.defaults
        )

        await appState.prepareStorage()
        await appState.startRecording()
        let session = try XCTUnwrap(appState.currentSession)
        await systemCapture.stall()
        try await waitUntil { appState.status != .recording }
        try await waitUntil { appState.status == .completed || appState.status == .failed }

        XCTAssertEqual(appState.status, .completed)
        XCTAssertTrue(appState.lastError?.contains("system audio capture stalled") == true)
        let log = try String(contentsOf: session.processingLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("System audio capture stopped producing buffers."))
    }

    private func makeSessionManager(root: URL) -> SessionManager {
        SessionManager(
            recordingsRoot: root,
            storageGuard: StorageGuard(
                provider: AppStateCapacityProvider(),
                minimumBytes: 1
            )
        )
    }

    private func makeAppState(
        sessionManager: SessionManager,
        captureCoordinator: CaptureCoordinator = CaptureCoordinator(),
        audioFinalizer: any AudioFinalizing = AudioFinalizer(),
        modelManager: WhisperModelManager,
        sessionTranscriber: any SessionTranscribing = SessionTranscriber(),
        processingFileService: (any ProcessingFileServicing)? = nil,
        monitoring: CaptureMonitoringConfiguration = CaptureMonitoringConfiguration(),
        storageStatusProvider: (@Sendable () async throws -> StorageStatus)? = nil,
        apiKeyStore: any APIKeyStoring = ResilienceAPIKeyStore(),
        defaults: UserDefaults
    ) -> AppState {
        let applicationSettingsStore = ApplicationSettingsStore(defaults: defaults)
        applicationSettingsStore.setMinimumStorageBytes(1)
        return AppState(
            sessionManager: sessionManager,
            captureCoordinator: captureCoordinator,
            audioFinalizer: audioFinalizer,
            modelManager: modelManager,
            sessionTranscriber: sessionTranscriber,
            processingFileService: processingFileService,
            outputFolderStore: OutputFolderStore(defaults: defaults),
            apiKeyStore: apiKeyStore,
            analysisSettingsStore: AnalysisSettingsStore(defaults: defaults),
            whisperSettingsStore: WhisperSettingsStore(defaults: defaults),
            audioRetentionSettingsStore: AudioRetentionSettingsStore(defaults: defaults),
            applicationSettingsStore: applicationSettingsStore,
            captureMonitoringConfiguration: monitoring,
            storageStatusProvider: storageStatusProvider,
            automaticallyManageVADModel: false
        )
    }

    private func makeFixture() throws -> ResilienceTestFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeAppStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "MeetingScribeAppStateTests.\(UUID().uuidString)"
        return ResilienceTestFixture(
            root: root,
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            suiteName: suiteName
        )
    }

    private func makeTranscript(sessionID: String, title: String) -> MergedTranscript {
        MergedTranscript(
            sessionID: sessionID,
            title: title,
            completedAt: Date(timeIntervalSince1970: 1_700_000_010),
            tracks: [],
            segments: [
                TranscriptSegment(
                    id: "segment-000000",
                    source: .system,
                    speaker: "Other",
                    start: 0,
                    end: 1,
                    language: "sk",
                    text: "Recovered transcript text",
                    confidence: nil
                ),
            ]
        )
    }

    private func decodeMetadata(at url: URL) throws -> SessionMetadata {
        try SessionJSONCoder.makeDecoder().decode(SessionMetadata.self, from: Data(contentsOf: url))
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for AppState transition.")
    }
}

private actor BlockingExportProcessingFileService: ProcessingFileServicing {
    private let delegate = ProcessingFileService()
    private let gate: BlockingFileServiceGate

    init(gate: BlockingFileServiceGate) {
        self.gate = gate
    }

    func loadRecoveredArtifacts(
        from session: RecordingSession
    ) async -> RecoveredProcessingArtifacts? {
        await delegate.loadRecoveredArtifacts(from: session)
    }

    func persistAnalysis(_ analysis: MeetingAnalysis, to url: URL) async throws {
        try await delegate.persistAnalysis(analysis, to: url)
    }

    func exportMarkdown(
        session: SessionMetadata,
        transcript: MergedTranscript,
        analysis: MeetingAnalysis?,
        to directoryURL: URL
    ) async throws -> MarkdownExportResult {
        gate.block()
        return try await delegate.exportMarkdown(
            session: session,
            transcript: transcript,
            analysis: analysis,
            to: directoryURL
        )
    }
}

private final class BlockingFileServiceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false

    func block() {
        condition.lock()
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<500 {
            if blockedStatus() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private func blockedStatus() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor SuspendedLowStorageCheck {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var statusContinuation: CheckedContinuation<StorageStatus, Never>?
    private var wasRequested = false

    func status() async -> StorageStatus {
        wasRequested = true
        requestContinuation?.resume()
        requestContinuation = nil
        return await withCheckedContinuation { continuation in
            statusContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        guard !wasRequested else { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func resume() {
        statusContinuation?.resume(
            returning: StorageStatus(availableBytes: 0, requiredBytes: 1)
        )
        statusContinuation = nil
    }
}

private struct ResilienceTestFixture {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct AppStateCapacityProvider: StorageCapacityProviding {
    func availableCapacity(at url: URL) throws -> Int64 { 1_000_000 }
}

private actor ResilienceAPIKeyStore: APIKeyStoring {
    func save(_ apiKey: String) async throws {}
    func load() async throws -> String? { nil }
    func delete() async throws {}
}

private actor CountingResilienceAPIKeyStore: APIKeyStoring {
    private var loads = 0

    func save(_ apiKey: String) async throws {}
    func load() async throws -> String? {
        loads += 1
        return nil
    }
    func delete() async throws {}
    func loadCount() -> Int { loads }
}

private actor FailingResilienceAPIKeyStore: APIKeyStoring {
    func save(_ apiKey: String) async throws {}
    func load() async throws -> String? { throw KeychainStoreError.invalidUTF8 }
    func delete() async throws {}
}

private actor ResilienceCaptureService: AudioCaptureService {
    private var current = AudioCaptureDiagnostics.empty

    func start(outputURL: URL) async throws {
        try Data("preserved mock audio".utf8).write(to: outputURL, options: .atomic)
        current = AudioCaptureDiagnostics(
            fileName: outputURL.lastPathComponent,
            startedAt: Date()
        )
        current.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 1,
            presentationTimestamp: 0
        )
    }

    func stop() async -> AudioCaptureDiagnostics { current }
    func diagnostics() async -> AudioCaptureDiagnostics { current }

    func fail(reason: String) {
        current.failureReason = reason
    }

    func stall() {
        current.lastBufferReceivedAt = Date().addingTimeInterval(-20)
    }

    func resumeBuffers() {
        current.registerBuffer(
            frameCount: 4_800,
            sampleRate: 48_000,
            channelCount: 1,
            presentationTimestamp: current.lastPresentationTimestamp ?? 0
        )
    }
}

private struct ResilienceAudioFinalizer: AudioFinalizing {
    func finalize(
        session: RecordingSession,
        diagnostics: CaptureSessionDiagnostics
    ) async throws -> AudioFinalizationMetadata {
        AudioFinalizationMetadata(
            completedAt: Date(),
            timelineOrigin: 0,
            system: FinalizedAudioTrackMetadata(
                fileName: session.systemWorkingAudioURL.lastPathComponent,
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 1_600,
                durationSeconds: 0.1,
                timelineOffsetSeconds: 0
            ),
            microphone: nil,
            warnings: []
        )
    }
}

private actor ResilienceSessionTranscriber: SessionTranscribing {
    func transcribe(
        session: RecordingSession,
        finalization: AudioFinalizationMetadata,
        modelURL: URL,
        language: TranscriptionLanguage
    ) async throws -> SessionTranscriptionResult {
        let segment = TranscriptSegment(
            id: "segment-000000",
            source: .system,
            speaker: "Other",
            start: 0,
            end: 0.1,
            language: "sk",
            text: "Safely stopped transcript",
            confidence: nil
        )
        let track = TrackTranscript(
            source: .system,
            model: modelURL.lastPathComponent,
            requestedLanguage: language,
            detectedLanguage: "sk",
            completedAt: Date(),
            segments: [segment]
        )
        let merged = MergedTranscript(
            sessionID: session.metadata.id,
            title: session.metadata.title,
            completedAt: Date(),
            tracks: [],
            segments: [segment]
        )
        return SessionTranscriptionResult(
            metadata: SessionTranscriptionMetadata(
                status: .completed,
                model: modelURL.lastPathComponent,
                systemSegmentCount: 1,
                microphoneSegmentCount: 0,
                mergedSegmentCount: 1,
                warnings: [],
                failureReason: nil
            ),
            systemTranscript: track,
            microphoneTranscript: nil,
            mergedTranscript: merged
        )
    }
}
