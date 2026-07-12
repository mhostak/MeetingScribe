import Foundation
import XCTest
@testable import MeetingScribe

@MainActor
final class AppStateResilienceTests: XCTestCase {
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

        XCTAssertEqual(appState.status, .completed)
        XCTAssertTrue(appState.lastError?.contains("stopped safely") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemAudioURL.path))
        let persisted = try decodeMetadata(at: session.manifestURL)
        XCTAssertEqual(persisted.systemAudio?.failureReason, "Simulated required capture failure")
        XCTAssertEqual(persisted.output?.status, .completed)
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
        monitoring: CaptureMonitoringConfiguration = CaptureMonitoringConfiguration(),
        defaults: UserDefaults
    ) -> AppState {
        AppState(
            sessionManager: sessionManager,
            captureCoordinator: captureCoordinator,
            audioFinalizer: audioFinalizer,
            modelManager: modelManager,
            sessionTranscriber: sessionTranscriber,
            outputFolderStore: OutputFolderStore(defaults: defaults),
            apiKeyStore: ResilienceAPIKeyStore(),
            analysisSettingsStore: AnalysisSettingsStore(defaults: defaults),
            whisperSettingsStore: WhisperSettingsStore(defaults: defaults),
            captureMonitoringConfiguration: monitoring
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
