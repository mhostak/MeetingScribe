import Foundation
import XCTest
@testable import MeetingScribe

final class TranscriptModelsTests: XCTestCase {
    func testTranscriptSanitizerRemovesEmptyAndNonSpeechMarkers() {
        XCTAssertNil(TranscriptSanitizer.meaningfulText(from: "  \n"))
        XCTAssertNil(TranscriptSanitizer.meaningfulText(from: "[BLANK_AUDIO]"))
        XCTAssertNil(TranscriptSanitizer.meaningfulText(from: " [Silence] "))
        XCTAssertNil(TranscriptSanitizer.meaningfulText(from: "(silence)"))
        XCTAssertEqual(
            TranscriptSanitizer.meaningfulText(from: "  Dobrý deň. \n"),
            "Dobrý deň."
        )
    }

    func testTrackTranscriptJSONRoundTripPreservesTimestampedSegment() throws {
        let provenance = TranscriptionProvenance(
            engine: "FluidAudio",
            engineVersion: "0.15.5",
            model: "parakeet-tdt-0.6b-v3-coreml",
            modelRevision: "reviewed-revision",
            configurationRevision: "parakeet-v3-long-input-v1"
        )
        let transcript = TrackTranscript(
            source: .microphone,
            model: provenance.model,
            requestedLanguage: .automatic,
            detectedLanguage: "sk",
            completedAt: Date(timeIntervalSince1970: 1_725_876_700),
            segments: [
                TranscriptSegment(
                    id: "microphone-000001",
                    source: .microphone,
                    speaker: "Martin",
                    start: 2.5,
                    end: 8.75,
                    language: "sk",
                    text: "Mali by sme to dokončiť do konca týždňa.",
                    confidence: nil
                )
            ],
            performance: TrackTranscriptionPerformance(
                audioDurationSeconds: 60,
                activeDurationSeconds: 20,
                skippedDurationSeconds: 40,
                inferenceInputDurationSeconds: 21,
                chunkCount: 2,
                wallTimeSeconds: 4
            ),
            provenance: provenance
        )

        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        let decoded = try TranscriptJSONCoder.makeDecoder().decode(
            TrackTranscript.self,
            from: data
        )

        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.provenance, provenance)
    }

    func testMergedTranscriptJSONRoundTripPreservesTrackMetadata() throws {
        let transcript = MergedTranscript(
            sessionID: "session-1",
            title: "SOFA weekly",
            completedAt: Date(timeIntervalSince1970: 1_725_876_700),
            tracks: [
                MergedTranscriptTrack(
                    source: .system,
                    model: "ggml-test.bin",
                    requestedLanguage: .automatic,
                    detectedLanguage: "cs",
                    segmentCount: 0
                ),
            ],
            segments: []
        )

        let data = try TranscriptJSONCoder.makeEncoder().encode(transcript)
        let decoded = try TranscriptJSONCoder.makeDecoder().decode(
            MergedTranscript.self,
            from: data
        )

        XCTAssertEqual(decoded, transcript)
    }

    func testContinuousUtteranceGroupingUsesSpeakerTurnsAndPreservesSourceMappings() throws {
        let transcript = MergedTranscript(
            sessionID: "session-1",
            title: "Grouping",
            completedAt: Date(timeIntervalSince1970: 1_725_876_700),
            tracks: [],
            segments: [
                segment("system-0", .system, 0, 1, "Prvá veta."),
                segment("microphone-0", .microphone, 0.5, 1.2, "Moja"),
                segment("system-1", .system, 1.05, 2, "Druhá veta."),
                segment("microphone-1", .microphone, 1.25, 2, "súvislá veta."),
            ]
        )
        let turns = SpeakerTurnArtifact(
            sessionID: transcript.sessionID,
            sourceFingerprint: "audio",
            engine: "test-turn-detector",
            model: "test-tdrz.bin",
            completedAt: transcript.completedAt,
            boundaries: [
                SpeakerTurnBoundary(source: .system, time: 1, confidence: nil),
            ]
        )

        let result = try UtteranceArtifactStore().makeArtifact(
            transcript: transcript,
            turnArtifact: turns
        )

        XCTAssertEqual(result.utterances.count, 3)
        XCTAssertEqual(result.utterances[0].sourceSegmentIDs, ["system-0"])
        XCTAssertEqual(result.utterances[1].sourceSegmentIDs, ["microphone-0", "microphone-1"])
        XCTAssertEqual(result.utterances[1].text, "Moja súvislá veta.")
        XCTAssertEqual(result.utterances[2].sourceSegmentIDs, ["system-1"])
        XCTAssertEqual(result.utterances[2].precedingBoundary, .speakerTurn)
        XCTAssertEqual(result.turnDetectionModel, "test-tdrz.bin")
    }

    func testSpeakerTurnMarkerMapsToOnlyOneNearestRawSegmentBoundary() throws {
        let transcript = MergedTranscript(
            sessionID: "session-one-to-one",
            title: "One-to-one turns",
            completedAt: Date(),
            tracks: [],
            segments: [
                segment("s0", .system, 0, 1.8, "Prvá"),
                segment("s1", .system, 1.9, 2.1, "druhá"),
                segment("s2", .system, 2.2, 3, "tretia"),
            ]
        )
        let turns = SpeakerTurnArtifact(
            sessionID: transcript.sessionID,
            sourceFingerprint: "audio",
            engine: "test-turn-detector",
            model: "test-tdrz.bin",
            completedAt: transcript.completedAt,
            boundaries: [
                SpeakerTurnBoundary(source: .system, time: 2, confidence: nil),
            ]
        )

        let result = try UtteranceArtifactStore().makeArtifact(
            transcript: transcript,
            turnArtifact: turns
        )

        XCTAssertEqual(result.utterances.count, 2)
        XCTAssertEqual(result.utterances[0].sourceSegmentIDs, ["s0"])
        XCTAssertEqual(result.utterances[1].sourceSegmentIDs, ["s1", "s2"])
        XCTAssertEqual(result.utterances[1].precedingBoundary, .speakerTurn)
    }

    func testSpeakerTurnMarkerInsideLongRawSegmentAwayFromEdgeIsIgnored() throws {
        let transcript = MergedTranscript(
            sessionID: "session-distant-turn",
            title: "Distant turn",
            completedAt: Date(),
            tracks: [],
            segments: [
                segment("s0", .system, 0, 10, "Dlhý segment"),
                segment("s1", .system, 10.1, 11, "pokračuje."),
            ]
        )
        let turns = SpeakerTurnArtifact(
            sessionID: transcript.sessionID,
            sourceFingerprint: "audio",
            engine: "test-turn-detector",
            model: "test-tdrz.bin",
            completedAt: transcript.completedAt,
            boundaries: [
                SpeakerTurnBoundary(source: .system, time: 5, confidence: nil),
            ]
        )

        let result = try UtteranceArtifactStore().makeArtifact(
            transcript: transcript,
            turnArtifact: turns
        )

        XCTAssertEqual(result.utterances.count, 1)
        XCTAssertEqual(result.utterances[0].sourceSegmentIDs, ["s0", "s1"])
    }

    func testContinuousUtteranceFallbackSplitsOnPauseOverlapAndMaximumDuration() throws {
        let configuration = ContinuousUtteranceConfiguration(
            maximumGapSeconds: 1.5,
            sentencePauseSeconds: 0.7,
            maximumDurationSeconds: 3,
            speakerTurnToleranceSeconds: 0.35
        )
        let transcript = MergedTranscript(
            sessionID: "session-2",
            title: "Fallback",
            completedAt: Date(),
            tracks: [],
            segments: [
                segment("s0", .system, 0, 1, "Prvá veta."),
                segment("s1", .system, 1.8, 2.4, "Druhá veta"),
                segment("s2", .system, 4.1, 5, "Po tichu"),
                segment("s3", .system, 4.9, 5.6, "Prekrytie"),
                segment("s4", .system, 7.5, 8.2, "Ďalší blok"),
                segment("s5", .system, 8.3, 11.5, "Príliš dlhý blok"),
            ]
        )

        let result = ContinuousUtteranceGrouper(configuration: configuration).group(
            transcript: transcript,
            sourceFingerprint: "raw"
        )

        XCTAssertEqual(
            result.utterances.map(\.precedingBoundary),
            [.trackStart, .sentencePause, .silenceGap, .overlap, .silenceGap, .maximumDuration]
        )
        XCTAssertTrue(result.utterances.allSatisfy { !$0.sourceSegmentIDs.isEmpty })
        XCTAssertNil(result.turnDetectionModel)
    }

    func testUtteranceArtifactFingerprintInvalidatesAfterRawTranscriptChange() throws {
        let store = UtteranceArtifactStore()
        let transcript = MergedTranscript(
            sessionID: "session-3",
            title: "Original",
            completedAt: Date(),
            tracks: [],
            segments: [segment("s0", .system, 0, 1, "Original")]
        )
        let artifact = try store.makeArtifact(transcript: transcript)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingScribeUtterance-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.persist(artifact, to: url)

        XCTAssertNotNil(try store.loadValidArtifact(
            from: url,
            transcript: transcript,
            turnArtifact: nil
        ))

        let changed = MergedTranscript(
            sessionID: transcript.sessionID,
            title: transcript.title,
            completedAt: transcript.completedAt,
            tracks: transcript.tracks,
            segments: [segment("s0", .system, 0, 1, "Changed")]
        )
        XCTAssertNil(try store.loadValidArtifact(
            from: url,
            transcript: changed,
            turnArtifact: nil
        ))
    }

    private func segment(
        _ id: String,
        _ source: TranscriptSource,
        _ start: Double,
        _ end: Double,
        _ text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            source: source,
            speaker: source == .system ? "Other" : "Martin",
            start: start,
            end: end,
            language: "sk",
            text: text,
            confidence: nil
        )
    }
}
