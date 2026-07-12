import Foundation
import XCTest
@testable import MeetingScribe

final class MeetingAnalyzerTests: XCTestCase {
    func testEmptyTranscriptDoesNotCallProvider() async throws {
        let provider = MockAnalysisProvider()
        let run = try await MeetingAnalyzer(provider: provider).analyze(
            session: makeSession(),
            transcript: makeTranscript(segments: [])
        )

        XCTAssertEqual(run.analysis, .empty)
        XCTAssertEqual(run.transcriptChunkCount, 0)
        XCTAssertEqual(run.requestCount, 0)
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLongTranscriptUsesChunkRequestsThenConsolidates() async throws {
        let provider = MockAnalysisProvider()
        let segments = (0..<4).map { index in
            TranscriptSegment(
                id: String(format: "segment-%06d", index),
                source: index.isMultiple(of: 2) ? .system : .microphone,
                speaker: index.isMultiple(of: 2) ? "Other" : "Martin",
                start: Double(index * 10),
                end: Double(index * 10 + 5),
                language: "sk",
                text: String(repeating: "slovo ", count: 110),
                confidence: nil
            )
        }

        let run = try await MeetingAnalyzer(
            provider: provider,
            maxInputCharacters: 1_000
        ).analyze(
            session: makeSession(),
            transcript: makeTranscript(segments: segments)
        )

        let requests = await provider.requests
        XCTAssertEqual(run.transcriptChunkCount, 4)
        XCTAssertEqual(run.requestCount, 5)
        XCTAssertEqual(requests.map(\.mode), [
            .transcript, .transcript, .transcript, .transcript, .consolidation,
        ])
        XCTAssertEqual(run.analysis.summary, "Consolidated")
        XCTAssertTrue(requests[0].content.contains("[segment-000000]"))
    }

    func testOversizedSingleSegmentIsRejectedWithoutProviderCall() async {
        let provider = MockAnalysisProvider()
        let segment = TranscriptSegment(
            id: "segment-000000",
            source: .system,
            speaker: "Other",
            start: 0,
            end: 1,
            language: "sk",
            text: String(repeating: "x", count: 1_100),
            confidence: nil
        )

        do {
            _ = try await MeetingAnalyzer(
                provider: provider,
                maxInputCharacters: 1_000
            ).analyze(
                session: makeSession(),
                transcript: makeTranscript(segments: [segment])
            )
            XCTFail("Expected oversized input to be rejected.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .transcriptChunkTooLarge)
        }
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testConsolidationDeadEndIsRejectedInsteadOfLooping() async {
        let provider = LargePartialAnalysisProvider()
        let segments = (0..<2).map { index in
            TranscriptSegment(
                id: String(format: "segment-%06d", index),
                source: .system,
                speaker: "Other",
                start: Double(index),
                end: Double(index + 1),
                language: "sk",
                text: String(repeating: "x", count: 700),
                confidence: nil
            )
        }

        do {
            _ = try await MeetingAnalyzer(
                provider: provider,
                maxInputCharacters: 1_000
            ).analyze(
                session: makeSession(),
                transcript: makeTranscript(segments: segments)
            )
            XCTFail("Expected non-reducible consolidation to fail.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .transcriptChunkTooLarge)
        }
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testCancellationAfterFirstRequestStopsRemainingAnalysis() async throws {
        let provider = MockAnalysisProvider(cancelAfterFirstRequest: true)
        let segments = (0..<3).map { index in
            TranscriptSegment(
                id: "segment-\(index)",
                source: .system,
                speaker: "Other",
                start: Double(index),
                end: Double(index + 1),
                language: "sk",
                text: String(repeating: "slovo ", count: 110),
                confidence: nil
            )
        }

        do {
            _ = try await MeetingAnalyzer(
                provider: provider,
                maxInputCharacters: 1_000
            ).analyze(
                session: makeSession(),
                transcript: makeTranscript(segments: segments)
            )
            XCTFail("Expected analysis cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
    }

    private func makeSession() -> SessionMetadata {
        SessionMetadata(
            id: "session-1",
            title: "Test meeting",
            status: .recorded,
            createdAt: Date()
        )
    }

    private func makeTranscript(segments: [TranscriptSegment]) -> MergedTranscript {
        MergedTranscript(
            sessionID: "session-1",
            title: "Test meeting",
            completedAt: Date(),
            tracks: [],
            segments: segments
        )
    }
}

private actor MockAnalysisProvider: AnalysisProvider {
    let cancelAfterFirstRequest: Bool
    private(set) var requests: [AnalysisRequest] = []

    init(cancelAfterFirstRequest: Bool = false) {
        self.cancelAfterFirstRequest = cancelAfterFirstRequest
    }

    func analyze(_ request: AnalysisRequest) async throws -> MeetingAnalysis {
        requests.append(request)
        if cancelAfterFirstRequest, requests.count == 1 {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        return MeetingAnalysis(
            summary: request.mode == .consolidation ? "Consolidated" : "Partial",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risksAndBlockers: [],
            nextMeetingTopics: []
        )
    }
}

private actor LargePartialAnalysisProvider: AnalysisProvider {
    private(set) var requestCount = 0

    func analyze(_ request: AnalysisRequest) async throws -> MeetingAnalysis {
        requestCount += 1
        return MeetingAnalysis(
            summary: String(repeating: "y", count: 700),
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risksAndBlockers: [],
            nextMeetingTopics: []
        )
    }
}
