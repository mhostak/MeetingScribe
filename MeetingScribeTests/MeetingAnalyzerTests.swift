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
                speaker: index.isMultiple(of: 2) ? "Other" : "Speaker B",
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
        XCTAssertEqual(run.analysis.markdown, "Consolidated")
        XCTAssertTrue(requests[0].content.contains("[00:00:00]"))
        XCTAssertFalse(requests[0].content.contains("segment-000000"))
    }

    func testUserNotesAreAttachedToEveryRequest() async throws {
        let provider = MockAnalysisProvider()
        let segments = (0..<4).map { index in
            TranscriptSegment(
                id: String(format: "segment-%06d", index),
                source: .system,
                speaker: "Other",
                start: Double(index * 10),
                end: Double(index * 10 + 5),
                language: "sk",
                text: String(repeating: "slovo ", count: 110),
                confidence: nil
            )
        }

        _ = try await MeetingAnalyzer(
            provider: provider,
            maxInputCharacters: 1_000
        ).analyze(
            session: makeSession(),
            transcript: makeTranscript(segments: segments),
            userNotes: "First note"
        )

        let requests = await provider.requests
        XCTAssertTrue(requests.contains { $0.mode == .transcript })
        XCTAssertTrue(requests.contains { $0.mode == .consolidation })
        XCTAssertTrue(requests.allSatisfy { $0.userNotes == "First note" })
    }

    func testWithoutUserNotesNoRequestContainsNotes() async throws {
        let provider = MockAnalysisProvider()
        let transcript = makeTranscript(segments: [
            TranscriptSegment(
                id: "segment-1",
                source: .system,
                speaker: "Other",
                start: 0,
                end: 1,
                language: "sk",
                text: "Text meetingu",
                confidence: nil
            ),
        ])

        _ = try await MeetingAnalyzer(provider: provider).analyze(
            session: makeSession(),
            transcript: transcript
        )

        let requests = await provider.requests
        XCTAssertTrue(requests.allSatisfy { $0.userNotes == nil })
    }

    func testLongUserNotesAreTruncatedWithMarker() {
        let notes = String(repeating: "a", count: AnalysisPrompt.maximumUserNotesCharacters + 7)
        let truncated = AnalysisPrompt.truncateUserNotes(notes)

        XCTAssertTrue(truncated.hasPrefix(String(repeating: "a", count: 20_000)))
        XCTAssertTrue(
            truncated.hasSuffix(
                "\n[notes truncated: 7 more characters; "
                    + "the full notes are exported to Markdown]"
            )
        )
        let multibyteNotes = String(
            repeating: "é",
            count: AnalysisPrompt.maximumUserNotesCharacters + 1
        )
        XCTAssertTrue(
            AnalysisPrompt.truncateUserNotes(multibyteNotes)
                .hasPrefix(String(repeating: "é", count: 20_000))
        )
    }

    func testUserNotesReservationWithoutContentRoomThrows() async throws {
        let provider = MockAnalysisProvider()
        let transcript = makeTranscript(segments: [
            TranscriptSegment(
                id: "segment-1",
                source: .system,
                speaker: "Other",
                start: 0,
                end: 1,
                language: "sk",
                text: "Text meetingu",
                confidence: nil
            ),
        ])

        do {
            _ = try await MeetingAnalyzer(
                provider: provider,
                maxInputCharacters: 1_000
            ).analyze(
                session: makeSession(),
                transcript: transcript,
                userNotes: String(repeating: "n", count: 1_000)
            )
            XCTFail("Expected notes reservation to leave no content room.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .transcriptChunkTooLarge)
        }

        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSessionOutputLanguageIsUsedForEveryAnalysisRequest() async throws {
        let provider = MockAnalysisProvider()
        let transcript = makeTranscript(segments: [
            TranscriptSegment(
                id: "segment-1",
                source: .system,
                speaker: "Other",
                start: 0,
                end: 1,
                language: "sk",
                text: "Text meetingu",
                confidence: nil
            ),
        ])

        _ = try await MeetingAnalyzer(provider: provider).analyze(
            session: makeSession(outputLanguage: .czech),
            transcript: transcript
        )

        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.preferredLanguage), [.czech])
    }

    func testOversizedSingleSourceBlockIsSplitBeforeAnalysis() async throws {
        let provider = MockAnalysisProvider()
        let segment = TranscriptSegment(
            id: "source-block-000000",
            source: .microphone,
            speaker: "On-site participants",
            start: 0,
            end: 3_600,
            language: "sk",
            text: String(repeating: "slovo ", count: 400),
            confidence: nil
        )

        let run = try await MeetingAnalyzer(
            provider: provider,
            maxInputCharacters: 1_000
        ).analyze(
            session: makeSession(),
            transcript: makeTranscript(segments: [segment])
        )

        let requests = await provider.requests
        XCTAssertGreaterThan(run.transcriptChunkCount, 1)
        XCTAssertEqual(requests.filter { $0.mode == .transcript }.count, run.transcriptChunkCount)
        XCTAssertTrue(requests.allSatisfy { $0.content.count <= 1_000 })
        XCTAssertFalse(requests[0].content.contains("source-block-000000"))
        XCTAssertTrue(requests[0].content.contains("On-site user {microphone, sk}"))
        XCTAssertTrue(requests[1].content.contains("[00:"))

        let transcriptRequests = requests.filter { $0.mode == .transcript }
        let firstBody = transcriptRequests[0].content.split(separator: "\n").dropFirst(2)
        let secondBody = transcriptRequests[1].content.split(separator: "\n").dropFirst(2)
        let firstWords = Set(firstBody.joined(separator: " ").split(separator: " ").suffix(10))
        let secondWords = Set(secondBody.joined(separator: " ").split(separator: " ").prefix(20))
        XCTAssertFalse(firstWords.isDisjoint(with: secondWords))
    }

    func testLongBlockPrefersSentenceBoundaryAndInterpolatesOverlapTimestamp() async throws {
        let provider = MockAnalysisProvider()
        let sentence = String(repeating: "a", count: 680) + ". "
        let segment = TranscriptSegment(
            id: "source-block-1",
            source: .microphone,
            speaker: "On-site participants",
            start: 0,
            end: 1_000,
            language: "sk",
            text: sentence + String(repeating: "b", count: 500),
            confidence: nil
        )

        _ = try await MeetingAnalyzer(
            provider: provider,
            maxInputCharacters: 1_000
        ).analyze(
            session: makeSession(),
            transcript: makeTranscript(segments: [segment])
        )

        let requests = await provider.requests.filter { $0.mode == .transcript }
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].content.hasSuffix("."))
        XCTAssertTrue(requests[1].content.contains("[00:"))
        XCTAssertFalse(requests[1].content.contains("[00:00:00]"))
    }

    func testShortSegmentsOverlapAcrossTranscriptChunks() async throws {
        let provider = MockAnalysisProvider()
        let segments = (0..<12).map { index in
            TranscriptSegment(
                id: "segment-\(index)",
                source: .microphone,
                speaker: "Speaker B",
                start: Double(index),
                end: Double(index + 1),
                language: "sk",
                text: String(repeating: "word", count: 12),
                confidence: nil
            )
        }

        _ = try await MeetingAnalyzer(
            provider: provider,
            maxInputCharacters: 1_000
        ).analyze(
            session: makeSession(),
            transcript: makeTranscript(segments: segments)
        )

        let requests = await provider.requests.filter { $0.mode == .transcript }
        XCTAssertGreaterThan(requests.count, 1)
        let firstTimestamps = Set(requests[0].content.matches(of: /\[\d\d:\d\d:\d\d\]/).map(\.output))
        let secondTimestamps = Set(requests[1].content.matches(of: /\[\d\d:\d\d:\d\d\]/).map(\.output))
        XCTAssertFalse(firstTimestamps.isDisjoint(with: secondTimestamps))
    }

    func testSegmentMetadataThatLeavesNoRoomForTextIsRejected() async {
        let provider = MockAnalysisProvider()
        let segment = TranscriptSegment(
            id: "segment-1",
            source: .system,
            speaker: "Remote participants",
            start: 0,
            end: 1,
            language: String(repeating: "x", count: 1_000),
            text: "Text meetingu",
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
            XCTFail("Expected oversized segment metadata to be rejected.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .transcriptChunkTooLarge)
        }
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testConfirmedParticipantNamesAreIncludedOnlyWithExplicitAnalysisOptIn() async throws {
        let optedInProvider = MockAnalysisProvider()
        let optedOutProvider = MockAnalysisProvider()
        let transcript = makeTranscript(segments: [
            TranscriptSegment(
                id: "segment-1",
                source: .system,
                speaker: "Other",
                start: 0,
                end: 1,
                language: "sk",
                text: "Text meetingu",
                confidence: nil
            ),
        ])

        _ = try await MeetingAnalyzer(provider: optedInProvider).analyze(
            session: makeSession(shareParticipantNamesWithAnalysis: true),
            transcript: transcript
        )
        _ = try await MeetingAnalyzer(provider: optedOutProvider).analyze(
            session: makeSession(shareParticipantNamesWithAnalysis: false),
            transcript: transcript
        )

        let optedInRequests = await optedInProvider.requests
        let optedOutRequests = await optedOutProvider.requests
        XCTAssertTrue(optedInRequests[0].content.contains("system = remote participant(s): Participant One"))
        XCTAssertTrue(optedInRequests[0].content.contains("microphone = recording user (on-site)"))
        XCTAssertFalse(optedOutRequests[0].content.contains("Participant One"))
    }

    func testIncludedCalendarDescriptionIsProvidedAsAnalysisContext() async throws {
        let provider = MockAnalysisProvider()
        let transcript = makeTranscript(segments: [
            TranscriptSegment(
                id: "segment-1",
                source: .system,
                speaker: "Remote participants",
                start: 0,
                end: 1,
                language: "sk",
                text: "Text meetingu",
                confidence: nil
            ),
        ])

        _ = try await MeetingAnalyzer(provider: provider).analyze(
            session: makeSession(eventDescription: "Discuss the launch plan."),
            transcript: transcript
        )

        let requests = await provider.requests
        XCTAssertTrue(requests[0].content.contains("Confirmed calendar event description:"))
        XCTAssertTrue(requests[0].content.contains("Discuss the launch plan."))
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

    private func makeSession(
        shareParticipantNamesWithAnalysis: Bool? = nil,
        outputLanguage: OutputLanguage? = nil,
        eventDescription: String? = nil
    ) -> SessionMetadata {
        SessionMetadata(
            id: "session-1",
            title: "Test meeting",
            status: .recorded,
            createdAt: Date(),
            outputLanguage: outputLanguage,
            calendarEvent: (shareParticipantNamesWithAnalysis != nil || eventDescription != nil)
                ? CalendarEventSnapshot(
                    source: .appleCalendar,
                    title: "Test meeting",
                    startsAt: Date(),
                    endsAt: Date().addingTimeInterval(3_600),
                    selectedAt: Date(),
                    participants: [
                        ConfirmedParticipant(displayName: "Participant One"),
                    ],
                    shareParticipantNamesWithAnalysis: shareParticipantNamesWithAnalysis ?? false,
                    eventDescription: eventDescription
                )
                : nil
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

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisMarkdown {
        requests.append(request)
        if cancelAfterFirstRequest, requests.count == 1 {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        return AnalysisMarkdown(
            markdown: request.mode == .consolidation ? "Consolidated" : "Partial"
        )
    }
}

private actor LargePartialAnalysisProvider: AnalysisProvider {
    private(set) var requestCount = 0

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisMarkdown {
        requestCount += 1
        return AnalysisMarkdown(markdown: String(repeating: "y", count: 700))
    }
}
