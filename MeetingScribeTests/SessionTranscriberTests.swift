import Foundation
import XCTest
@testable import MeetingScribe

final class SessionTranscriberTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeTranscriber-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testTranscribesAndPersistsBothTracksWithTimelineOffsets() async throws {
        let service = MockTranscriptionService()
        let completedAt = Date(timeIntervalSince1970: 1_725_876_700)
        let transcriber = SessionTranscriber(service: service, now: { completedAt })
        let session = makeSession()

        let result = try await transcriber.transcribe(
            session: session,
            finalization: finalization(),
            modelURL: temporaryRoot.appendingPathComponent("ggml-test.bin"),
            language: .automatic
        )

        XCTAssertEqual(result.metadata.status, .completed)
        XCTAssertEqual(result.metadata.systemSegmentCount, 1)
        XCTAssertEqual(result.metadata.microphoneSegmentCount, 1)
        XCTAssertEqual(result.metadata.mergedSegmentCount, 2)
        XCTAssertEqual(result.metadata.systemPerformance?.chunkCount, 2)
        XCTAssertEqual(result.metadata.microphonePerformance?.chunkCount, 1)
        XCTAssertTrue(result.metadata.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemTrackTranscriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneTrackTranscriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.mergedTranscriptURL.path))

        let options = await service.receivedOptions
        XCTAssertEqual(options.map(\.source), [.system, .microphone])
        XCTAssertEqual(options.map(\.language), [.automatic, .automatic])
        XCTAssertEqual(options.map(\.timelineOffsetSeconds), [0, 0.25])
        XCTAssertEqual(options.map(\.speaker), ["Other", "Martin"])
        let audioURLs = await service.receivedAudioURLs
        XCTAssertEqual(
            audioURLs.map(\.lastPathComponent),
            ["system-16k.wav", "microphone-16k.wav"]
        )

        let systemData = try Data(contentsOf: session.systemTrackTranscriptURL)
        let persisted = try TranscriptJSONCoder.makeDecoder().decode(
            TrackTranscript.self,
            from: systemData
        )
        XCTAssertEqual(persisted.source, .system)

        let mergedData = try Data(contentsOf: session.mergedTranscriptURL)
        let merged = try TranscriptJSONCoder.makeDecoder().decode(
            MergedTranscript.self,
            from: mergedData
        )
        XCTAssertEqual(merged.sessionID, "test-session")
        XCTAssertEqual(merged.segments.map(\.source), [.system, .microphone])
        let releaseCount = await service.releaseCount
        XCTAssertEqual(releaseCount, 1)
    }

    func testMicrophoneTranscriptionFailureDoesNotDiscardSystemTranscript() async throws {
        let service = MockTranscriptionService(failMicrophone: true)
        let session = makeSession()
        let transcriber = SessionTranscriber(service: service)

        let result = try await transcriber.transcribe(
            session: session,
            finalization: finalization(),
            modelURL: temporaryRoot.appendingPathComponent("ggml-test.bin"),
            language: .slovak
        )

        XCTAssertEqual(result.metadata.status, .completed)
        XCTAssertEqual(result.metadata.systemSegmentCount, 1)
        XCTAssertNil(result.metadata.microphoneSegmentCount)
        XCTAssertEqual(result.metadata.mergedSegmentCount, 1)
        XCTAssertEqual(result.metadata.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemTrackTranscriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.microphoneTrackTranscriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.mergedTranscriptURL.path))
        XCTAssertEqual(result.mergedTranscript.segments.map(\.source), [.system])
        let releaseCount = await service.releaseCount
        XCTAssertEqual(releaseCount, 1)
    }

    func testEmptyMicrophoneTranscriptIsPersistedAndReportedAsNoSpeech() async throws {
        let service = MockTranscriptionService(emptyMicrophone: true)
        let session = makeSession()
        let transcriber = SessionTranscriber(service: service)

        let result = try await transcriber.transcribe(
            session: session,
            finalization: finalization(),
            modelURL: temporaryRoot.appendingPathComponent("ggml-test.bin"),
            language: .czech
        )

        XCTAssertEqual(result.metadata.systemSegmentCount, 1)
        XCTAssertEqual(result.metadata.microphoneSegmentCount, 0)
        XCTAssertEqual(result.metadata.mergedSegmentCount, 1)
        XCTAssertEqual(result.metadata.warnings, ["No speech was detected in microphone audio."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneTrackTranscriptURL.path))
        XCTAssertTrue(result.microphoneTranscript?.segments.isEmpty == true)
    }

    func testCancellationAfterSystemTrackPreventsPersistenceAndMicrophoneWork() async throws {
        let service = MockTranscriptionService(cancelAfterSystem: true)
        let session = makeSession()
        let transcriber = SessionTranscriber(service: service)

        do {
            _ = try await transcriber.transcribe(
                session: session,
                finalization: finalization(),
                modelURL: temporaryRoot.appendingPathComponent("ggml-test.bin"),
                language: .slovak
            )
            XCTFail("Expected transcription cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let options = await service.receivedOptions
        XCTAssertEqual(options.map(\.source), [.system])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.systemTrackTranscriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.microphoneTrackTranscriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.mergedTranscriptURL.path))
        let releaseCount = await service.releaseCount
        XCTAssertEqual(releaseCount, 1)
    }

    private func makeSession() -> RecordingSession {
        RecordingSession(
            metadata: SessionMetadata(
                id: "test-session",
                title: "Test",
                status: .recording,
                createdAt: Date(),
                startedAt: Date()
            ),
            directoryURL: temporaryRoot
        )
    }

    private func finalization() -> AudioFinalizationMetadata {
        AudioFinalizationMetadata(
            completedAt: Date(),
            timelineOrigin: 100,
            system: FinalizedAudioTrackMetadata(
                fileName: "system-16k.wav",
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 16_000,
                durationSeconds: 1,
                timelineOffsetSeconds: 0
            ),
            microphone: FinalizedAudioTrackMetadata(
                fileName: "microphone-16k.wav",
                sampleRate: 16_000,
                channelCount: 1,
                totalFrames: 16_000,
                durationSeconds: 1,
                timelineOffsetSeconds: 0.25
            ),
            warnings: []
        )
    }
}

private actor MockTranscriptionService: TranscriptionService {
    let failMicrophone: Bool
    let cancelAfterSystem: Bool
    let emptyMicrophone: Bool
    private(set) var receivedOptions: [TranscriptionOptions] = []
    private(set) var receivedAudioURLs: [URL] = []
    private(set) var releaseCount = 0

    init(
        failMicrophone: Bool = false,
        cancelAfterSystem: Bool = false,
        emptyMicrophone: Bool = false
    ) {
        self.failMicrophone = failMicrophone
        self.cancelAfterSystem = cancelAfterSystem
        self.emptyMicrophone = emptyMicrophone
    }

    func transcribe(
        audioURL: URL,
        modelURL: URL,
        options: TranscriptionOptions
    ) async throws -> TrackTranscript {
        receivedAudioURLs.append(audioURL)
        receivedOptions.append(options)
        if failMicrophone, options.source == .microphone {
            throw TranscriptionError.inferenceFailed(code: -1)
        }
        let segments = emptyMicrophone && options.source == .microphone ? [] : [
            TranscriptSegment(
                id: "\(options.source.rawValue)-000000",
                source: options.source,
                speaker: options.speaker,
                start: options.timelineOffsetSeconds,
                end: options.timelineOffsetSeconds + 1,
                language: "sk",
                text: "Test",
                confidence: nil
            )
        ]
        let transcript = TrackTranscript(
            source: options.source,
            model: modelURL.lastPathComponent,
            requestedLanguage: options.language,
            detectedLanguage: options.language == .automatic ? "sk" : options.language.rawValue,
            completedAt: Date(),
            segments: segments,
            performance: TrackTranscriptionPerformance(
                audioDurationSeconds: 60,
                activeDurationSeconds: options.source == .system ? 45 : 10,
                skippedDurationSeconds: options.source == .system ? 15 : 50,
                inferenceInputDurationSeconds: options.source == .system ? 46 : 10,
                chunkCount: options.source == .system ? 2 : 1,
                wallTimeSeconds: options.source == .system ? 8 : 2
            )
        )
        if cancelAfterSystem, options.source == .system {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        return transcript
    }

    func releaseResources() {
        releaseCount += 1
    }
}
