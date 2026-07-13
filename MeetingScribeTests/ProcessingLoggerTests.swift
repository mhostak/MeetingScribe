import Foundation
import XCTest
@testable import MeetingScribe

final class ProcessingLoggerTests: XCTestCase {
    func testLoggerWritesJSONLinesAndRedactsSecrets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeLoggerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = RecordingSession(
            metadata: SessionMetadata(
                id: "session-1",
                title: "Private transcript title",
                status: .recording,
                createdAt: Date()
            ),
            directoryURL: root
        )
        let logger = ProcessingLogger(now: { Date(timeIntervalSince1970: 1_700_000_000) })

        try await logger.log(
            .processingFailed,
            for: session,
            attributes: [
                .model("model.bin"),
                .reason("Bearer abc.def and sk-supersecret123456789\nsecond line"),
            ]
        )
        try await logger.log(
            .transcriptionCompleted,
            for: session,
            attributes: [
                .systemAudioDurationSeconds(3_600),
                .systemActiveDurationSeconds(3_300),
                .systemSkippedDurationSeconds(300),
                .systemInferenceInputDurationSeconds(3_600),
                .systemTranscriptionWallTimeSeconds(680),
                .systemChunkCount(1),
                .microphoneAudioDurationSeconds(3_600),
                .microphoneActiveDurationSeconds(800),
                .microphoneSkippedDurationSeconds(2_800),
                .microphoneInferenceInputDurationSeconds(825),
                .microphoneTranscriptionWallTimeSeconds(186),
                .microphoneChunkCount(3),
            ]
        )

        let content = try String(contentsOf: session.processingLogURL, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"))
        XCTAssertTrue(content.contains(#""event":"processingFailed""#))
        XCTAssertTrue(content.contains("[REDACTED]"))
        XCTAssertFalse(content.contains("abc.def"))
        XCTAssertFalse(content.contains("sk-supersecret"))
        XCTAssertFalse(content.contains("Private transcript title"))
        XCTAssertEqual(content.split(separator: "\n").count, 2)
        XCTAssertTrue(content.contains(#""systemChunkCount":"1""#))
        XCTAssertTrue(content.contains(#""microphoneChunkCount":"3""#))
        XCTAssertTrue(content.contains(#""microphoneSkippedDurationSeconds":"2800.0""#))
    }
}
