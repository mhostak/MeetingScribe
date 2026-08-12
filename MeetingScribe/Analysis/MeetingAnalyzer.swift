import Foundation

struct MeetingAnalysisRun: Equatable, Sendable {
    let analysis: AnalysisMarkdown
    let transcriptChunkCount: Int
    let requestCount: Int
}

struct MeetingAnalyzer: Sendable {
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
        let lines = segments.map { segment in
            "[\(elapsedTime(segment.start))] [\(segment.id)] "
                + "\(segment.speaker) {\(segment.source.rawValue), \(segment.language)}: \(segment.text)"
        }
        guard !participantNames.isEmpty else { return try chunk(lines) }

        let context = "Confirmed participants: " + participantNames.joined(separator: ", ")
        let contentLimit = maxInputCharacters - context.count - 1
        guard contentLimit >= 1 else { throw AnalysisError.transcriptChunkTooLarge }
        return try chunk(lines, limit: contentLimit).map { context + "\n" + $0 }
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

    private func chunk(_ values: [String], limit: Int? = nil) throws -> [String] {
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
                current = []
                currentLength = 0
            }
            current.append(value)
            currentLength += value.count + (current.count == 1 ? 0 : 1)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
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
