import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var isEditingMeetingTitle = false
    @State private var meetingTitleDraft = ""
    @FocusState private var isMeetingTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Group {
                if let candidate = activeRecoveryCandidate {
                    recoveryContent(candidate)
                } else {
                    statusContent
                }
            }

            if let lastError = appState.lastError, appState.status != .failed {
                messageBanner(lastError, color: .orange, icon: "exclamationmark.triangle.fill")
            }

            footer
        }
        .padding(18)
        .frame(width: 360)
        .environment(\.locale, appState.selectedAppLanguage.locale)
        .onChange(of: appState.currentSession?.metadata.id) {
            cancelMeetingTitleEditing()
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch appState.status {
        case .idle:
            readyContent
        case .recording:
            recordingContent
        case .completed:
            completedContent
        case .failed:
            failedContent
        case .preparing, .stopping, .transcribing, .analyzing, .exporting:
            processingContent
        }
    }

    private var activeRecoveryCandidate: SessionRecoveryCandidate? {
        appState.status == .idle ? appState.recoveryCandidates.first : nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title3.weight(.semibold))
                .foregroundStyle(appState.status == .recording ? Color.red : Color.accentColor)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text("MeetingScribe")
                    .font(.headline)
                Text(LocalizedStringKey(appState.status.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.status == .recording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Recording")
            }

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit MeetingScribe")
            .accessibilityLabel("Quit MeetingScribe")
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Meeting title (optional)", text: $appState.meetingTitle)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await appState.startRecording() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isRecoveringSession)

            Text("Make sure you have the required permission or participant consent.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                settingsChip(
                    appState.selectedWhisperModel.displayName,
                    icon: "waveform",
                    section: "transcription",
                    localizeTitle: false
                )
                settingsChip(
                    appState.aiAnalysisEnabled ? "AI on" : "AI off",
                    icon: "sparkles",
                    section: "ai"
                )
                settingsChip(
                    appState.outputFolderURL?.lastPathComponent ?? "Output folder",
                    icon: "folder",
                    section: "output",
                    localizeTitle: appState.outputFolderURL == nil
                )
            }
        }
    }

    private var recordingContent: some View {
        VStack(spacing: 14) {
            recordingTitleEditor

            if let startedAt = appState.currentSession?.metadata.startedAt {
                RecordingDurationView(startedAt: startedAt)
            }

            RecordingWaveformView()
                .frame(height: 42)

            VStack(spacing: 7) {
                audioStatus(
                    title: "System audio",
                    diagnostics: appState.captureDiagnostics.systemAudio,
                    required: true
                )
                audioStatus(
                    title: "Microphone",
                    diagnostics: appState.captureDiagnostics.microphone,
                    required: false
                )
            }

            Button {
                Task { await appState.stopRecording() }
            } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Text("Recording continues if this popover is closed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var recordingTitleEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)

            if isEditingMeetingTitle {
                TextField("Meeting title (optional)", text: $meetingTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .focused($isMeetingTitleFocused)
                    .onSubmit { saveMeetingTitle() }

                Button(action: saveMeetingTitle) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .disabled(
                    meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Save meeting title")
                .accessibilityLabel("Save meeting title")

                Button(action: cancelMeetingTitleEditing) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityLabel("Cancel")
            } else {
                Text(appState.currentSession?.metadata.title ?? appState.meetingTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Button(action: beginMeetingTitleEditing) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit meeting title")
                .accessibilityLabel("Edit meeting title")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func beginMeetingTitleEditing() {
        meetingTitleDraft = appState.currentSession?.metadata.title ?? appState.meetingTitle
        isEditingMeetingTitle = true
        DispatchQueue.main.async {
            isMeetingTitleFocused = true
        }
    }

    private func saveMeetingTitle() {
        let normalizedTitle = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        isMeetingTitleFocused = false
        isEditingMeetingTitle = false
        Task { await appState.renameCurrentSession(to: normalizedTitle) }
    }

    private func cancelMeetingTitleEditing() {
        isMeetingTitleFocused = false
        isEditingMeetingTitle = false
    }

    private var processingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Processing meeting")
                    .font(.headline)
                Text("You can close this popover. Processing will continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(appState.processingSteps) { step in
                    processingRow(step)
                    if step.id != ProcessingStepID.allCases.last {
                        Divider().padding(.leading, 30)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            sessionSummary(appState.currentSession, includesSegments: false)

            Label("Original audio is preserved until processing completes.", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var completedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            completedBanner

            Divider()

            TextField("Meeting title (optional)", text: $appState.meetingTitle)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await appState.startRecording() }
            } label: {
                Label("Start new meeting", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var completedBanner: some View {
        Button {
            guard let session = appState.lastCompletedSession else { return }
            appState.requestRecordingsOverview(for: session)
            openWindow(id: "recordings")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text("Meeting processed successfully")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(appState.lastCompletedSession == nil)
        .help("Show completed recording")
        .accessibilityLabel("Show completed recording")
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            messageBanner(
                appState.lastError ?? "Meeting processing failed.",
                color: .red,
                icon: "xmark.octagon.fill"
            )

            HStack {
                Button("Reveal session") { appState.revealLastSession() }
                Spacer()
                Button("Try another meeting") { appState.reset() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack {
                Button {
                    openWindow(id: "recordings")
                } label: {
                    Label("Recordings overview", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .font(.caption)
        }
    }

    private func settingsChip(
        _ title: String,
        icon: String,
        section: String,
        localizeTitle: Bool = true
    ) -> some View {
        Button {
            appState.selectedSettingsSection = section
            openSettings()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if localizeTitle {
                    Text(LocalizedStringKey(title))
                } else {
                    Text(verbatim: title)
                }
            }
            .font(.caption2)
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    private func processingRow(_ step: ProcessingStep) -> some View {
        HStack(spacing: 10) {
            Group {
                switch step.state {
                case .active:
                    ProgressView().controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)

            Text(LocalizedStringKey(step.id.displayName))
                .foregroundStyle(step.state == .pending ? .secondary : .primary)
            Spacer()
            if step.state == .skipped {
                Text("Skipped").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 38)
    }

    private func recoveryContent(_ candidate: SessionRecoveryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unfinished recording found", systemImage: "arrow.counterclockwise.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(candidate.session.metadata.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text(LocalizedStringKey(candidate.reason.displayName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                preservedTracks(candidate.artifacts)
            } icon: {
                Image(systemName: "waveform.badge.checkmark")
            }
            .font(.caption)

            if appState.recoveryCandidates.count > 1 {
                (Text("Further unfinished recordings:")
                    + Text(verbatim: " \(appState.recoveryCandidates.count - 1)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Recover and process") {
                Task { await appState.recoverSession(candidate) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(appState.isRecoveringSession)

            HStack {
                Button("Reveal") { appState.revealRecovery(candidate) }
                Spacer()
                Button("Close") { Task { await appState.closeRecovery(candidate) } }
            }
            .controlSize(.small)

            Text("Nothing is deleted when a recovery is closed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func preservedTracks(_ artifacts: SessionRecoveryArtifacts) -> some View {
        let hasSystem = artifacts.hasSystemAudio || artifacts.hasWorkingSystemAudio
        if hasSystem && artifacts.hasMicrophoneAudio {
            Text("Preserved tracks: system audio and microphone")
        } else if hasSystem {
            Text("Preserved track: system audio")
        } else if artifacts.hasMicrophoneAudio {
            Text("Preserved track: microphone")
        } else if artifacts.hasMergedTranscript {
            Text("Preserved artifact: transcript")
        } else {
            Text("Preserved session files")
        }
    }

    @ViewBuilder
    private func sessionSummary(_ session: RecordingSession?, includesSegments: Bool) -> some View {
        if let session {
            VStack(alignment: .leading, spacing: 6) {
                Label(session.metadata.title, systemImage: "text.quote")
                    .lineLimit(2)

                HStack(spacing: 14) {
                    if let duration = sessionDuration(session.metadata) {
                        Label(duration, systemImage: "clock")
                    }
                    if includesSegments,
                       let segments = session.metadata.transcription?.mergedSegmentCount {
                        Label {
                            Text(verbatim: "\(segments) ") + Text("segments")
                        } icon: {
                            Image(systemName: "text.bubble")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if includesSegments, let name = appState.lastMarkdownURL?.lastPathComponent {
                    Label(name, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sessionDuration(_ metadata: SessionMetadata) -> String? {
        guard let startedAt = metadata.startedAt else { return nil }
        let end = metadata.endedAt ?? Date()
        let elapsed = max(0, Int(end.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", elapsed / 3_600, (elapsed % 3_600) / 60, elapsed % 60)
    }

    private func messageBanner(_ message: String, color: Color, icon: String) -> some View {
        Label {
            Text(LocalizedStringKey(message))
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func audioStatus(
        title: LocalizedStringKey,
        diagnostics: AudioCaptureDiagnostics,
        required: Bool
    ) -> some View {
        let health = diagnostics.health()
        return HStack(spacing: 8) {
            Image(systemName: audioIcon(for: health))
                .foregroundStyle(health == .stalled || health == .failed ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title) + Text(": ") + Text(audioHealthKey(health))
                if let failureReason = diagnostics.failureReason, !required {
                    Text(LocalizedStringKey(failureReason)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func audioHealthKey(_ health: AudioCaptureHealth) -> LocalizedStringKey {
        switch health {
        case .idle, .waitingForData: return "waiting for data"
        case .active: return "active"
        case .stalled: return "no recent data"
        case .failed: return "capture error"
        }
    }

    private func audioIcon(for health: AudioCaptureHealth) -> String {
        switch health {
        case .active: return "waveform.badge.checkmark"
        case .stalled, .failed: return "exclamationmark.triangle.fill"
        case .idle, .waitingForData: return "waveform"
        }
    }
}

struct MenuBarStatusLabel: View {
    let status: AppStatus
    let hasRecovery: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var iconState: MenuBarIconState {
        MenuBarIconState(status: status, hasRecovery: hasRecovery)
    }

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(for: iconState, colorScheme: colorScheme))
            .renderingMode(.original)
            .frame(width: 24, height: 18)
            .id("\(iconState.rawValue)-\(colorScheme)")
            .accessibilityLabel(Text(LocalizedStringKey(iconState.accessibilityLabel)))
    }
}

private enum MenuBarIconRenderer {
    static func image(for state: MenuBarIconState, colorScheme: ColorScheme) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.shouldAntialias = true
            let baseColor: NSColor = colorScheme == .dark ? .white : .black
            drawWaveform(in: rect, color: baseColor)
            drawBadge(state, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawWaveform(in rect: NSRect, color: NSColor) {
        let heights: [CGFloat] = [6, 11, 16, 10, 6]
        color.setFill()
        for (index, height) in heights.enumerated() {
            let x = rect.minX + 1 + CGFloat(index) * 3.1
            let bar = NSRect(x: x, y: rect.midY - height / 2, width: 2.1, height: height)
            NSBezierPath(roundedRect: bar, xRadius: 1.05, yRadius: 1.05).fill()
        }
    }

    private static func drawBadge(_ state: MenuBarIconState, in rect: NSRect) {
        let center = NSPoint(x: rect.maxX - 4.6, y: rect.maxY - 4.6)
        switch state {
        case .idle:
            break
        case .recording:
            drawDot(center: center, color: .systemRed)
        case .attention:
            drawDot(center: center, color: .systemOrange)
        case .processing:
            let ringRect = NSRect(x: center.x - 3.2, y: center.y - 3.2, width: 6.4, height: 6.4)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: 3.2, startAngle: 35, endAngle: 305)
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            NSColor.systemBlue.setStroke()
            ring.stroke()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: ringRect.midX - 0.8, y: ringRect.midY - 0.8, width: 1.6, height: 1.6)).fill()
        }
    }

    private static func drawDot(center: NSPoint, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
    }
}

private struct RecordingDurationView: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(String(
                format: "%02d:%02d:%02d",
                elapsed / 3_600,
                (elapsed % 3_600) / 60,
                elapsed % 60
            ))
            .font(.system(size: 30, weight: .semibold, design: .monospaced))
            .foregroundStyle(.red)
            .contentTransition(.numericText())
        }
    }
}

private struct RecordingWaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                waveform(phase: 0.8)
            } else {
                TimelineView(.animation(minimumInterval: 0.16)) { context in
                    waveform(phase: context.date.timeIntervalSinceReferenceDate * 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording audio activity")
    }

    private func waveform(phase: Double) -> some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<22, id: \.self) { index in
                let wave = abs(sin(phase + Double(index) * 0.62))
                Capsule()
                    .fill(.red.opacity(0.55 + wave * 0.4))
                    .frame(width: 5, height: 7 + wave * 31)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
