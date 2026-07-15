import XCTest
@testable import MeetingScribe

final class SpeakerDiarizationTests: XCTestCase {
    func testNormalizerSortsSegmentsAndAssignsDeterministicIDs() throws {
        let result = try SpeakerDiarizationNormalizer().normalize(
            engine: " FluidAudio ",
            engineVersion: " 0.15.5 ",
            model: " community-1 ",
            audioDurationSeconds: 5,
            segments: [
                RawSpeakerDiarizationSegment(
                    speakerID: " S2 ",
                    start: 2,
                    end: 3,
                    confidence: 0.8
                ),
                RawSpeakerDiarizationSegment(
                    speakerID: "S1",
                    start: 0,
                    end: 1,
                    confidence: nil
                ),
            ]
        )

        XCTAssertEqual(result.engine, "FluidAudio")
        XCTAssertEqual(result.engineVersion, "0.15.5")
        XCTAssertEqual(result.model, "community-1")
        XCTAssertEqual(result.speakerIDs, ["S1", "S2"])
        XCTAssertEqual(result.segments.map(\.id), ["diarization-000000", "diarization-000001"])
        XCTAssertEqual(result.segments.map(\.speakerID), ["S1", "S2"])
    }

    func testNormalizerRejectsInvalidTimesAndConfidence() {
        XCTAssertThrowsError(
            try SpeakerDiarizationNormalizer().normalize(
                engine: "engine",
                engineVersion: "1",
                model: "model",
                audioDurationSeconds: 3,
                segments: [
                    RawSpeakerDiarizationSegment(
                        speakerID: "S1",
                        start: 2,
                        end: 1,
                        confidence: nil
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeakerDiarizationValidationError,
                .invalidSegmentTime(index: 0, start: 2, end: 1)
            )
        }

        XCTAssertThrowsError(
            try SpeakerDiarizationNormalizer().normalize(
                engine: "engine",
                engineVersion: "1",
                model: "model",
                audioDurationSeconds: 3,
                segments: [
                    RawSpeakerDiarizationSegment(
                        speakerID: "S1",
                        start: 0,
                        end: 1,
                        confidence: 1.1
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeakerDiarizationValidationError,
                .invalidConfidence(index: 0, confidence: 1.1)
            )
        }
    }

    func testQualityEvaluatorFindsOptimalSpeakerPermutation() throws {
        let hypothesis = try makeResult(
            duration: 2,
            segments: [
                RawSpeakerDiarizationSegment(speakerID: "X", start: 0, end: 1),
                RawSpeakerDiarizationSegment(speakerID: "Y", start: 1, end: 2),
            ]
        )
        let reference = DiarizationReference(segments: [
            DiarizationReferenceSegment(speakerID: "A", start: 0, end: 1),
            DiarizationReferenceSegment(speakerID: "B", start: 1, end: 2),
        ])

        let report = try evaluator.evaluate(hypothesis: hypothesis, reference: reference)

        XCTAssertEqual(report.hypothesisToReferenceSpeaker, ["X": "A", "Y": "B"])
        XCTAssertEqual(report.diarizationErrorRate, 0, accuracy: 0.000_001)
        XCTAssertEqual(report.referenceSpeakerSeconds, 2, accuracy: 0.000_001)
    }

    func testQualityEvaluatorMeasuresMissedSpeech() throws {
        let hypothesis = try makeResult(
            duration: 2,
            segments: [RawSpeakerDiarizationSegment(speakerID: "X", start: 0, end: 1)]
        )
        let reference = DiarizationReference(segments: [
            DiarizationReferenceSegment(speakerID: "A", start: 0, end: 2)
        ])

        let report = try evaluator.evaluate(hypothesis: hypothesis, reference: reference)

        XCTAssertEqual(report.missedSpeakerSeconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(report.falseAlarmSeconds, 0, accuracy: 0.000_001)
        XCTAssertEqual(report.confusedSpeakerSeconds, 0, accuracy: 0.000_001)
        XCTAssertEqual(report.diarizationErrorRate, 0.5, accuracy: 0.000_001)
    }

    func testQualityEvaluatorCanIgnoreOverlappingReferenceSpeech() throws {
        let hypothesis = try makeResult(
            duration: 2,
            segments: [RawSpeakerDiarizationSegment(speakerID: "X", start: 0, end: 2)]
        )
        let reference = DiarizationReference(segments: [
            DiarizationReferenceSegment(speakerID: "A", start: 0, end: 2),
            DiarizationReferenceSegment(speakerID: "B", start: 0.5, end: 1.5),
        ])

        let report = try evaluator.evaluate(hypothesis: hypothesis, reference: reference)

        XCTAssertEqual(report.referenceSpeakerSeconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(report.evaluatedSeconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(report.diarizationErrorRate, 0, accuracy: 0.000_001)
    }

    private var evaluator: DiarizationQualityEvaluator {
        DiarizationQualityEvaluator(configuration: DiarizationQualityConfiguration(
            frameDurationSeconds: 0.1,
            collarSeconds: 0,
            ignoreOverlappingReferenceSpeech: true
        ))
    }

    private func makeResult(
        duration: Double,
        segments: [RawSpeakerDiarizationSegment]
    ) throws -> SpeakerDiarizationResult {
        try SpeakerDiarizationNormalizer().normalize(
            engine: "test",
            engineVersion: "1",
            model: "fixture",
            audioDurationSeconds: duration,
            segments: segments
        )
    }
}
