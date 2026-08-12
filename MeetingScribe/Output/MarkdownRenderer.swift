import Foundation

struct MarkdownRenderer: Sendable {
    static let analysisStartMarker = "<!-- meetingscribe:ai-analysis:start -->"
    static let analysisEndMarker = "<!-- meetingscribe:ai-analysis:end -->"

    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func render(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript? = nil,
        resolvedTranscript: ResolvedTranscript? = nil,
        analysis: AIAnalysisArtifact? = nil
    ) -> String {
        let vocabulary = MarkdownVocabulary(language: session.resolvedOutputLanguage)
        let renderedSegments = renderableSegments(
            transcript: transcript,
            utteranceTranscript: utteranceTranscript,
            resolvedTranscript: resolvedTranscript
        )
        let startedAt = session.startedAt ?? session.createdAt
        let endedAt = session.endedAt ?? transcript.completedAt
        let durationSeconds = max(0, endedAt.timeIntervalSince(startedAt))
        let durationMinutes = Int(ceil(durationSeconds / 60))
        let languages = uniqueValues(
            renderedSegments.map(\.language) + transcript.tracks.map(\.detectedLanguage)
        )
        let participants = session.calendarEvent.map { snapshot in
            uniqueValues(snapshot.participants.map(\.displayName))
        } ?? uniqueValues(renderedSegments.map { vocabulary.sourceLabel(for: $0.source) })

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
        if let analysis {
            let model = analysis.model.map { " – \($0)" } ?? ""
            lines.append(
                "\(yamlQuoted("ai analysis")): "
                    + yamlQuoted("\(dateString(analysis.generatedAt)) – \(analysis.tool.rawValue)\(model)")
            )
        }
        lines.append(contentsOf: [
            "---",
            "",
            "# \(markdownHeading(session.title))",
            "",
            Self.analysisStartMarker,
        ])
        if let analysis {
            lines.append(analysis.markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            lines.append("<!-- \(vocabulary.analysisUnavailable) -->")
        }
        lines.append(contentsOf: [Self.analysisEndMarker, ""])
        lines.append(contentsOf: ["## \(vocabulary.transcript)", ""])

        if renderedSegments.isEmpty {
            lines.append("_\(vocabulary.emptyTranscript)_")
        } else {
            let overlappingIndices = TranscriptOverlapDetector().overlappingIndices(
                in: renderedSegments
            )
            for (index, segment) in renderedSegments.enumerated() {
                let overlap = overlappingIndices.contains(index)
                    ? " *(\(vocabulary.speechOverlap))*"
                    : ""
                lines.append(
                    "### \(elapsedTime(segment.start)) — "
                        + "\(markdownHeading(vocabulary.sourceLabel(for: segment.source)))\(overlap)"
                )
                lines.append("")
                lines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private func renderableSegments(
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?,
        resolvedTranscript: ResolvedTranscript?
    ) -> [TranscriptSegment] {
        _ = resolvedTranscript // Legacy input is deliberately ignored for source-based output.
        let sourceBlocks: ContinuousUtteranceTranscript
        if let utteranceTranscript,
           utteranceTranscript.sessionID == transcript.sessionID,
           utteranceTranscript.configuration == .sourceBlocks {
            sourceBlocks = utteranceTranscript
        } else {
            sourceBlocks = SourceConversationBlockGrouper().group(
                transcript: transcript,
                sourceFingerprint: "markdown-source-blocks"
            )
        }
        return sourceBlocks.utterances.map { utterance in
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
    let transcript: String
    let speechOverlap: String
    let emptyTranscript: String
    let analysisUnavailable: String
    let remoteParticipants: String
    let onSiteParticipants: String

    func sourceLabel(for source: TranscriptSource) -> String {
        switch source {
        case .system: return remoteParticipants
        case .microphone: return onSiteParticipants
        }
    }

    init(language: OutputLanguage) {
        switch language {
        case .slovak:
            self.init(
                transcript: "Prepis",
                speechOverlap: "prekrytie reči",
                emptyTranscript: "Prepis neobsahuje žiadne rozpoznané segmenty.",
                analysisUnavailable: "AI analýza zatiaľ nebola vytvorená.",
                remoteParticipants: "Vzdialení účastníci",
                onSiteParticipants: "Účastníci na mieste"
            )
        case .czech:
            self.init(
                transcript: "Přepis",
                speechOverlap: "překryv řeči",
                emptyTranscript: "Přepis neobsahuje žádné rozpoznané segmenty.",
                analysisUnavailable: "AI analýza zatím nebyla vytvořena.",
                remoteParticipants: "Vzdálení účastníci",
                onSiteParticipants: "Účastníci na místě"
            )
        case .english:
            self.init(
                transcript: "Transcript",
                speechOverlap: "overlapping speech",
                emptyTranscript: "The transcript contains no recognized segments.",
                analysisUnavailable: "AI analysis has not been created.",
                remoteParticipants: "Remote participants",
                onSiteParticipants: "On-site participants"
            )
        }
    }

    private init(
        transcript: String,
        speechOverlap: String,
        emptyTranscript: String,
        analysisUnavailable: String,
        remoteParticipants: String,
        onSiteParticipants: String
    ) {
        self.transcript = transcript
        self.speechOverlap = speechOverlap
        self.emptyTranscript = emptyTranscript
        self.analysisUnavailable = analysisUnavailable
        self.remoteParticipants = remoteParticipants
        self.onSiteParticipants = onSiteParticipants
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
