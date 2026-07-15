import Foundation

struct SpeakerTranscriptResolverConfiguration: Codable, Equatable, Sendable {
    static let current = SpeakerTranscriptResolverConfiguration(
        revision: "speaker-resolution-v1",
        ambiguityToleranceSeconds: 0.05,
        continuousSpeechGapSeconds: 1.5
    )

    let revision: String
    let ambiguityToleranceSeconds: Double
    let continuousSpeechGapSeconds: Double
}

struct SpeakerTranscriptResolver: Sendable {
    let configuration: SpeakerTranscriptResolverConfiguration
    private let artifactStore: SpeakerArtifactStore
    private let now: @Sendable () -> Date

    init(
        configuration: SpeakerTranscriptResolverConfiguration = .current,
        artifactStore: SpeakerArtifactStore = SpeakerArtifactStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.artifactStore = artifactStore
        self.now = now
    }

    func resolve(
        transcript: MergedTranscript,
        artifact: SpeakerDiarizationArtifact
    ) throws -> ResolvedTranscript {
        guard transcript.sessionID == artifact.sessionID else {
            throw SpeakerArtifactError.wrongSession
        }
        guard artifact.sourceTranscriptFingerprint == (try artifactStore.fingerprint(
            transcript: transcript
        )) else {
            throw SpeakerArtifactError.staleTranscript
        }

        let drafts = transcript.segments.flatMap { segment -> [Draft] in
            if segment.source == .microphone {
                return [draft(
                    segment: segment,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    assignment: assignment(for: SpeakerProfile.localID, artifact: artifact)
                )]
            }
            guard let words = segment.words, !words.isEmpty else {
                return [draft(
                    segment: segment,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    assignment: systemAssignment(
                        start: segment.start,
                        end: segment.end,
                        artifact: artifact
                    )
                )]
            }
            return wordDrafts(words, segment: segment, artifact: artifact)
        }
        let merged = mergeContinuousDrafts(drafts.sorted(by: draftComesBefore))
        return ResolvedTranscript(
            schemaVersion: 1,
            sessionID: transcript.sessionID,
            createdAt: now(),
            sourceTranscriptFingerprint: try artifactStore.fingerprint(transcript: transcript),
            diarizationFingerprint: try artifactStore.fingerprint(artifact: artifact),
            segments: merged.enumerated().map { index, value in
                ResolvedTranscriptSegment(
                    id: String(format: "resolved-%06d", index),
                    source: value.source,
                    speakerID: value.speakerID,
                    speaker: value.speaker,
                    start: value.start,
                    end: value.end,
                    language: value.language,
                    text: value.text,
                    confidence: value.confidence,
                    sourceSegmentIDs: value.sourceSegmentIDs,
                    ambiguity: value.ambiguity
                )
            }
        )
    }

    private func wordDrafts(
        _ words: [TranscriptWord],
        segment: TranscriptSegment,
        artifact: SpeakerDiarizationArtifact
    ) -> [Draft] {
        var groups: [Draft] = []
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let assignment = systemAssignment(
                start: word.start,
                end: word.end,
                artifact: artifact
            )
            let value = draft(
                segment: segment,
                start: word.start,
                end: word.end,
                text: word.text,
                confidence: word.confidence,
                assignment: assignment
            )
            if let last = groups.last,
               last.speakerID == value.speakerID,
               last.ambiguity == value.ambiguity {
                groups[groups.count - 1] = last.merging(value, tokenAware: true)
            } else {
                groups.append(value)
            }
        }
        if groups.isEmpty {
            return [draft(
                segment: segment,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                assignment: systemAssignment(
                    start: segment.start,
                    end: segment.end,
                    artifact: artifact
                )
            )]
        }
        return groups
    }

    private func systemAssignment(
        start: Double,
        end: Double,
        artifact: SpeakerDiarizationArtifact
    ) -> Assignment {
        let overlaps = artifact.result.segments.compactMap { segment -> (String, Double)? in
            let overlap = max(0, min(end, segment.end) - max(start, segment.start))
            return overlap > 0 ? (segment.speakerID, overlap) : nil
        }.reduce(into: [String: Double]()) { values, item in
            values[item.0, default: 0] += item.1
        }.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        guard let best = overlaps.first else {
            return Assignment(
                speakerID: "unknown-speaker",
                speaker: "Unknown speaker",
                ambiguity: .unmatchedSpeech
            )
        }
        var value = assignment(for: best.key, artifact: artifact)
        if overlaps.count > 1,
           best.value - overlaps[1].value <= configuration.ambiguityToleranceSeconds {
            value.ambiguity = .overlappingSpeakers
        }
        return value
    }

    private func assignment(
        for speakerID: String,
        artifact: SpeakerDiarizationArtifact
    ) -> Assignment {
        guard let profile = artifactStore.effectiveProfile(for: speakerID, in: artifact) else {
            return Assignment(
                speakerID: "unknown-speaker",
                speaker: "Unknown speaker",
                ambiguity: .unmatchedSpeech
            )
        }
        return Assignment(
            speakerID: profile.id,
            speaker: profile.state == .unknown ? "Unknown speaker" : profile.displayName,
            ambiguity: .none
        )
    }

    private func draft(
        segment: TranscriptSegment,
        start: Double,
        end: Double,
        text: String,
        confidence: Double? = nil,
        assignment: Assignment
    ) -> Draft {
        Draft(
            source: segment.source,
            speakerID: assignment.speakerID,
            speaker: assignment.speaker,
            start: start,
            end: end,
            language: segment.language,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence ?? segment.confidence,
            sourceSegmentIDs: [segment.id],
            ambiguity: assignment.ambiguity
        )
    }

    private func mergeContinuousDrafts(_ values: [Draft]) -> [Draft] {
        var result: [Draft] = []
        for value in values where !value.text.isEmpty {
            if let last = result.last,
               last.source == value.source,
               last.speakerID == value.speakerID,
               last.ambiguity == value.ambiguity,
               value.start - last.end <= configuration.continuousSpeechGapSeconds,
               value.start >= last.start {
                result[result.count - 1] = last.merging(value, tokenAware: false)
            } else {
                result.append(value)
            }
        }
        return result
    }

    private func draftComesBefore(_ lhs: Draft, _ rhs: Draft) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private struct Assignment {
        let speakerID: String
        let speaker: String
        var ambiguity: ResolvedSpeakerAmbiguity
    }

    private struct Draft {
        let source: TranscriptSource
        let speakerID: String
        let speaker: String
        let start: Double
        let end: Double
        let language: String
        let text: String
        let confidence: Double?
        let sourceSegmentIDs: [String]
        let ambiguity: ResolvedSpeakerAmbiguity

        func merging(_ other: Draft, tokenAware: Bool) -> Draft {
            Draft(
                source: source,
                speakerID: speakerID,
                speaker: speaker,
                start: min(start, other.start),
                end: max(end, other.end),
                language: language == other.language ? language : "mixed",
                text: joined(text, other.text, tokenAware: tokenAware),
                confidence: weightedConfidence(other),
                sourceSegmentIDs: sourceSegmentIDs + other.sourceSegmentIDs.filter {
                    !sourceSegmentIDs.contains($0)
                },
                ambiguity: ambiguity
            )
        }

        private func weightedConfidence(_ other: Draft) -> Double? {
            let values = [confidence, other.confidence].compactMap { $0 }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        private func joined(_ lhs: String, _ rhs: String, tokenAware: Bool) -> String {
            guard !lhs.isEmpty else { return rhs }
            guard !rhs.isEmpty else { return lhs }
            if tokenAware,
               let first = rhs.first,
               ".,!?;:)]}%".contains(first) {
                return lhs + rhs
            }
            if tokenAware, lhs.last?.isWhitespace == true { return lhs + rhs }
            return lhs + " " + rhs
        }
    }
}
