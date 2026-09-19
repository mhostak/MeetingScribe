import Foundation

struct MarkdownRenderer: Sendable {
    static let analysisStartMarker = "<!-- meetingscribe:ai-analysis:start -->"
    static let analysisEndMarker = "<!-- meetingscribe:ai-analysis:end -->"
    static let userNotesStartMarker = "<!-- meetingscribe:user-notes:start -->"
    static let userNotesEndMarker = "<!-- meetingscribe:user-notes:end -->"

    /// The markers that delimit regions this application owns and rewrites.
    static let reservedMarkers = [
        analysisStartMarker,
        analysisEndMarker,
        userNotesStartMarker,
        userNotesEndMarker,
    ]

    /// Turns a reserved marker inside user-supplied text into ordinary text.
    ///
    /// A meeting title, a Calendar description or a note can contain anything,
    /// including a marker pasted out of an earlier MeetingScribe note. A
    /// second analysis start marker in the document is not a cosmetic problem:
    /// it appears before the real one, and re-analysis replaces everything
    /// between the first start marker and the real end marker — the
    /// frontmatter and the heading along with it.
    ///
    /// The text itself is kept and shown in brackets. It stops being an HTML
    /// comment, which is the only property that made it dangerous.
    static func neutralizingReservedMarkers(_ text: String) -> String {
        guard text.contains("<!--") else { return text }
        var text = text
        for marker in reservedMarkers {
            guard text.contains(marker) else { continue }
            let inner = marker
                .dropFirst("<!--".count)
                .dropLast("-->".count)
                .trimmingCharacters(in: .whitespaces)
            text = text.replacingOccurrences(of: marker, with: "[\(inner)]")
        }
        return text
    }

    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func render(
        session: SessionMetadata,
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript? = nil,
        analysis: AIAnalysisArtifact? = nil,
        notes: String? = nil
    ) -> String {
        let vocabulary = MarkdownVocabulary(language: session.resolvedOutputLanguage)
        let renderedSegments = renderableSegments(
            transcript: transcript,
            utteranceTranscript: utteranceTranscript
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

        let safeTitle = Self.neutralizingReservedMarkers(session.title)
        var lines = [
            "---",
            "type: meeting",
            "title: \(yamlQuoted(safeTitle))",
            "date: \(dateString(startedAt))",
            "started: \(timeString(startedAt))",
            "ended: \(timeString(endedAt))",
            "duration_minutes: \(durationMinutes)",
        ]
        appendYAMLList(name: "languages", values: languages, to: &lines)
        appendYAMLList(name: "participants", values: participants, to: &lines)
        if let eventDescription = session.calendarEvent?.eventDescription {
            lines.append(
                "calendar_description: "
                    + yamlQuoted(Self.neutralizingReservedMarkers(eventDescription))
            )
        }
        appendYAMLList(name: "tags", values: ["meeting"], to: &lines)
        lines.append("recording_id: \(yamlQuoted(session.id))")
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("notes: true")
        }
        if let analysis {
            lines.append(analysisFrontmatterLine(analysis))
        }
        lines.append(contentsOf: [
            "---",
            "",
            "# \(markdownHeading(safeTitle))",
            "",
            Self.analysisStartMarker,
        ])
        if let analysis {
            // Current analyses are rejected at the schema if they contain a
            // reserved marker, but an `analysis.json` written by an older
            // build is replayed unchanged during recovery.
            lines.append(
                Self.neutralizingReservedMarkers(analysis.markdown)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else {
            lines.append("<!-- \(vocabulary.analysisUnavailable) -->")
        }
        lines.append(contentsOf: [Self.analysisEndMarker, ""])
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(contentsOf: [
                Self.userNotesStartMarker,
                "## \(vocabulary.userNotes)",
                Self.neutralizingReservedMarkers(notes),
                Self.userNotesEndMarker,
                "",
            ])
        }
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

    func analysisFrontmatterLine(_ analysis: AIAnalysisArtifact) -> String {
        let model = analysis.model.map { " – \($0)" } ?? ""
        return "\(yamlQuoted("ai analysis")): "
            + yamlQuoted("\(dateString(analysis.generatedAt)) – \(analysis.tool.rawValue)\(model)")
    }

    private func renderableSegments(
        transcript: MergedTranscript,
        utteranceTranscript: ContinuousUtteranceTranscript?
    ) -> [TranscriptSegment] {
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
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C:
                escaped += "\\\\"
            case 0x22:
                escaped += "\\\""
            case 0x0A, 0x0D:
                escaped += "\\n"
            case 0x09, 0x00...0x08, 0x0B...0x1F, 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    private func markdownHeading(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MarkdownAnalysisUpdateError: Error, Equatable, LocalizedError {
    case invalidStructure
    case couldNotDecode
    case couldNotEncode

    var errorDescription: String? {
        switch self {
        case .invalidStructure:
            return "The Markdown file does not contain a valid MeetingScribe AI analysis block."
        case .couldNotDecode:
            return "The Markdown file could not be decoded as UTF-8."
        case .couldNotEncode:
            return "The updated Markdown file could not be encoded as UTF-8."
        }
    }
}

struct MarkdownAnalysisUpdater: Sendable {
    private let renderer: MarkdownRenderer

    init(timeZone: TimeZone = .current) {
        renderer = MarkdownRenderer(timeZone: timeZone)
    }

    func update(_ analysis: AIAnalysisArtifact, at markdownURL: URL) throws {
        guard let markdown = try? String(contentsOf: markdownURL, encoding: .utf8) else {
            throw MarkdownAnalysisUpdateError.couldNotDecode
        }
        let updated = try updating(markdown, with: analysis)
        guard let data = updated.data(using: .utf8) else {
            throw MarkdownAnalysisUpdateError.couldNotEncode
        }
        try data.write(to: markdownURL, options: .atomic)
    }

    func updating(_ markdown: String, with analysis: AIAnalysisArtifact) throws -> String {
        // Search the body only. The frontmatter carries the meeting title and
        // the Calendar description verbatim, and a marker quoted inside one of
        // them would otherwise be found first — making the replacement below
        // delete the frontmatter and the heading on its way to the real end
        // marker. The renderer neutralizes such markers as it writes; this
        // covers documents written before it did, and hand-edited ones.
        let searchStart = Self.bodyStart(of: markdown)
        guard let startRange = markdown.range(
                  of: MarkdownRenderer.analysisStartMarker,
                  range: searchStart..<markdown.endIndex
              ),
              let endRange = markdown.range(
                  of: MarkdownRenderer.analysisEndMarker,
                  range: startRange.upperBound..<markdown.endIndex
              ) else {
            throw MarkdownAnalysisUpdateError.invalidStructure
        }

        let normalizedAnalysis = analysis.markdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = markdown
        updated.replaceSubrange(
            startRange.upperBound..<endRange.lowerBound,
            with: "\n\(normalizedAnalysis)\n"
        )

        var lines = updated.components(separatedBy: "\n")
        guard lines.first == "---",
              let frontmatterEnd = lines.dropFirst().firstIndex(of: "---") else {
            throw MarkdownAnalysisUpdateError.invalidStructure
        }
        let analysisLine = renderer.analysisFrontmatterLine(analysis)
        let existingLine = lines[1..<frontmatterEnd].firstIndex { line in
            let normalized = line.trimmingCharacters(in: .whitespaces)
            return normalized.hasPrefix("\"ai analysis\":")
                || normalized.hasPrefix("ai analysis:")
        }
        if let existingLine {
            lines[existingLine] = analysisLine
        } else {
            lines.insert(analysisLine, at: frontmatterEnd)
        }
        return lines.joined(separator: "\n")
    }

    /// The first index after the YAML frontmatter, or the start of the
    /// document when there is no frontmatter to skip.
    ///
    /// A document whose frontmatter is never closed has no body, and the
    /// caller's own `---` check rejects it a moment later. Returning the start
    /// of the document in that case keeps this a pure positioning helper that
    /// cannot reject anything on its own.
    private static func bodyStart(of markdown: String) -> String.Index {
        let delimiter = "---\n"
        guard markdown.hasPrefix(delimiter) else { return markdown.startIndex }
        let afterOpening = markdown.index(markdown.startIndex, offsetBy: delimiter.count)
        guard let closing = markdown.range(
            of: "\n---\n",
            range: markdown.index(before: afterOpening)..<markdown.endIndex
        ) else {
            return markdown.startIndex
        }
        return closing.upperBound
    }
}

private struct MarkdownVocabulary {
    let transcript: String
    let userNotes: String
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
                userNotes: "Poznámky",
                speechOverlap: "prekrytie reči",
                emptyTranscript: "Prepis neobsahuje žiadne rozpoznané segmenty.",
                analysisUnavailable: "AI analýza zatiaľ nebola vytvorená.",
                remoteParticipants: "Vzdialení účastníci",
                onSiteParticipants: "Účastníci na mieste"
            )
        case .czech:
            self.init(
                transcript: "Přepis",
                userNotes: "Poznámky",
                speechOverlap: "překryv řeči",
                emptyTranscript: "Přepis neobsahuje žádné rozpoznané segmenty.",
                analysisUnavailable: "AI analýza zatím nebyla vytvořena.",
                remoteParticipants: "Vzdálení účastníci",
                onSiteParticipants: "Účastníci na místě"
            )
        case .english:
            self.init(
                transcript: "Transcript",
                userNotes: "Notes",
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
        userNotes: String,
        speechOverlap: String,
        emptyTranscript: String,
        analysisUnavailable: String,
        remoteParticipants: String,
        onSiteParticipants: String
    ) {
        self.transcript = transcript
        self.userNotes = userNotes
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
