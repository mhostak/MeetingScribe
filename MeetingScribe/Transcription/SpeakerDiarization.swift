import Foundation

public struct SpeakerDiarizationOptions: Codable, Equatable, Sendable {
    public var minimumSpeakers: Int?
    public var maximumSpeakers: Int?
    public var exactSpeakerCount: Int?

    public init(
        minimumSpeakers: Int? = nil,
        maximumSpeakers: Int? = nil,
        exactSpeakerCount: Int? = nil
    ) {
        self.minimumSpeakers = minimumSpeakers
        self.maximumSpeakers = maximumSpeakers
        self.exactSpeakerCount = exactSpeakerCount
    }
}

public struct RawSpeakerDiarizationSegment: Codable, Equatable, Sendable {
    public let speakerID: String
    public let start: Double
    public let end: Double
    public let confidence: Double?

    public init(
        speakerID: String,
        start: Double,
        end: Double,
        confidence: Double? = nil
    ) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct SpeakerDiarizationSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let speakerID: String
    public let start: Double
    public let end: Double
    public let confidence: Double?

    public init(
        id: String,
        speakerID: String,
        start: Double,
        end: Double,
        confidence: Double? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct SpeakerDiarizationResult: Codable, Equatable, Sendable {
    public let engine: String
    public let engineVersion: String
    public let model: String
    public let audioDurationSeconds: Double
    public let segments: [SpeakerDiarizationSegment]

    public init(
        engine: String,
        engineVersion: String,
        model: String,
        audioDurationSeconds: Double,
        segments: [SpeakerDiarizationSegment]
    ) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.model = model
        self.audioDurationSeconds = audioDurationSeconds
        self.segments = segments
    }

    public var speakerIDs: [String] {
        Array(Set(segments.map(\.speakerID))).sorted()
    }
}

struct SpeakerDiarizationRequest: Sendable {
    let audioURL: URL
    let modelBundleURL: URL
    let options: SpeakerDiarizationOptions
}

protocol SpeakerDiarizing: Sendable {
    func diarize(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationResult
    func releaseResources() async
}

extension SpeakerDiarizing {
    func releaseResources() async {}
}

public enum SpeakerDiarizationValidationError: Error, Equatable, LocalizedError {
    case invalidAudioDuration(Double)
    case emptyEngine
    case emptyEngineVersion
    case emptyModel
    case emptySpeakerID(index: Int)
    case invalidSegmentTime(index: Int, start: Double, end: Double)
    case segmentExceedsAudio(index: Int, end: Double, audioDuration: Double)
    case invalidConfidence(index: Int, confidence: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidAudioDuration(let duration):
            return "Invalid audio duration: \(duration)"
        case .emptyEngine:
            return "The diarization engine name is empty."
        case .emptyEngineVersion:
            return "The diarization engine version is empty."
        case .emptyModel:
            return "The diarization model name is empty."
        case .emptySpeakerID(let index):
            return "Diarization segment \(index) has an empty speaker ID."
        case .invalidSegmentTime(let index, let start, let end):
            return "Diarization segment \(index) has invalid time \(start)...\(end)."
        case .segmentExceedsAudio(let index, let end, let duration):
            return "Diarization segment \(index) ends at \(end), after audio duration \(duration)."
        case .invalidConfidence(let index, let confidence):
            return "Diarization segment \(index) has invalid confidence \(confidence)."
        }
    }
}

public struct SpeakerDiarizationNormalizer: Sendable {
    public var endToleranceSeconds: Double

    public init(endToleranceSeconds: Double = 0.05) {
        self.endToleranceSeconds = endToleranceSeconds
    }

    public func normalize(
        engine: String,
        engineVersion: String,
        model: String,
        audioDurationSeconds: Double,
        segments: [RawSpeakerDiarizationSegment]
    ) throws -> SpeakerDiarizationResult {
        guard audioDurationSeconds.isFinite, audioDurationSeconds > 0 else {
            throw SpeakerDiarizationValidationError.invalidAudioDuration(audioDurationSeconds)
        }

        let normalizedEngine = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEngine.isEmpty else {
            throw SpeakerDiarizationValidationError.emptyEngine
        }
        let normalizedVersion = engineVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVersion.isEmpty else {
            throw SpeakerDiarizationValidationError.emptyEngineVersion
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw SpeakerDiarizationValidationError.emptyModel
        }

        let validated = try segments.enumerated().map { index, segment in
            let speakerID = segment.speakerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speakerID.isEmpty else {
                throw SpeakerDiarizationValidationError.emptySpeakerID(index: index)
            }
            guard segment.start.isFinite,
                  segment.end.isFinite,
                  segment.start >= 0,
                  segment.end > segment.start else {
                throw SpeakerDiarizationValidationError.invalidSegmentTime(
                    index: index,
                    start: segment.start,
                    end: segment.end
                )
            }
            guard segment.end <= audioDurationSeconds + endToleranceSeconds else {
                throw SpeakerDiarizationValidationError.segmentExceedsAudio(
                    index: index,
                    end: segment.end,
                    audioDuration: audioDurationSeconds
                )
            }
            if let confidence = segment.confidence,
               (!confidence.isFinite || confidence < 0 || confidence > 1) {
                throw SpeakerDiarizationValidationError.invalidConfidence(
                    index: index,
                    confidence: confidence
                )
            }

            return RawSpeakerDiarizationSegment(
                speakerID: speakerID,
                start: segment.start,
                end: min(segment.end, audioDurationSeconds),
                confidence: segment.confidence
            )
        }

        let ordered = validated.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.speakerID < $1.speakerID
        }
        let normalizedSegments = ordered.enumerated().map { index, segment in
            SpeakerDiarizationSegment(
                id: String(format: "diarization-%06d", index),
                speakerID: segment.speakerID,
                start: segment.start,
                end: segment.end,
                confidence: segment.confidence
            )
        }

        return SpeakerDiarizationResult(
            engine: normalizedEngine,
            engineVersion: normalizedVersion,
            model: normalizedModel,
            audioDurationSeconds: audioDurationSeconds,
            segments: normalizedSegments
        )
    }
}

public struct DiarizationReferenceSegment: Codable, Equatable, Sendable {
    public let speakerID: String
    public let start: Double
    public let end: Double

    public init(speakerID: String, start: Double, end: Double) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public struct DiarizationReference: Codable, Equatable, Sendable {
    public let segments: [DiarizationReferenceSegment]

    public init(segments: [DiarizationReferenceSegment]) {
        self.segments = segments
    }
}

public struct DiarizationQualityConfiguration: Codable, Equatable, Sendable {
    public var frameDurationSeconds: Double
    public var collarSeconds: Double
    public var ignoreOverlappingReferenceSpeech: Bool

    public init(
        frameDurationSeconds: Double = 0.01,
        collarSeconds: Double = 0.25,
        ignoreOverlappingReferenceSpeech: Bool = true
    ) {
        self.frameDurationSeconds = frameDurationSeconds
        self.collarSeconds = collarSeconds
        self.ignoreOverlappingReferenceSpeech = ignoreOverlappingReferenceSpeech
    }

    public static let spikeDefault = DiarizationQualityConfiguration()
}

public struct DiarizationQualityReport: Codable, Equatable, Sendable {
    public let referenceSpeakerSeconds: Double
    public let evaluatedSeconds: Double
    public let missedSpeakerSeconds: Double
    public let falseAlarmSeconds: Double
    public let confusedSpeakerSeconds: Double
    public let diarizationErrorRate: Double
    public let hypothesisToReferenceSpeaker: [String: String]

    public init(
        referenceSpeakerSeconds: Double,
        evaluatedSeconds: Double,
        missedSpeakerSeconds: Double,
        falseAlarmSeconds: Double,
        confusedSpeakerSeconds: Double,
        diarizationErrorRate: Double,
        hypothesisToReferenceSpeaker: [String: String]
    ) {
        self.referenceSpeakerSeconds = referenceSpeakerSeconds
        self.evaluatedSeconds = evaluatedSeconds
        self.missedSpeakerSeconds = missedSpeakerSeconds
        self.falseAlarmSeconds = falseAlarmSeconds
        self.confusedSpeakerSeconds = confusedSpeakerSeconds
        self.diarizationErrorRate = diarizationErrorRate
        self.hypothesisToReferenceSpeaker = hypothesisToReferenceSpeaker
    }
}

public enum DiarizationQualityError: Error, Equatable, LocalizedError {
    case invalidFrameDuration(Double)
    case invalidCollar(Double)
    case invalidReferenceSegment(index: Int)
    case noScorableReferenceSpeech

    public var errorDescription: String? {
        switch self {
        case .invalidFrameDuration(let value):
            return "Invalid diarization scoring frame duration: \(value)"
        case .invalidCollar(let value):
            return "Invalid diarization scoring collar: \(value)"
        case .invalidReferenceSegment(let index):
            return "Reference diarization segment \(index) is invalid."
        case .noScorableReferenceSpeech:
            return "The diarization reference contains no scorable speech."
        }
    }
}

public struct DiarizationQualityEvaluator: Sendable {
    public let configuration: DiarizationQualityConfiguration

    public init(configuration: DiarizationQualityConfiguration = .spikeDefault) {
        self.configuration = configuration
    }

    public func evaluate(
        hypothesis: SpeakerDiarizationResult,
        reference: DiarizationReference
    ) throws -> DiarizationQualityReport {
        guard configuration.frameDurationSeconds.isFinite,
              configuration.frameDurationSeconds > 0 else {
            throw DiarizationQualityError.invalidFrameDuration(
                configuration.frameDurationSeconds
            )
        }
        guard configuration.collarSeconds.isFinite,
              configuration.collarSeconds >= 0 else {
            throw DiarizationQualityError.invalidCollar(configuration.collarSeconds)
        }
        for (index, segment) in reference.segments.enumerated() {
            guard !segment.speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.start.isFinite,
                  segment.end.isFinite,
                  segment.start >= 0,
                  segment.end > segment.start else {
                throw DiarizationQualityError.invalidReferenceSegment(index: index)
            }
        }

        let maximumEnd = max(
            hypothesis.audioDurationSeconds,
            reference.segments.map(\.end).max() ?? 0
        )
        let frameCount = Int(ceil(maximumEnd / configuration.frameDurationSeconds))
        let frames = (0..<frameCount).compactMap { index -> ScoringFrame? in
            let time = (Double(index) + 0.5) * configuration.frameDurationSeconds
            if isWithinReferenceCollar(time, segments: reference.segments) { return nil }

            let referenceSpeakers = Set(reference.segments.compactMap { segment in
                (segment.start <= time && time < segment.end) ? segment.speakerID : nil
            })
            if configuration.ignoreOverlappingReferenceSpeech,
               referenceSpeakers.count > 1 {
                return nil
            }
            let hypothesisSpeakers = Set(hypothesis.segments.compactMap { segment in
                (segment.start <= time && time < segment.end) ? segment.speakerID : nil
            })
            return ScoringFrame(
                referenceSpeakers: referenceSpeakers,
                hypothesisSpeakers: hypothesisSpeakers
            )
        }

        var overlapWeights: [String: [String: Double]] = [:]
        for frame in frames {
            for hypothesisSpeaker in frame.hypothesisSpeakers {
                for referenceSpeaker in frame.referenceSpeakers {
                    overlapWeights[hypothesisSpeaker, default: [:]][referenceSpeaker, default: 0]
                        += configuration.frameDurationSeconds
                }
            }
        }
        let mapping = optimalSpeakerMapping(
            hypothesisSpeakers: hypothesis.speakerIDs,
            referenceSpeakers: Array(Set(reference.segments.map(\.speakerID))).sorted(),
            weights: overlapWeights
        )

        var referenceSpeakerSeconds = 0.0
        var evaluatedSeconds = 0.0
        var missed = 0.0
        var falseAlarm = 0.0
        var confused = 0.0
        let frameDuration = configuration.frameDurationSeconds

        for frame in frames {
            evaluatedSeconds += frameDuration
            let referenceCount = frame.referenceSpeakers.count
            let hypothesisCount = frame.hypothesisSpeakers.count
            referenceSpeakerSeconds += Double(referenceCount) * frameDuration

            let mappedHypothesis = Set(frame.hypothesisSpeakers.compactMap { mapping[$0] })
            let correct = mappedHypothesis.intersection(frame.referenceSpeakers).count
            missed += Double(max(0, referenceCount - hypothesisCount)) * frameDuration
            falseAlarm += Double(max(0, hypothesisCount - referenceCount)) * frameDuration
            confused += Double(max(0, min(referenceCount, hypothesisCount) - correct))
                * frameDuration
        }

        guard referenceSpeakerSeconds > 0 else {
            throw DiarizationQualityError.noScorableReferenceSpeech
        }
        let errorRate = (missed + falseAlarm + confused) / referenceSpeakerSeconds
        return DiarizationQualityReport(
            referenceSpeakerSeconds: referenceSpeakerSeconds,
            evaluatedSeconds: evaluatedSeconds,
            missedSpeakerSeconds: missed,
            falseAlarmSeconds: falseAlarm,
            confusedSpeakerSeconds: confused,
            diarizationErrorRate: errorRate,
            hypothesisToReferenceSpeaker: mapping
        )
    }

    private func isWithinReferenceCollar(
        _ time: Double,
        segments: [DiarizationReferenceSegment]
    ) -> Bool {
        guard configuration.collarSeconds > 0 else { return false }
        return segments.lazy.flatMap { [$0.start, $0.end] }.contains { boundary in
            abs(time - boundary) < configuration.collarSeconds
        }
    }

    private func optimalSpeakerMapping(
        hypothesisSpeakers: [String],
        referenceSpeakers: [String],
        weights: [String: [String: Double]]
    ) -> [String: String] {
        guard !hypothesisSpeakers.isEmpty, !referenceSpeakers.isEmpty else { return [:] }
        if referenceSpeakers.count > 20 {
            return greedySpeakerMapping(
                hypothesisSpeakers: hypothesisSpeakers,
                referenceSpeakers: referenceSpeakers,
                weights: weights
            )
        }

        struct State: Hashable {
            let hypothesisIndex: Int
            let usedReferenceMask: UInt64
        }
        var memo: [State: Double] = [:]

        func bestScore(_ hypothesisIndex: Int, _ usedMask: UInt64) -> Double {
            guard hypothesisIndex < hypothesisSpeakers.count else { return 0 }
            let state = State(hypothesisIndex: hypothesisIndex, usedReferenceMask: usedMask)
            if let cached = memo[state] { return cached }

            var best = bestScore(hypothesisIndex + 1, usedMask)
            let hypothesisSpeaker = hypothesisSpeakers[hypothesisIndex]
            for referenceIndex in referenceSpeakers.indices {
                let bit = UInt64(1) << UInt64(referenceIndex)
                guard usedMask & bit == 0 else { continue }
                let weight = weights[hypothesisSpeaker]?[referenceSpeakers[referenceIndex]] ?? 0
                best = max(best, weight + bestScore(hypothesisIndex + 1, usedMask | bit))
            }
            memo[state] = best
            return best
        }

        var mapping: [String: String] = [:]
        var mask: UInt64 = 0
        for hypothesisIndex in hypothesisSpeakers.indices {
            let skipScore = bestScore(hypothesisIndex + 1, mask)
            var selectedReference: Int?
            var selectedScore = skipScore
            let hypothesisSpeaker = hypothesisSpeakers[hypothesisIndex]
            for referenceIndex in referenceSpeakers.indices {
                let bit = UInt64(1) << UInt64(referenceIndex)
                guard mask & bit == 0 else { continue }
                let weight = weights[hypothesisSpeaker]?[referenceSpeakers[referenceIndex]] ?? 0
                let candidate = weight + bestScore(hypothesisIndex + 1, mask | bit)
                if candidate > selectedScore + 1e-12 {
                    selectedScore = candidate
                    selectedReference = referenceIndex
                }
            }
            if let referenceIndex = selectedReference {
                mapping[hypothesisSpeaker] = referenceSpeakers[referenceIndex]
                mask |= UInt64(1) << UInt64(referenceIndex)
            }
        }
        return mapping
    }

    private func greedySpeakerMapping(
        hypothesisSpeakers: [String],
        referenceSpeakers: [String],
        weights: [String: [String: Double]]
    ) -> [String: String] {
        var candidates: [(Double, String, String)] = []
        for hypothesis in hypothesisSpeakers {
            for reference in referenceSpeakers {
                candidates.append((weights[hypothesis]?[reference] ?? 0, hypothesis, reference))
            }
        }
        candidates.sort {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }

        var mapping: [String: String] = [:]
        var usedReferences = Set<String>()
        for (weight, hypothesis, reference) in candidates where weight > 0 {
            guard mapping[hypothesis] == nil, !usedReferences.contains(reference) else { continue }
            mapping[hypothesis] = reference
            usedReferences.insert(reference)
        }
        return mapping
    }

    private struct ScoringFrame {
        let referenceSpeakers: Set<String>
        let hypothesisSpeakers: Set<String>
    }
}
