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

            Button("Start prototype session…") {
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

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let startedAt = appState.currentSession?.metadata.startedAt {
                RecordingDurationView(startedAt: startedAt)
            }

            Label("Phase 1 stores metadata only; audio capture is not enabled yet", systemImage: "externaldrive.fill.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Stop recording") {
                Task {
                    await appState.stopRecording()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
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

            Text(String(format: "● Prototype session — %02d:%02d:%02d", hours, minutes, seconds))
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(.red)
        }
    }
}
