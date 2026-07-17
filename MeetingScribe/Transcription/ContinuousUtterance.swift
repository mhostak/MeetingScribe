import CryptoKit
import Foundation

enum UtteranceBoundaryReason: String, Codable, Equatable, Sendable {
    case trackStart
    case speakerTurn
    case speakerLabelChange
    case overlap
    case silenceGap
    case sentencePause
    case maximumDuration
}

struct SpeakerTurnBoundary: Codable, Equatable, Sendable {
    let source: TranscriptSource
    let time: Double
    let confidence: Double?
}

struct SpeakerTurnArtifact: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let sourceFingerprint: String
    let engine: String
    let model: String
    let completedAt: Date
    let boundaries: [SpeakerTurnBoundary]

    init(
        schemaVersion: Int = 1,
        sessionID: String,
        sourceFingerprint: String,
        engine: String,
        model: String,
        completedAt: Date,
        boundaries: [SpeakerTurnBoundary]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.sourceFingerprint = sourceFingerprint
        self.engine = engine
        self.model = model
        self.completedAt = completedAt
        self.boundaries = boundaries
    }
}

struct ContinuousUtteranceConfiguration: Codable, Equatable, Sendable {
    var maximumGapSeconds: Double = 1.5
    var sentencePauseSeconds: Double = 0.7
    var maximumDurationSeconds: Double = 45
    var speakerTurnToleranceSeconds: Double = 0.35

    static let current = ContinuousUtteranceConfiguration()
    static let sourceBlocks = ContinuousUtteranceConfiguration(
        maximumGapSeconds: 86_400,
        sentencePauseSeconds: 86_400,
        maximumDurationSeconds: 86_400,
        speakerTurnToleranceSeconds: 0.35
    )
}

struct ContinuousUtterance: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let source: TranscriptSource
    let speaker: String
    let sourceSegmentIDs: [String]
    let start: Double
    let end: Double
    let language: String
    let text: String
    let confidence: Double?
    let precedingBoundary: UtteranceBoundaryReason
}

struct ContinuousUtteranceTranscript: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let sourceFingerprint: String
    let completedAt: Date
    let configuration: ContinuousUtteranceConfiguration
    let turnDetectionEngine: String?
    let turnDetectionModel: String?
    let utterances: [ContinuousUtterance]

    init(
        schemaVersion: Int = 1,
        sessionID: String,
        sourceFingerprint: String,
        completedAt: Date,
        configuration: ContinuousUtteranceConfiguration,
        turnDetectionEngine: String?,
        turnDetectionModel: String?,
        utterances: [ContinuousUtterance]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.sourceFingerprint = sourceFingerprint
        self.completedAt = completedAt
        self.configuration = configuration
        self.turnDetectionEngine = turnDetectionEngine
        self.turnDetectionModel = turnDetectionModel
        self.utterances = utterances
    }
}

protocol SpeakerTurnDetecting: Sendable {
    func detectSpeakerTurns(
        audioURL: URL,
        modelURL: URL,
        timelineOffsetSeconds: Double
    ) async throws -> [SpeakerTurnBoundary]
}

struct ContinuousUtteranceGrouper: Sendable {
    let configuration: ContinuousUtteranceConfiguration

    init(configuration: ContinuousUtteranceConfiguration = .current) {
        self.configuration = configuration
    }

    func group(
        transcript: MergedTranscript,
        sourceFingerprint: String,
        turnArtifact: SpeakerTurnArtifact? = nil
    ) -> ContinuousUtteranceTranscript {
        let boundaries = turnArtifact?.boundaries ?? []
        var drafts: [Draft] = []

        for source in TranscriptSource.allCases {
            let segments = transcript.segments
                .filter { $0.source == source }
                .sorted(by: segmentComesBefore)
            drafts.append(contentsOf: groupTrack(segments, boundaries: boundaries))
        }

        drafts.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.source != $1.source { return $0.source == .system }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.sourceSegmentIDs.lexicographicallyPrecedes($1.sourceSegmentIDs)
        }
        let utterances = drafts.enumerated().map { index, draft in
            ContinuousUtterance(
                id: String(format: "utterance-%06d", index),
                source: draft.source,
                speaker: draft.speaker,
                sourceSegmentIDs: draft.sourceSegmentIDs,
                start: draft.start,
                end: draft.end,
                language: draft.language,
                text: draft.text,
                confidence: draft.confidence,
                precedingBoundary: draft.precedingBoundary
            )
        }

        return ContinuousUtteranceTranscript(
            sessionID: transcript.sessionID,
            sourceFingerprint: sourceFingerprint,
            completedAt: transcript.completedAt,
            configuration: configuration,
            turnDetectionEngine: turnArtifact?.engine,
            turnDetectionModel: turnArtifact?.model,
            utterances: utterances
        )
    }

    private func groupTrack(
        _ segments: [TranscriptSegment],
        boundaries: [SpeakerTurnBoundary]
    ) -> [Draft] {
        guard let first = segments.first else { return [] }

        let speakerTurnIndices = speakerTurnBoundaryIndices(
            in: segments,
            boundaries: boundaries
        )
        var result: [Draft] = []
        var group = [first]
        var precedingBoundary = UtteranceBoundaryReason.trackStart

        for index in segments.indices.dropFirst() {
            let next = segments[index]
            let previous = group[group.count - 1]
            if let boundary = boundaryReason(
                groupStart: group[0].start,
                previous: previous,
                next: next,
                hasSpeakerTurn: speakerTurnIndices.contains(index)
            ) {
                result.append(makeDraft(from: group, precedingBoundary: precedingBoundary))
                group = [next]
                precedingBoundary = boundary
            } else {
                group.append(next)
            }
        }
        result.append(makeDraft(from: group, precedingBoundary: precedingBoundary))
        return result
    }

    private func boundaryReason(
        groupStart: Double,
        previous: TranscriptSegment,
        next: TranscriptSegment,
        hasSpeakerTurn: Bool
    ) -> UtteranceBoundaryReason? {
        if hasSpeakerTurn {
            return .speakerTurn
        }
        if previous.speaker != next.speaker {
            return .speakerLabelChange
        }
        if next.start < previous.end - 0.001 {
            return .overlap
        }

        let gap = max(0, next.start - previous.end)
        if gap > configuration.maximumGapSeconds {
            return .silenceGap
        }
        if next.end - groupStart > configuration.maximumDurationSeconds {
            return .maximumDuration
        }
        if gap >= configuration.sentencePauseSeconds,
           hasTerminalPunctuation(previous.text) {
            return .sentencePause
        }
        return nil
    }

    private func speakerTurnBoundaryIndices(
        in segments: [TranscriptSegment],
        boundaries: [SpeakerTurnBoundary]
    ) -> Set<Int> {
        guard segments.count > 1, let source = segments.first?.source else { return [] }

        let tolerance = configuration.speakerTurnToleranceSeconds
        var matchedIndices = Set<Int>()
        for boundary in boundaries where boundary.source == source {
            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for index in segments.indices.dropFirst() {
                let previous = segments[index - 1]
                let next = segments[index]
                let distance = min(
                    abs(boundary.time - previous.end),
                    abs(boundary.time - next.start)
                )
                guard distance <= tolerance else { continue }
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            if let bestIndex {
                matchedIndices.insert(bestIndex)
            }
        }
        return matchedIndices
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let character = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .last else { return false }
        return ".!?…".contains(character)
    }

    private func makeDraft(
        from segments: [TranscriptSegment],
        precedingBoundary: UtteranceBoundaryReason
    ) -> Draft {
        let languages = Set(segments.map(\.language).filter { !$0.isEmpty })
        let language = languages.count == 1 ? languages.first! : "mixed"
        let confidenceValues = segments.compactMap(\.confidence)
        let confidence = confidenceValues.isEmpty
            ? nil
            : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        return Draft(
            source: segments[0].source,
            speaker: segments[0].speaker,
            sourceSegmentIDs: segments.map(\.id),
            start: segments.map(\.start).min() ?? segments[0].start,
            end: segments.map(\.end).max() ?? segments[0].end,
            language: language,
            text: segments.map(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            confidence: confidence,
            precedingBoundary: precedingBoundary
        )
    }

    private func segmentComesBefore(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id < rhs.id
    }

    private struct Draft {
        let source: TranscriptSource
        let speaker: String
        let sourceSegmentIDs: [String]
        let start: Double
        let end: Double
        let language: String
        let text: String
        let confidence: Double?
        let precedingBoundary: UtteranceBoundaryReason
    }
}

extension TranscriptSource {
    var conversationParticipantLabel: String {
        switch self {
        case .system: return "Remote participants"
        case .microphone: return "On-site participants"
        }
    }
}

/// Groups the transcript by alternating audio source instead of attempting to
/// infer individual people. A block ends only when the other source begins;
/// silence and raw ASR segment boundaries do not fragment one source.
struct SourceConversationBlockGrouper: Sendable {
    let configuration: ContinuousUtteranceConfiguration

    init(configuration: ContinuousUtteranceConfiguration = .sourceBlocks) {
        self.configuration = configuration
    }

    func group(
        transcript: MergedTranscript,
        sourceFingerprint: String
    ) -> ContinuousUtteranceTranscript {
        let segments = transcript.segments.sorted(by: segmentComesBefore)
        var drafts: [Draft] = []
        var group: [TranscriptSegment] = []
        var precedingBoundary = UtteranceBoundaryReason.trackStart

        for segment in segments {
            guard let previous = group.last else {
                group = [segment]
                continue
            }
            let boundary: UtteranceBoundaryReason? = segment.source != previous.source
                ? .speakerLabelChange
                : nil

            if let boundary {
                drafts.append(makeDraft(from: group, precedingBoundary: precedingBoundary))
                group = [segment]
                precedingBoundary = boundary
            } else {
                group.append(segment)
            }
        }
        if !group.isEmpty {
            drafts.append(makeDraft(from: group, precedingBoundary: precedingBoundary))
        }

        return ContinuousUtteranceTranscript(
            sessionID: transcript.sessionID,
            sourceFingerprint: sourceFingerprint,
            completedAt: transcript.completedAt,
            configuration: configuration,
            turnDetectionEngine: nil,
            turnDetectionModel: nil,
            utterances: drafts.enumerated().map { index, draft in
                ContinuousUtterance(
                    id: String(format: "source-block-%06d", index),
                    source: draft.source,
                    speaker: draft.source.conversationParticipantLabel,
                    sourceSegmentIDs: draft.sourceSegmentIDs,
                    start: draft.start,
                    end: draft.end,
                    language: draft.language,
                    text: draft.text,
                    confidence: draft.confidence,
                    precedingBoundary: draft.precedingBoundary
                )
            }
        )
    }

    private func makeDraft(
        from segments: [TranscriptSegment],
        precedingBoundary: UtteranceBoundaryReason
    ) -> Draft {
        let languages = Set(segments.map(\.language).filter { !$0.isEmpty })
        let confidenceValues = segments.compactMap(\.confidence)
        return Draft(
            source: segments[0].source,
            sourceSegmentIDs: segments.map(\.id),
            start: segments.map(\.start).min() ?? segments[0].start,
            end: segments.map(\.end).max() ?? segments[0].end,
            language: languages.count == 1 ? languages.first! : "mixed",
            text: segments.map(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            confidence: confidenceValues.isEmpty
                ? nil
                : confidenceValues.reduce(0, +) / Double(confidenceValues.count),
            precedingBoundary: precedingBoundary
        )
    }

    private func segmentComesBefore(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.source != rhs.source { return lhs.source == .system }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id < rhs.id
    }

    private struct Draft {
        let source: TranscriptSource
        let sourceSegmentIDs: [String]
        let start: Double
        let end: Double
        let language: String
        let text: String
        let confidence: Double?
        let precedingBoundary: UtteranceBoundaryReason
    }
}

extension ContinuousUtteranceTranscript {
    func asMergedTranscript(basedOn transcript: MergedTranscript) -> MergedTranscript {
        MergedTranscript(
            schemaVersion: transcript.schemaVersion,
            sessionID: transcript.sessionID,
            title: transcript.title,
            completedAt: transcript.completedAt,
            tracks: transcript.tracks,
            segments: utterances.map { utterance in
                TranscriptSegment(
                    id: utterance.id,
                    source: utterance.source,
                    speaker: utterance.speaker,
                    start: utterance.start,
                    end: utterance.end,
                    language: utterance.language,
                    text: utterance.text,
                    confidence: utterance.confidence
                )
            }
        )
    }
}

struct UtteranceArtifactStore: Sendable {
    let configuration: ContinuousUtteranceConfiguration

    init(configuration: ContinuousUtteranceConfiguration = .sourceBlocks) {
        self.configuration = configuration
    }

    func makeArtifact(
        transcript: MergedTranscript,
        turnArtifact: SpeakerTurnArtifact? = nil
    ) throws -> ContinuousUtteranceTranscript {
        let fingerprint = try sourceFingerprint(
            transcript: transcript,
            turnArtifact: turnArtifact
        )
        return SourceConversationBlockGrouper(configuration: configuration).group(
            transcript: transcript,
            sourceFingerprint: fingerprint
        )
    }

    func persist(_ artifact: ContinuousUtteranceTranscript, to url: URL) throws {
        let data = try TranscriptJSONCoder.makeEncoder().encode(artifact)
        try data.write(to: url, options: .atomic)
    }

    func persist(_ artifact: SpeakerTurnArtifact, to url: URL) throws {
        let data = try TranscriptJSONCoder.makeEncoder().encode(artifact)
        try data.write(to: url, options: .atomic)
    }

    func loadValidArtifact(
        from url: URL,
        transcript: MergedTranscript,
        turnArtifact: SpeakerTurnArtifact?
    ) throws -> ContinuousUtteranceTranscript? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let artifact = try TranscriptJSONCoder.makeDecoder().decode(
            ContinuousUtteranceTranscript.self,
            from: data
        )
        guard artifact.sessionID == transcript.sessionID,
              artifact.configuration == configuration,
              artifact.sourceFingerprint == (try sourceFingerprint(
                  transcript: transcript,
                  turnArtifact: turnArtifact
              )) else {
            return nil
        }
        return artifact
    }

    func loadTurnArtifact(from url: URL, sessionID: String) throws -> SpeakerTurnArtifact? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let artifact = try TranscriptJSONCoder.makeDecoder().decode(
            SpeakerTurnArtifact.self,
            from: data
        )
        return artifact.sessionID == sessionID ? artifact : nil
    }

    func sourceFingerprint(
        transcript: MergedTranscript,
        turnArtifact: SpeakerTurnArtifact?
    ) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try TranscriptJSONCoder.makeEncoder().encode(transcript))
        if let turnArtifact {
            hasher.update(data: try TranscriptJSONCoder.makeEncoder().encode(turnArtifact))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func audioFingerprint(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
