import AppKit
import SwiftUI

struct ReadinessView: View {
    @ObservedObject var appState: AppState
    var openOnboardingAction: () -> Void

    init(
        appState: AppState,
        openOnboardingAction: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.openOnboardingAction = openOnboardingAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Readiness overview")
                        .font(.headline)
                    summaryText
                        .font(.subheadline)
                }

                Spacer()

                Button("Open setup guide") {
                    openOnboardingAction()
                }
                Button("Check again") {
                    Task { await appState.refreshReadiness() }
                }
                .disabled(appState.isRefreshingReadiness)
            }

            if let error = appState.readinessError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Readiness check failed"))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ReadinessOverviewView(appState: appState, openSettingsAction: {})

                    Divider()

                    Text("Setup test")
                        .font(.headline)
                    Text("Permission is not proof that audio is arriving from a device. Run the test after changing an input device or a permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SetupTestView(appState: appState)
                }
                .padding(.bottom, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 160, idealHeight: 260, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 360)
        .environment(\.locale, appState.selectedAppLanguage.locale)
        .task { await appState.refreshReadiness() }
        .onChange(of: appState.readinessConfiguration) {
            Task { await appState.refreshReadiness() }
        }
        .onChange(of: appState.analysisToolStatus) {
            Task { await appState.refreshReadiness() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await appState.refreshReadiness() }
        }
    }

    @ViewBuilder
    private var summaryText: some View {
        if appState.isRefreshingReadiness {
            Label("Checking readiness…", systemImage: "hourglass")
        } else {
            switch appState.readinessSnapshot?.summary {
            case .readyForRecordingAndTranscription:
                Label("Ready for recording and transcription", systemImage: "checkmark.circle.fill")
            case .readyForRecordingTranscriptionNeedsAttention:
                Label("Recording ready · transcription needs attention", systemImage: "exclamationmark.triangle.fill")
            case .recordingNeedsAttention:
                Label("Recording needs attention", systemImage: "exclamationmark.triangle.fill")
            case nil:
                Label("Readiness has not been checked", systemImage: "questionmark.circle")
            }
        }
    }
}

struct ReadinessOverviewView: View {
    @ObservedObject var appState: AppState
    let openSettingsAction: () -> Void

    init(
        appState: AppState,
        openSettingsAction: @escaping () -> Void
    ) {
        self.appState = appState
        self.openSettingsAction = openSettingsAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = appState.readinessSnapshot {
                ForEach(snapshot.checks) { check in
                    ReadinessCheckRow(
                        appState: appState,
                        check: check,
                        openSettingsAction: openSettingsAction
                    )
                }

                Text("Checked at \(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No readiness result",
                    systemImage: "checkmark.seal",
                    description: Text("Choose Check again to inspect permissions, storage, the transcription model, and output.")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ReadinessCheckRow: View {
    @ObservedObject var appState: AppState
    let check: ReadinessCheck
    let openSettingsAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(LocalizedStringKey(check.localizationKey))
                        .font(.headline)
                    Spacer()
                    Text(LocalizedStringKey(statusKey))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel(
                            Text("\(Text(LocalizedStringKey(statusKey))), \(Text(verbatim: detailText))")
                        )
                }

                Text(verbatim: detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let impactKey {
                    Text(LocalizedStringKey(impactKey))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let actionTitle = actionTitle {
                    Button(LocalizedStringKey(actionTitle)) {
                        Task {
                            await appState.performReadinessAction(check.action) {
                                openSettingsAction()
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var statusIcon: String {
        switch check.status {
        case .checking: return "hourglass"
        case .ready: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .unverified: return "questionmark.circle"
        case .optional: return "sparkles"
        }
    }

    private var statusColor: Color {
        switch check.status {
        case .checking: return .secondary
        case .ready: return .green
        case .needsAttention: return .orange
        case .unverified: return .secondary
        case .optional: return .accentColor
        }
    }

    private var statusKey: String {
        switch check.status {
        case .checking: return "Checking"
        case .ready: return "Ready"
        case .needsAttention: return "Needs attention"
        case .unverified: return "Unverified"
        case .optional: return "Optional"
        }
    }

    private var detailText: String {
        appState.localized(check.detail)
    }

    /// Only a consequence the user can act on is worth a line of its own; a
    /// passing check shows what it is set to instead.
    private var impactKey: String? {
        switch check.impact {
        case .blocksRecording: return "Blocks recording"
        case .blocksCaptureMode: return "Blocks the selected capture mode"
        case .limitsProcessing: return "Limits later processing"
        case .warning: return "Warning: recording can continue without this track"
        case .informational, .none: return nil
        }
    }

    private var actionTitle: String? {
        switch check.action {
        case .requestSystemAudioPermission:
            return "Allow system audio"
        case .openSystemAudioSettings:
            return "Open system audio settings"
        case .requestMicrophonePermission:
            return "Allow microphone"
        case .connectMicrophoneInput:
            return "Connect a microphone"
        case .freeStorageSpace, .fixStorageAccess:
            return "Open recordings folder"
        case .downloadTranscriptionModel:
            return "Download transcription model"
        case .importTranscriptionModel:
            return "Import transcription model"
        case .repairTranscriptionModel:
            return "Repair transcription model"
        case .chooseOutputFolder:
            return "Choose output folder…"
        case .useSessionFolder:
            return "Use session folder"
        case .fixOutputFileNameTemplate:
            return "Open output settings"
        case .openAISettings:
            return "Open AI settings"
        case .disableAI:
            return "Turn off AI"
        case .openCalendarSettings:
            return "Open Calendar settings"
        case .openNotificationSettings:
            return "Open notification settings"
        case .none:
            return nil
        }
    }
}
