import Foundation

/// Produces a deterministic, loss-preserving view of independently transcribed tracks.
///
/// Meaningful segments from both tracks are retained, including simultaneous
/// speech; this type does not deduplicate acoustic echo or collapse overlaps.
/// Timestamps are clamped to zero, rounded to milliseconds, and ordered by
/// start time, then system-before-microphone, end time, and original ID.
struct TranscriptMerger: Sendable {
    private static let timestampScale = 1_000.0

    /// Merges source-labelled tracks and assigns stable IDs in final timeline order.
    func merge(
        sessionID: String,
        title: String,
        systemTranscript: TrackTranscript?,
        microphoneTranscript: TrackTranscript?,
        completedAt: Date
    ) throws -> MergedTranscript {
        if let systemTranscript, systemTranscript.source != .system {
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

        guard systemTranscript != nil || microphoneTranscript != nil else {
            throw TranscriptMergeError.noTracks
        }

        var tracks: [MergedTranscriptTrack] = []
        var candidates: [Candidate] = []
        if let systemTranscript {
            tracks.append(makeTrack(from: systemTranscript))
            candidates.append(contentsOf: try normalizedCandidates(from: systemTranscript))
        }
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
                confidence: candidate.confidence,
                words: candidate.words
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
            segmentCount: transcript.segments.count,
            provenance: transcript.provenance
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

            guard let text = TranscriptSanitizer.meaningfulText(from: segment.text) else {
                return nil
            }

            let start = normalizedTimestamp(max(0, segment.start))
            let end = max(start, normalizedTimestamp(max(0, segment.end)))
            let normalizedSpeaker = segment.speaker
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = normalizedSpeaker.isEmpty
                ? defaultSpeaker(for: segment.source)
                : normalizedSpeaker
            let words = try normalizedWords(
                segment.words,
                segmentID: segment.id,
                segmentStart: start,
                segmentEnd: end
            )

            return Candidate(
                originalID: segment.id,
                source: segment.source,
                speaker: speaker,
                start: start,
                end: end,
                language: segment.language.trimmingCharacters(in: .whitespacesAndNewlines),
                text: text,
                confidence: segment.confidence,
                words: words
            )
        }
    }

    private func normalizedWords(
        _ words: [TranscriptWord]?,
        segmentID: String,
        segmentStart: Double,
        segmentEnd: Double
    ) throws -> [TranscriptWord]? {
        guard let words else { return nil }
        return try words.compactMap { word in
            guard word.start.isFinite, word.end.isFinite else {
                throw TranscriptMergeError.invalidTimestamp(segmentID: segmentID)
            }
            guard let text = TranscriptSanitizer.meaningfulText(from: word.text) else {
                return nil
            }
            let start = min(segmentEnd, max(segmentStart, normalizedTimestamp(word.start)))
            let end = min(segmentEnd, max(start, normalizedTimestamp(word.end)))
            return TranscriptWord(
                start: start,
                end: end,
                text: text,
                confidence: word.confidence
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
            return "Me"
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
    case noTracks
    case unexpectedTrackSource(expected: TranscriptSource, actual: TranscriptSource)
    case segmentSourceMismatch(
        segmentID: String,
        track: TranscriptSource,
        segment: TranscriptSource
    )
    case invalidTimestamp(segmentID: String)

    var errorDescription: String? {
        switch self {
        case .noTracks:
            return "No finalized audio track was available for transcription."
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
    let words: [TranscriptWord]?
}
