import Foundation

struct MeetingAnalysisRun: Equatable, Sendable {
    let analysis: AnalysisMarkdown
    let transcriptChunkCount: Int
    let requestCount: Int
}

struct MeetingAnalyzer: Sendable {
    private static let maximumOverlapCharacters = 2_000

    private let provider: any AnalysisProvider
    private let maxInputCharacters: Int

    init(
        provider: any AnalysisProvider,
        maxInputCharacters: Int = 45_000
    ) {
        self.provider = provider
        self.maxInputCharacters = max(1_000, maxInputCharacters)
    }

    func analyze(
        session: SessionMetadata,
        transcript: MergedTranscript,
        userPrompt: String = AnalysisPrompt.defaultTemplate
    ) async throws -> MeetingAnalysisRun {
        try Task.checkCancellation()
        let chunks = try transcriptChunks(
            from: transcript.segments,
            participantNames: participantNamesForAnalysis(from: session)
        )
        guard !chunks.isEmpty else {
            return MeetingAnalysisRun(
                analysis: .empty,
                transcriptChunkCount: 0,
                requestCount: 0
            )
        }

        var requestCount = 0
        var partials: [AnalysisMarkdown] = []
        for chunk in chunks {
            try Task.checkCancellation()
            partials.append(
                try await provider.analyze(
                    AnalysisRequest(
                        mode: .transcript,
                        meetingTitle: session.title,
                        recordingID: session.id,
                        preferredLanguage: session.resolvedOutputLanguage,
                        userPrompt: userPrompt,
                        content: chunk
                    )
                )
            )
            try Task.checkCancellation()
            requestCount += 1
        }

        while partials.count > 1 {
            try Task.checkCancellation()
            let groups = try consolidationGroups(from: partials)
            guard groups.count < partials.count else {
                throw AnalysisError.transcriptChunkTooLarge
            }

            var consolidated: [AnalysisMarkdown] = []
            for group in groups {
                try Task.checkCancellation()
                if group.count == 1 {
                    consolidated.append(group[0])
                    continue
                }
                let content = try encodedAnalyses(group)
                consolidated.append(
                    try await provider.analyze(
                        AnalysisRequest(
                            mode: .consolidation,
                            meetingTitle: session.title,
                            recordingID: session.id,
                            preferredLanguage: session.resolvedOutputLanguage,
                            userPrompt: userPrompt,
                            content: content
                        )
                    )
                )
                try Task.checkCancellation()
                requestCount += 1
            }
            partials = consolidated
        }

        try Task.checkCancellation()
        return MeetingAnalysisRun(
            analysis: partials[0],
            transcriptChunkCount: chunks.count,
            requestCount: requestCount
        )
    }

    private func transcriptChunks(
        from segments: [TranscriptSegment],
        participantNames: [String]
    ) throws -> [String] {
        let context = participantNames.isEmpty
            ? nil
            : "Confirmed participants: " + participantNames.joined(separator: ", ")
        let contentLimit = maxInputCharacters - (context.map { $0.count + 1 } ?? 0)
        guard contentLimit >= 1 else { throw AnalysisError.transcriptChunkTooLarge }

        let lines = try segments.flatMap { segment in
            try transcriptLines(for: segment, limit: contentLimit)
        }
        let chunks = try chunk(
            lines,
            limit: contentLimit,
            overlapLimit: overlapLimit(for: contentLimit)
        )
        guard let context else { return chunks }
        return chunks.map { context + "\n" + $0 }
    }

    /// Source-based conversation grouping can turn an entire single-source meeting into one
    /// segment. Split that text here so long meetings still fit in bounded AI requests.
    private func transcriptLines(
        for segment: TranscriptSegment,
        limit: Int
    ) throws -> [String] {
        let prefixAtStart = transcriptLinePrefix(for: segment, start: segment.start)
        let maximumPrefixLength = max(
            prefixAtStart.count,
            transcriptLinePrefix(for: segment, start: segment.end).count
        )
        let textLimit = limit - maximumPrefixLength
        guard textLimit >= 1 else { throw AnalysisError.transcriptChunkTooLarge }

        let pieces = splitText(
            segment.text,
            limit: textLimit,
            overlapLimit: overlapLimit(for: textLimit)
        )
        guard !pieces.isEmpty else { return [prefixAtStart] }

        let totalCharacters = max(
            1,
            segment.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        )
        let duration = max(0, segment.end - segment.start)
        return pieces.map { piece in
            let progress = Double(piece.startOffset) / Double(totalCharacters)
            let lineStart = segment.start + duration * progress
            return transcriptLinePrefix(for: segment, start: lineStart) + piece.text
        }
    }

    private func transcriptLinePrefix(
        for segment: TranscriptSegment,
        start: Double
    ) -> String {
        "[\(elapsedTime(start))] [\(segment.id)] "
            + "\(segment.speaker) {\(segment.source.rawValue), \(segment.language)}: "
    }

    private func splitText(
        _ text: String,
        limit: Int,
        overlapLimit: Int
    ) -> [TextPiece] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var pieces: [TextPiece] = []
        var start = normalized.startIndex

        while normalized.distance(from: start, to: normalized.endIndex) > limit {
            let hardEnd = normalized.index(start, offsetBy: limit)
            let candidate = normalized[start..<hardEnd]
            let minimumSemanticLength = max(1, limit * 2 / 3)
            let semanticEnd = candidate.indices.reversed().first { index in
                let length = normalized.distance(from: start, to: index) + 1
                return length >= minimumSemanticLength
                    && isSemanticBoundary(candidate[index])
            }.map { normalized.index(after: $0) }
            let wordEnd = candidate.lastIndex(where: { $0.isWhitespace }) ?? hardEnd
            let end = semanticEnd ?? wordEnd
            let piece = normalized[start..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                pieces.append(
                    TextPiece(
                        text: piece,
                        startOffset: normalized.distance(
                            from: normalized.startIndex,
                            to: start
                        )
                    )
                )
            }

            let pieceLength = normalized.distance(from: start, to: end)
            let overlap = min(overlapLimit, max(0, pieceLength / 3))
            var nextStart = normalized.index(end, offsetBy: -overlap)
            if let whitespace = normalized[nextStart..<end].firstIndex(where: { $0.isWhitespace }) {
                nextStart = normalized.index(after: whitespace)
            }
            while nextStart < normalized.endIndex, normalized[nextStart].isWhitespace {
                nextStart = normalized.index(after: nextStart)
            }
            start = nextStart > start ? nextStart : end
        }

        let finalPiece = normalized[start...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalPiece.isEmpty {
            pieces.append(
                TextPiece(
                    text: finalPiece,
                    startOffset: normalized.distance(from: normalized.startIndex, to: start)
                )
            )
        }
        return pieces
    }

    private func isSemanticBoundary(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character.isNewline
    }

    private func overlapLimit(for limit: Int) -> Int {
        min(Self.maximumOverlapCharacters, max(0, limit / 10))
    }

    private func participantNamesForAnalysis(from session: SessionMetadata) -> [String] {
        guard let calendarEvent = session.calendarEvent,
              calendarEvent.shareParticipantNamesWithAnalysis else {
            return []
        }
        return calendarEvent.participants.compactMap { participant in
            let name = participant.displayName
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return name.isEmpty ? nil : name
        }
    }

    private func consolidationGroups(
        from analyses: [AnalysisMarkdown]
    ) throws -> [[AnalysisMarkdown]] {
        var groups: [[AnalysisMarkdown]] = []
        var current: [AnalysisMarkdown] = []
        var currentLength = 2

        for analysis in analyses {
            let length = try encodedAnalyses([analysis]).count
            guard length <= maxInputCharacters else {
                throw AnalysisError.transcriptChunkTooLarge
            }
            if !current.isEmpty, currentLength + length > maxInputCharacters {
                groups.append(current)
                current = []
                currentLength = 2
            }
            current.append(analysis)
            currentLength += length
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func chunk(
        _ values: [String],
        limit: Int? = nil,
        overlapLimit: Int = 0
    ) throws -> [String] {
        let limit = limit ?? maxInputCharacters
        var chunks: [String] = []
        var current: [String] = []
        var currentLength = 0

        for value in values {
            guard value.count <= limit else {
                throw AnalysisError.transcriptChunkTooLarge
            }
            let addedLength = value.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty, currentLength + addedLength > limit {
                chunks.append(current.joined(separator: "\n"))
                current = overlappingSuffix(
                    of: current,
                    overlapLimit: overlapLimit,
                    spaceAvailable: limit - value.count - 1
                )
                currentLength = current.isEmpty
                    ? 0
                    : current.reduce(0) { $0 + $1.count } + current.count - 1
            }
            current.append(value)
            currentLength += value.count + (current.count == 1 ? 0 : 1)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    private func overlappingSuffix(
        of values: [String],
        overlapLimit: Int,
        spaceAvailable: Int
    ) -> [String] {
        guard overlapLimit > 0, spaceAvailable > 0 else { return [] }
        var suffix: [String] = []
        var length = 0
        for value in values.reversed() {
            let addedLength = value.count + (suffix.isEmpty ? 0 : 1)
            guard length + addedLength <= overlapLimit,
                  length + addedLength <= spaceAvailable else {
                break
            }
            suffix.insert(value, at: 0)
            length += addedLength
        }
        return suffix
    }

    private struct TextPiece {
        let text: String
        let startOffset: Int
    }

    private func encodedAnalyses(_ analyses: [AnalysisMarkdown]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(analyses), as: UTF8.self)
    }

    private func elapsedTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(
            format: "%02d:%02d:%02d",
            total / 3_600,
            (total % 3_600) / 60,
            total % 60
        )
    }
}
