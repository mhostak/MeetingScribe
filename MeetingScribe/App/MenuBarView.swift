import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            switch appState.status {
            case .idle, .completed, .failed:
                startControls
            case .recording:
                recordingControls
            default:
                ProgressView(appState.status.displayName)
            }

            if let lastError = appState.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Open recordings folder") {
                appState.openRecordingsFolder()
            }

            if appState.currentSession != nil || appState.lastCompletedSession != nil {
                Button("Reveal session manifest") {
                    appState.revealLastSession()
                }
            }

            if appState.lastMarkdownURL != nil {
                Button("Open Markdown") {
                    appState.openLastMarkdown()
                }

                Button("Reveal Markdown in Finder") {
                    appState.revealLastMarkdown()
                }

                if appState.canOpenLastMarkdownInObsidian {
                    Button("Open in Obsidian") {
                        appState.openLastMarkdownInObsidian()
                    }
                }
            }

            Divider()

            Button("Quit MeetingScribe") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: appState.status.menuBarSystemImage)
                .foregroundStyle(appState.status == .recording ? .red : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text("MeetingScribe")
                    .font(.headline)
                Text(appState.status.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var startControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let candidate = appState.recoveryCandidates.first {
                recoveryControls(candidate)
                Divider()
            }

            TextField("Meeting title (optional)", text: $appState.meetingTitle)

            VStack(alignment: .leading, spacing: 4) {
                Label("Markdown output", systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(appState.outputFolderDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack {
                    Button("Choose folder…") {
                        appState.chooseOutputFolder()
                    }

                    if appState.outputFolderURL != nil {
                        Button("Use default") {
                            appState.useDefaultOutputFolder()
                        }
                    }
                }
            }

            Picker("Whisper model", selection: $appState.selectedWhisperModelID) {
                ForEach(WhisperModelDescriptor.supported) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .onChange(of: appState.selectedWhisperModelID) {
                appState.persistWhisperModelSelection()
                Task {
                    await appState.refreshWhisperModelStatus()
                }
            }

            Picker(
                "Transcription language",
                selection: $appState.selectedTranscriptionLanguage
            ) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .onChange(of: appState.selectedTranscriptionLanguage) {
                appState.persistTranscriptionLanguageSelection()
            }

            Text(appState.selectedTranscriptionLanguage.selectionHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Whisper: \(appState.whisperModelStatusText)",
                systemImage: whisperModelIcon
            )
            .font(.caption)
            .foregroundStyle(whisperModelColor)

            if case .ready = appState.whisperModelStatus {
                EmptyView()
            } else {
                if let progress = appState.whisperModelDownloadProgress {
                    ProgressView(value: progress) {
                        Text("Downloading… \(progress.formatted(.percent.precision(.fractionLength(0))))")
                    }
                    .font(.caption)
                }
                Button(downloadModelButtonTitle) {
                    Task {
                        await appState.downloadSelectedWhisperModel()
                    }
                }
                .disabled(appState.isDownloadingWhisperModel)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("AI meeting analysis", isOn: $appState.aiAnalysisEnabled)
                    .onChange(of: appState.aiAnalysisEnabled) {
                        appState.persistAnalysisSettings()
                    }

                if appState.aiAnalysisEnabled {
                    Picker("OpenAI model", selection: $appState.selectedOpenAIModel) {
                        ForEach(OpenAIModelDescriptor.supported) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .onChange(of: appState.selectedOpenAIModel) {
                        appState.persistAnalysisSettings()
                    }

                    Label(
                        appState.hasOpenAIAPIKey
                            ? "OpenAI API key: stored in Keychain"
                            : "OpenAI API key: missing",
                        systemImage: appState.hasOpenAIAPIKey
                            ? "key.fill"
                            : "key.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(appState.hasOpenAIAPIKey ? .green : .orange)

                    SecureField("OpenAI API key", text: $appState.openAIAPIKeyInput)

                    HStack {
                        Button(appState.hasOpenAIAPIKey ? "Replace key" : "Save key") {
                            Task {
                                await appState.saveOpenAIAPIKey()
                            }
                        }
                        .disabled(
                            appState.isSavingOpenAIAPIKey
                                || appState.openAIAPIKeyInput
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                        )

                        if appState.hasOpenAIAPIKey {
                            Button("Delete key") {
                                Task {
                                    await appState.deleteOpenAIAPIKey()
                                }
                            }
                        }
                    }

                    Text("Only transcript text and meeting metadata are sent to OpenAI. Audio stays local.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button("Start recording…") {
                Task {
                    await appState.startRecording()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.recoveryCandidates.isEmpty || appState.isRecoveringSession)

            Text("Before recording, make sure you have the required permission or participant consent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.status == .completed || appState.status == .failed {
                Button("Reset status") {
                    appState.reset()
                }
            }
        }
    }

    private func recoveryControls(_ candidate: SessionRecoveryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Unfinished recording found", systemImage: "arrow.counterclockwise.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(candidate.session.metadata.title)
                .font(.subheadline.weight(.semibold))

            Text(candidate.reason.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(recoveryArtifactDescription(candidate.artifacts))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Recover and process") {
                    Task {
                        await appState.recoverSession(candidate)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isRecoveringSession)

                Button("Reveal") {
                    appState.revealRecovery(candidate)
                }
            }

            Button("Close without deleting files") {
                Task {
                    await appState.closeRecovery(candidate)
                }
            }
            .disabled(appState.isRecoveringSession)

            if appState.recoveryCandidates.count > 1 {
                Text("\(appState.recoveryCandidates.count - 1) more recoverable session(s) will appear next.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func recoveryArtifactDescription(_ artifacts: SessionRecoveryArtifacts) -> String {
        var values: [String] = []
        if artifacts.hasSystemAudio { values.append("system audio") }
        if artifacts.hasMicrophoneAudio { values.append("microphone") }
        if artifacts.hasMergedTranscript { values.append("transcript") }
        if artifacts.hasAnalysis { values.append("analysis") }
        return "Preserved: " + (values.isEmpty ? "session files" : values.joined(separator: ", "))
    }

    private var downloadModelButtonTitle: String {
        if appState.isDownloadingWhisperModel {
            return "Downloading Whisper model…"
        }
        let size = ByteCountFormatter.string(
            fromByteCount: appState.selectedWhisperModel.approximateSizeBytes,
            countStyle: .file
        )
        return "Download \(appState.selectedWhisperModel.displayName) (\(size))"
    }

    private var whisperModelIcon: String {
        if case .ready = appState.whisperModelStatus {
            return "checkmark.circle.fill"
        }
        return "arrow.down.circle"
    }

    private var whisperModelColor: Color {
        if case .ready = appState.whisperModelStatus {
            return .green
        }
        return .secondary
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let startedAt = appState.currentSession?.metadata.startedAt {
                RecordingDurationView(startedAt: startedAt)
            }

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

            Button("Stop recording") {
                Task {
                    await appState.stopRecording()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func audioStatus(
        title: String,
        diagnostics: AudioCaptureDiagnostics,
        required: Bool
    ) -> some View {
        let health = diagnostics.health()

        return VStack(alignment: .leading, spacing: 4) {
            Label(
                audioStatusText(title: title, health: health),
                systemImage: audioIcon(for: health)
            )
                .foregroundStyle(health == .stalled || health == .failed ? .orange : .secondary)

            Text("Buffers: \(diagnostics.bufferCount) · Frames: \(diagnostics.totalFrames)")
                .foregroundStyle(.secondary)

            if health == .stalled {
                Text("No \(title.lowercased()) buffers received for 10 seconds. Recording continues.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failureReason = diagnostics.failureReason, !required {
                Text(failureReason)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }

    private func audioStatusText(title: String, health: AudioCaptureHealth) -> String {
        switch health {
        case .idle, .waitingForData:
            return "\(title): waiting for data"
        case .active:
            return "\(title): active"
        case .stalled:
            return "\(title): no recent data"
        case .failed:
            return "\(title): capture error"
        }
    }

    private func audioIcon(for health: AudioCaptureHealth) -> String {
        switch health {
        case .active:
            return "waveform.badge.checkmark"
        case .stalled, .failed:
            return "exclamationmark.triangle.fill"
        case .idle, .waitingForData:
            return "waveform"
        }
    }
}

private struct RecordingDurationView: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            let hours = elapsed / 3_600
            let minutes = (elapsed % 3_600) / 60
            let seconds = elapsed % 60

            Text(String(format: "● Recording — %02d:%02d:%02d", hours, minutes, seconds))
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(.red)
        }
    }
}
