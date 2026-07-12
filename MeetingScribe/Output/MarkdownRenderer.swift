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
            "## Súhrn",
            "",
        ])
        appendSummary(analysis, to: &lines)
        appendReferences(
            title: "Rozhodnutia",
            values: analysis?.decisions,
            analysisAvailable: analysis != nil,
            to: &lines
        )
        appendActionItems(analysis?.actionItems, analysisAvailable: analysis != nil, to: &lines)
        appendReferences(
            title: "Otvorené otázky",
            values: analysis?.openQuestions,
            analysisAvailable: analysis != nil,
            to: &lines
        )
        appendReferences(
            title: "Riziká a blokery",
            values: analysis?.risksAndBlockers,
            analysisAvailable: analysis != nil,
            to: &lines
        )
        appendReferences(
            title: "Témy na ďalší meeting",
            values: analysis?.nextMeetingTopics,
            analysisAvailable: analysis != nil,
            to: &lines
        )
        lines.append(contentsOf: ["## Transcript", ""])

        if transcript.segments.isEmpty {
            lines.append("_Transcript neobsahuje žiadne rozpoznané segmenty._")
        } else {
            let overlappingIndices = TranscriptOverlapDetector().overlappingIndices(
                in: transcript.segments
            )
            for (index, segment) in transcript.segments.enumerated() {
                let overlap = overlappingIndices.contains(index) ? " *(prekrytie reči)*" : ""
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

    private func appendSummary(_ analysis: MeetingAnalysis?, to lines: inout [String]) {
        guard let analysis else {
            lines.append(contentsOf: ["<!-- AI analýza zatiaľ nebola vytvorená. -->", ""])
            return
        }
        let summary = analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(summary.isEmpty ? "_Súhrn nebol identifikovaný._" : summary)
        lines.append("")
    }

    private func appendReferences(
        title: String,
        values: [AnalysisReference]?,
        analysisAvailable: Bool,
        to lines: inout [String]
    ) {
        lines.append(contentsOf: ["## \(title)", ""])
        guard analysisAvailable else {
            lines.append(contentsOf: ["<!-- AI analýza zatiaľ nebola vytvorená. -->", ""])
            return
        }
        guard let values, !values.isEmpty else {
            lines.append(contentsOf: ["_Neboli identifikované._", ""])
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
        to lines: inout [String]
    ) {
        lines.append(contentsOf: ["## Úlohy", ""])
        guard analysisAvailable else {
            lines.append(contentsOf: ["<!-- AI analýza zatiaľ nebola vytvorená. -->", ""])
            return
        }
        guard let values, !values.isEmpty else {
            lines.append(contentsOf: ["_Neboli identifikované._", ""])
            return
        }
        lines.append(contentsOf: values.map { value in
            let owner = nonEmpty(value.owner) ?? "Neurčené"
            let dueDate = nonEmpty(value.dueDate) ?? "neurčený"
            return "- [ ] \(owner) — \(singleLine(value.text)) — termín: \(dueDate)"
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
