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
        artifact: SpeakerDiarizationArtifact,
        transcriptFingerprint: String? = nil,
        artifactFingerprint: String? = nil
    ) throws -> ResolvedTranscript {
        guard transcript.sessionID == artifact.sessionID else {
            throw SpeakerArtifactError.wrongSession
        }
        guard artifact.effectiveTimelineOffsetSeconds.isFinite,
              artifact.effectiveTimelineOffsetSeconds >= 0 else {
            throw SpeakerArtifactError.invalidTimelineOffset
        }
        let resolvedTranscriptFingerprint: String
        if let transcriptFingerprint {
            resolvedTranscriptFingerprint = transcriptFingerprint
        } else {
            resolvedTranscriptFingerprint = try artifactStore.fingerprint(transcript: transcript)
        }
        guard artifact.sourceTranscriptFingerprint == resolvedTranscriptFingerprint else {
            throw SpeakerArtifactError.staleTranscript
        }

        let profiles = artifactStore.effectiveProfiles(in: artifact)
        var sweep = SystemAssignmentSweep(segments: artifact.result.segments)
        var drafts: [Draft] = []
        for segment in transcript.segments {
            if segment.source == .microphone {
                drafts.append(draft(
                    segment: segment,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    assignment: assignment(for: SpeakerProfile.localID, profiles: profiles)
                ))
                continue
            }
            guard let words = segment.words, !words.isEmpty else {
                drafts.append(draft(
                    segment: segment,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    assignment: systemAssignment(
                        start: segment.start,
                        end: segment.end,
                        timelineOffset: artifact.effectiveTimelineOffsetSeconds,
                        profiles: profiles,
                        sweep: &sweep
                    )
                ))
                continue
            }
            drafts.append(contentsOf: wordDrafts(
                words,
                segment: segment,
                timelineOffset: artifact.effectiveTimelineOffsetSeconds,
                profiles: profiles,
                sweep: &sweep
            ))
        }
        let merged = mergeContinuousDrafts(drafts.sorted(by: draftComesBefore))
        let resolvedArtifactFingerprint: String
        if let artifactFingerprint {
            resolvedArtifactFingerprint = artifactFingerprint
        } else {
            resolvedArtifactFingerprint = try artifactStore.fingerprint(artifact: artifact)
        }
        return ResolvedTranscript(
            schemaVersion: 1,
            sessionID: transcript.sessionID,
            createdAt: now(),
            sourceTranscriptFingerprint: resolvedTranscriptFingerprint,
            diarizationFingerprint: resolvedArtifactFingerprint,
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
        timelineOffset: Double,
        profiles: [String: SpeakerProfile],
        sweep: inout SystemAssignmentSweep
    ) -> [Draft] {
        var groups: [Draft] = []
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let assignment = systemAssignment(
                start: word.start,
                end: word.end,
                timelineOffset: timelineOffset,
                profiles: profiles,
                sweep: &sweep
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
                    timelineOffset: timelineOffset,
                    profiles: profiles,
                    sweep: &sweep
                )
            )]
        }
        return groups
    }

    private func systemAssignment(
        start: Double,
        end: Double,
        timelineOffset: Double,
        profiles: [String: SpeakerProfile],
        sweep: inout SystemAssignmentSweep
    ) -> Assignment {
        let localStart = start - timelineOffset
        let localEnd = end - timelineOffset
        let overlaps = sweep.overlaps(start: localStart, end: localEnd)
        guard let best = overlaps.first else {
            return Assignment(
                speakerID: "unknown-speaker",
                speaker: "Unknown speaker",
                ambiguity: .unmatchedSpeech
            )
        }
        var value = assignment(for: best.key, profiles: profiles)
        if overlaps.count > 1,
           best.value - overlaps[1].value <= configuration.ambiguityToleranceSeconds {
            value.ambiguity = .overlappingSpeakers
        }
        return value
    }

    private func assignment(
        for speakerID: String,
        profiles: [String: SpeakerProfile]
    ) -> Assignment {
        guard let profile = profiles[speakerID] else {
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

    private struct SystemAssignmentSweep {
        let segments: [SpeakerDiarizationSegment]
        var cursor = 0
        var lastStart = -Double.infinity

        mutating func overlaps(start: Double, end: Double) -> [(key: String, value: Double)] {
            guard end > start else { return [] }
            if start < lastStart {
                cursor = 0
            }
            lastStart = start
            while cursor < segments.count, segments[cursor].end <= start {
                cursor += 1
            }
            var totals: [String: Double] = [:]
            var index = cursor
            while index < segments.count, segments[index].start < end {
                let segment = segments[index]
                let overlap = max(0, min(end, segment.end) - max(start, segment.start))
                if overlap > 0 {
                    totals[segment.speakerID, default: 0] += overlap
                }
                index += 1
            }
            return totals.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
        }
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
