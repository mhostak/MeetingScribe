import Foundation

struct TranscriptMerger: Sendable {
    private static let timestampScale = 1_000.0

    func merge(
        sessionID: String,
        title: String,
        systemTranscript: TrackTranscript,
        microphoneTranscript: TrackTranscript?,
        completedAt: Date
    ) throws -> MergedTranscript {
        guard systemTranscript.source == .system else {
            throw TranscriptMergeError.unexpectedTrackSource(
                expected: .system,
                actual: systemTranscript.source
            )
        }
        if let microphoneTranscript, microphoneTranscript.source != .microphone {
            throw TranscriptMergeError.unexpectedTrackSource(
                expected: .microphone,
                actual: microphoneTranscript.source
            )
        }

        var tracks = [makeTrack(from: systemTranscript)]
        var candidates = try normalizedCandidates(from: systemTranscript)
        if let microphoneTranscript {
            tracks.append(makeTrack(from: microphoneTranscript))
            candidates.append(contentsOf: try normalizedCandidates(from: microphoneTranscript))
        }

        candidates.sort(by: candidateComesBefore)
        let segments = candidates.enumerated().map { index, candidate in
            TranscriptSegment(
                id: String(format: "segment-%06d", index),
                source: candidate.source,
                speaker: candidate.speaker,
                start: candidate.start,
                end: candidate.end,
                language: candidate.language,
                text: candidate.text,
                confidence: candidate.confidence
            )
        }

        return MergedTranscript(
            sessionID: sessionID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            completedAt: completedAt,
            tracks: tracks,
            segments: segments
        )
    }

    private func makeTrack(from transcript: TrackTranscript) -> MergedTranscriptTrack {
        MergedTranscriptTrack(
            source: transcript.source,
            model: transcript.model,
            requestedLanguage: transcript.requestedLanguage,
            detectedLanguage: transcript.detectedLanguage,
            segmentCount: transcript.segments.count
        )
    }

    private func normalizedCandidates(
        from transcript: TrackTranscript
    ) throws -> [Candidate] {
        try transcript.segments.compactMap { segment in
            guard segment.source == transcript.source else {
                throw TranscriptMergeError.segmentSourceMismatch(
                    segmentID: segment.id,
                    track: transcript.source,
                    segment: segment.source
                )
            }
            guard segment.start.isFinite, segment.end.isFinite else {
                throw TranscriptMergeError.invalidTimestamp(segmentID: segment.id)
            }

            guard let text = WhisperTranscriptSanitizer.meaningfulText(from: segment.text) else {
                return nil
            }

            let start = normalizedTimestamp(max(0, segment.start))
            let end = max(start, normalizedTimestamp(max(0, segment.end)))
            let normalizedSpeaker = segment.speaker
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = normalizedSpeaker.isEmpty
                ? defaultSpeaker(for: segment.source)
                : normalizedSpeaker

            return Candidate(
                originalID: segment.id,
                source: segment.source,
                speaker: speaker,
                start: start,
                end: end,
                language: segment.language.trimmingCharacters(in: .whitespacesAndNewlines),
                text: text,
                confidence: segment.confidence
            )
        }
    }

    private func normalizedTimestamp(_ value: Double) -> Double {
        (value * Self.timestampScale).rounded() / Self.timestampScale
    }

    private func defaultSpeaker(for source: TranscriptSource) -> String {
        switch source {
        case .system:
            return "Other"
        case .microphone:
            return "Martin"
        }
    }

    private func candidateComesBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.source != rhs.source { return lhs.source == .system }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.originalID < rhs.originalID
    }
}

enum TranscriptMergeError: Error, Equatable, LocalizedError {
    case unexpectedTrackSource(expected: TranscriptSource, actual: TranscriptSource)
    case segmentSourceMismatch(
        segmentID: String,
        track: TranscriptSource,
        segment: TranscriptSource
    )
    case invalidTimestamp(segmentID: String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedTrackSource(expected, actual):
            return "Expected a \(expected.rawValue) transcript, received \(actual.rawValue)."
        case let .segmentSourceMismatch(segmentID, track, segment):
            return "Segment \(segmentID) belongs to \(segment.rawValue), not \(track.rawValue)."
        case let .invalidTimestamp(segmentID):
            return "Segment \(segmentID) contains a non-finite timestamp."
        }
    }
}

private struct Candidate: Sendable {
    let originalID: String
    let source: TranscriptSource
    let speaker: String
    let start: Double
    let end: Double
    let language: String
    let text: String
    let confidence: Double?
}
