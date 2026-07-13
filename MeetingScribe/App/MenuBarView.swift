import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let candidate = appState.recoveryCandidates.first,
               appState.status == .idle || appState.status == .completed || appState.status == .failed {
                recoveryBanner(candidate)
            }

            Group {
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

            if let lastError = appState.lastError, appState.status != .failed {
                messageBanner(lastError, color: .orange, icon: "exclamationmark.triangle.fill")
            }

            footer
        }
        .padding(18)
        .frame(width: 360)
        .environment(\.locale, appState.selectedAppLanguage.locale)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title3.weight(.semibold))
                .foregroundStyle(
                    appState.status == .recording ? Color.red : Color.accentColor
                )
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
            }
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Meeting title (optional)", text: $appState.meetingTitle)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 7) {
                settingsChip(
                    appState.selectedWhisperModel.displayName,
                    icon: "waveform",
                    section: "transcription"
                )
                settingsChip(
                    appState.aiAnalysisEnabled ? "AI on" : "AI off",
                    icon: "sparkles",
                    section: "ai"
                )
                settingsChip(
                    appState.outputFolderURL?.lastPathComponent ?? "Output folder",
                    icon: "folder",
                    section: "output"
                )
            }

            Button {
                Task { await appState.startRecording() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!appState.recoveryCandidates.isEmpty || appState.isRecoveringSession)

            Text("Make sure you have the required permission or participant consent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingContent: some View {
        VStack(spacing: 14) {
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
        }
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
        }
    }

    private var completedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            messageBanner(
                "Meeting processed successfully",
                color: .green,
                icon: "checkmark.circle.fill"
            )

            if let name = appState.lastMarkdownURL?.lastPathComponent {
                Label(name, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if appState.canOpenLastMarkdownInObsidian {
                Button {
                    appState.openLastMarkdownInObsidian()
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if appState.lastMarkdownURL != nil {
                Button {
                    appState.openLastMarkdown()
                } label: {
                    Label("Open Markdown", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack {
                Button("Show in Finder") { appState.revealLastMarkdown() }
                    .disabled(appState.lastMarkdownURL == nil)
                Spacer()
                Button("New meeting") { appState.reset() }
            }
        }
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
                    appState.openRecordingsFolder()
                } label: {
                    Label("Recordings", systemImage: "folder")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Quit MeetingScribe") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.caption)
        }
    }

    private func settingsChip(_ title: String, icon: String, section: String) -> some View {
        Button {
            appState.selectedSettingsSection = section
            openSettings()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(LocalizedStringKey(title))
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

    private func recoveryBanner(_ candidate: SessionRecoveryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Unfinished recording found", systemImage: "arrow.counterclockwise.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(candidate.session.metadata.title)
                .font(.caption)
                .lineLimit(1)
            HStack {
                Button("Recover and process") {
                    Task { await appState.recoverSession(candidate) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isRecoveringSession)
                Button("Reveal") { appState.revealRecovery(candidate) }
                Spacer()
                Button("Close") { Task { await appState.closeRecovery(candidate) } }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func messageBanner(_ message: String, color: Color, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func audioStatus(
        title: String,
        diagnostics: AudioCaptureDiagnostics,
        required: Bool
    ) -> some View {
        let health = diagnostics.health()
        return HStack(spacing: 8) {
            Image(systemName: audioIcon(for: health))
                .foregroundStyle(health == .stalled || health == .failed ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(audioStatusText(title: title, health: health))
                if let failureReason = diagnostics.failureReason, !required {
                    Text(failureReason).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func audioStatusText(title: String, health: AudioCaptureHealth) -> String {
        switch health {
        case .idle, .waitingForData: return "\(title): waiting for data"
        case .active: return "\(title): active"
        case .stalled: return "\(title): no recent data"
        case .failed: return "\(title): capture error"
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "waveform")
                .symbolRenderingMode(.monochrome)

            if status == .recording {
                Circle().fill(.red).frame(width: 6, height: 6).offset(x: 3, y: -2)
            } else if status.isProcessing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .frame(width: 7, height: 7)
                    .offset(x: 4, y: 3)
            } else if status == .failed || hasRecovery {
                Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 3, y: -2)
            }
        }
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
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 4
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
        .accessibilityLabel("Recording audio activity")
    }
}
