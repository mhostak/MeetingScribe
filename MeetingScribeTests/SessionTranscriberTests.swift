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
        XCTAssertTrue(result.metadata.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.systemTrackTranscriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.microphoneTrackTranscriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.mergedTranscriptURL.path))

        let options = await service.receivedOptions
        XCTAssertEqual(options.map(\.source), [.system, .microphone])
        XCTAssertEqual(options.map(\.timelineOffsetSeconds), [0, 0.25])
        XCTAssertEqual(options.map(\.speaker), ["Other", "Martin"])

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
    private(set) var receivedOptions: [TranscriptionOptions] = []

    init(failMicrophone: Bool = false) {
        self.failMicrophone = failMicrophone
    }

    func transcribe(
        audioURL: URL,
        modelURL: URL,
        options: TranscriptionOptions
    ) async throws -> TrackTranscript {
        receivedOptions.append(options)
        if failMicrophone, options.source == .microphone {
            throw TranscriptionError.inferenceFailed(code: -1)
        }
        return TrackTranscript(
            source: options.source,
            model: modelURL.lastPathComponent,
            requestedLanguage: options.language,
            detectedLanguage: options.language == .automatic ? "sk" : options.language.rawValue,
            completedAt: Date(),
            segments: [
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
        )
    }
}
