import Foundation

struct MarkdownRenderer: Sendable {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func render(
        session: SessionMetadata,
        transcript: MergedTranscript,
        analysis: MeetingAnalysis? = nil
    ) -> String {
        let vocabulary = MarkdownVocabulary(language: session.resolvedOutputLanguage)
        let startedAt = session.startedAt ?? session.createdAt
        let endedAt = session.endedAt ?? transcript.completedAt
        let durationSeconds = max(0, endedAt.timeIntervalSince(startedAt))
        let durationMinutes = Int(ceil(durationSeconds / 60))
        let languages = uniqueValues(
            transcript.segments.map(\.language) + transcript.tracks.map(\.detectedLanguage)
        )
        let participants = uniqueValues(transcript.segments.map(\.speaker))

        var lines = [
            "---",
            "type: meeting",
            "title: \(yamlQuoted(session.title))",
            "date: \(dateString(startedAt))",
            "started: \(timeString(startedAt))",
            "ended: \(timeString(endedAt))",
            "duration_minutes: \(durationMinutes)",
        ]
        appendYAMLList(name: "languages", values: languages, to: &lines)
        appendYAMLList(name: "participants", values: participants, to: &lines)
        appendYAMLList(name: "tags", values: ["meeting"], to: &lines)
        lines.append("recording_id: \(yamlQuoted(session.id))")
        lines.append(contentsOf: [
            "---",
            "",
            "# \(markdownHeading(session.title))",
            "",
            "## \(vocabulary.summary)",
            "",
        ])
        appendSummary(analysis, vocabulary: vocabulary, to: &lines)
        appendReferences(
            title: vocabulary.decisions,
            values: analysis?.decisions,
            analysisAvailable: analysis != nil,
            vocabulary: vocabulary,
            to: &lines
        )
        appendActionItems(
            analysis?.actionItems,
            analysisAvailable: analysis != nil,
            vocabulary: vocabulary,
            to: &lines
        )
        appendReferences(
            title: vocabulary.openQuestions,
            values: analysis?.openQuestions,
            analysisAvailable: analysis != nil,
            vocabulary: vocabulary,
            to: &lines
        )
        appendReferences(
            title: vocabulary.risksAndBlockers,
            values: analysis?.risksAndBlockers,
            analysisAvailable: analysis != nil,
            vocabulary: vocabulary,
            to: &lines
        )
        appendReferences(
            title: vocabulary.nextMeetingTopics,
            values: analysis?.nextMeetingTopics,
            analysisAvailable: analysis != nil,
            vocabulary: vocabulary,
            to: &lines
        )
        lines.append(contentsOf: ["## \(vocabulary.transcript)", ""])

        if transcript.segments.isEmpty {
            lines.append("_\(vocabulary.emptyTranscript)_")
        } else {
            let overlappingIndices = TranscriptOverlapDetector().overlappingIndices(
                in: transcript.segments
            )
            for (index, segment) in transcript.segments.enumerated() {
                let overlap = overlappingIndices.contains(index)
                    ? " *(\(vocabulary.speechOverlap))*"
                    : ""
                lines.append(
                    "### \(elapsedTime(segment.start)) — \(markdownHeading(segment.speaker))\(overlap)"
                )
                lines.append("")
                lines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private func appendSummary(
        _ analysis: MeetingAnalysis?,
        vocabulary: MarkdownVocabulary,
        to lines: inout [String]
    ) {
        guard let analysis else {
            lines.append(contentsOf: ["<!-- \(vocabulary.analysisUnavailable) -->", ""])
            return
        }
        let summary = analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(summary.isEmpty ? "_\(vocabulary.summaryUnavailable)_" : summary)
        lines.append("")
    }

    private func appendReferences(
        title: String,
        values: [AnalysisReference]?,
        analysisAvailable: Bool,
        vocabulary: MarkdownVocabulary,
        to lines: inout [String]
    ) {
        lines.append(contentsOf: ["## \(title)", ""])
        guard analysisAvailable else {
            lines.append(contentsOf: ["<!-- \(vocabulary.analysisUnavailable) -->", ""])
            return
        }
        guard let values, !values.isEmpty else {
            lines.append(contentsOf: ["_\(vocabulary.noneIdentified)_", ""])
            return
        }
        lines.append(contentsOf: values.map { value in
            "- \(singleLine(value.text))\(evidenceSuffix(value.timestampSeconds, value.segmentID))"
        })
        lines.append("")
    }

    private func appendActionItems(
        _ values: [AnalysisActionItem]?,
        analysisAvailable: Bool,
        vocabulary: MarkdownVocabulary,
        to lines: inout [String]
    ) {
        lines.append(contentsOf: ["## \(vocabulary.actionItems)", ""])
        guard analysisAvailable else {
            lines.append(contentsOf: ["<!-- \(vocabulary.analysisUnavailable) -->", ""])
            return
        }
        guard let values, !values.isEmpty else {
            lines.append(contentsOf: ["_\(vocabulary.noneIdentified)_", ""])
            return
        }
        lines.append(contentsOf: values.map { value in
            let owner = nonEmpty(value.owner) ?? vocabulary.unknownOwner
            let dueDate = nonEmpty(value.dueDate) ?? vocabulary.unknownDueDate
            return "- [ ] \(owner) — \(singleLine(value.text)) — \(vocabulary.dueDate): \(dueDate)"
                + evidenceSuffix(value.timestampSeconds, value.segmentID)
        })
        lines.append("")
    }

    private func evidenceSuffix(_ timestamp: Double?, _ segmentID: String?) -> String {
        let values = [
            timestamp.map(elapsedTime),
            nonEmpty(segmentID).map { "`\($0)`" },
        ].compactMap { $0 }
        return values.isEmpty ? "" : " — " + values.joined(separator: " · ")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return normalized
    }

    private func singleLine(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func appendYAMLList(name: String, values: [String], to lines: inout [String]) {
        if values.isEmpty {
            lines.append("\(name): []")
            return
        }
        lines.append("\(name):")
        lines.append(contentsOf: values.map { "  - \(yamlQuoted($0))" })
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func dateString(_ date: Date) -> String {
        formatted(date, pattern: "yyyy-MM-dd")
    }

    private func timeString(_ date: Date) -> String {
        formatted(date, pattern: "HH:mm")
    }

    private func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
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

    private func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        return "\"\(escaped)\""
    }

    private func markdownHeading(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MarkdownVocabulary {
    let summary: String
    let decisions: String
    let actionItems: String
    let openQuestions: String
    let risksAndBlockers: String
    let nextMeetingTopics: String
    let transcript: String
    let speechOverlap: String
    let emptyTranscript: String
    let analysisUnavailable: String
    let summaryUnavailable: String
    let noneIdentified: String
    let unknownOwner: String
    let unknownDueDate: String
    let dueDate: String

    init(language: OutputLanguage) {
        switch language {
        case .slovak:
            self.init(
                summary: "Súhrn",
                decisions: "Rozhodnutia",
                actionItems: "Úlohy",
                openQuestions: "Otvorené otázky",
                risksAndBlockers: "Riziká a blokery",
                nextMeetingTopics: "Témy na ďalší meeting",
                transcript: "Prepis",
                speechOverlap: "prekrytie reči",
                emptyTranscript: "Prepis neobsahuje žiadne rozpoznané segmenty.",
                analysisUnavailable: "AI analýza zatiaľ nebola vytvorená.",
                summaryUnavailable: "Súhrn nebol identifikovaný.",
                noneIdentified: "Neboli identifikované.",
                unknownOwner: "Neurčené",
                unknownDueDate: "neurčený",
                dueDate: "termín"
            )
        case .czech:
            self.init(
                summary: "Shrnutí",
                decisions: "Rozhodnutí",
                actionItems: "Úkoly",
                openQuestions: "Otevřené otázky",
                risksAndBlockers: "Rizika a blokátory",
                nextMeetingTopics: "Témata na další schůzku",
                transcript: "Přepis",
                speechOverlap: "překryv řeči",
                emptyTranscript: "Přepis neobsahuje žádné rozpoznané segmenty.",
                analysisUnavailable: "AI analýza zatím nebyla vytvořena.",
                summaryUnavailable: "Shrnutí nebylo identifikováno.",
                noneIdentified: "Nebyly identifikovány.",
                unknownOwner: "Neurčeno",
                unknownDueDate: "neurčený",
                dueDate: "termín"
            )
        case .english:
            self.init(
                summary: "Summary",
                decisions: "Decisions",
                actionItems: "Action items",
                openQuestions: "Open questions",
                risksAndBlockers: "Risks and blockers",
                nextMeetingTopics: "Topics for the next meeting",
                transcript: "Transcript",
                speechOverlap: "overlapping speech",
                emptyTranscript: "The transcript contains no recognized segments.",
                analysisUnavailable: "AI analysis has not been created.",
                summaryUnavailable: "No summary was identified.",
                noneIdentified: "None identified.",
                unknownOwner: "Unassigned",
                unknownDueDate: "unspecified",
                dueDate: "due"
            )
        }
    }

    private init(
        summary: String,
        decisions: String,
        actionItems: String,
        openQuestions: String,
        risksAndBlockers: String,
        nextMeetingTopics: String,
        transcript: String,
        speechOverlap: String,
        emptyTranscript: String,
        analysisUnavailable: String,
        summaryUnavailable: String,
        noneIdentified: String,
        unknownOwner: String,
        unknownDueDate: String,
        dueDate: String
    ) {
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.risksAndBlockers = risksAndBlockers
        self.nextMeetingTopics = nextMeetingTopics
        self.transcript = transcript
        self.speechOverlap = speechOverlap
        self.emptyTranscript = emptyTranscript
        self.analysisUnavailable = analysisUnavailable
        self.summaryUnavailable = summaryUnavailable
        self.noneIdentified = noneIdentified
        self.unknownOwner = unknownOwner
        self.unknownDueDate = unknownDueDate
        self.dueDate = dueDate
    }
}

struct TranscriptOverlapDetector: Sendable {
    func overlappingIndices(in segments: [TranscriptSegment]) -> Set<Int> {
        let systemIndices = sortedIndices(for: .system, in: segments)
        let microphoneIndices = sortedIndices(for: .microphone, in: segments)
        var overlaps = Set<Int>()
        markOverlaps(
            in: systemIndices,
            against: mergedIntervals(from: microphoneIndices, in: segments),
            segments: segments,
            result: &overlaps
        )
        markOverlaps(
            in: microphoneIndices,
            against: mergedIntervals(from: systemIndices, in: segments),
            segments: segments,
            result: &overlaps
        )
        return overlaps
    }

    private func markOverlaps(
        in indices: [Int],
        against intervals: [(start: Double, end: Double)],
        segments: [TranscriptSegment],
        result: inout Set<Int>
    ) {
        var intervalCursor = 0
        for index in indices {
            let segment = segments[index]
            guard segment.start < segment.end else { continue }
            while intervalCursor < intervals.count,
                  intervals[intervalCursor].end <= segment.start {
                intervalCursor += 1
            }
            guard intervalCursor < intervals.count else { return }
            if intervals[intervalCursor].start < segment.end {
                result.insert(index)
            }
        }
    }

    private func mergedIntervals(
        from indices: [Int],
        in segments: [TranscriptSegment]
    ) -> [(start: Double, end: Double)] {
        var result: [(start: Double, end: Double)] = []
        for index in indices {
            let segment = segments[index]
            guard segment.start < segment.end else { continue }
            if let last = result.last, segment.start <= last.end {
                result[result.count - 1].end = max(last.end, segment.end)
            } else {
                result.append((segment.start, segment.end))
            }
        }
        return result
    }

    private func sortedIndices(
        for source: TranscriptSource,
        in segments: [TranscriptSegment]
    ) -> [Int] {
        segments.indices
            .filter { segments[$0].source == source }
            .sorted {
                let lhs = segments[$0]
                let rhs = segments[$1]
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end < rhs.end }
                return $0 < $1
            }
    }
}
