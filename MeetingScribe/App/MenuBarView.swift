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

            Divider()

            Button("Quit MeetingScribe") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 320)
        .task {
            await appState.prepareStorage()
        }
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
            TextField("Meeting title (optional)", text: $appState.meetingTitle)

            Picker("Whisper model", selection: $appState.selectedWhisperModelID) {
                ForEach(WhisperModelDescriptor.supported) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .onChange(of: appState.selectedWhisperModelID) {
                Task {
                    await appState.refreshWhisperModelStatus()
                }
            }

            Label(
                "Whisper: \(appState.whisperModelStatusText)",
                systemImage: whisperModelIcon
            )
            .font(.caption)
            .foregroundStyle(whisperModelColor)

            if case .ready = appState.whisperModelStatus {
                EmptyView()
            } else {
                Button(downloadModelButtonTitle) {
                    Task {
                        await appState.downloadSelectedWhisperModel()
                    }
                }
                .disabled(appState.isDownloadingWhisperModel)
            }

            Button("Start recording…") {
                Task {
                    await appState.startRecording()
                }
            }
            .buttonStyle(.borderedProminent)

            if appState.status == .completed || appState.status == .failed {
                Button("Reset status") {
                    appState.reset()
                }
            }
        }
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
