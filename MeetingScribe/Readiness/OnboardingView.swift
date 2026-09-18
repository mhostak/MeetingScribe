import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var fluidAudioModelState: FluidAudioModelState
    let openSettingsAction: () -> Void
    let closeAction: () -> Void

    init(
        appState: AppState,
        openSettingsAction: @escaping () -> Void,
        closeAction: @escaping () -> Void
    ) {
        self.appState = appState
        _fluidAudioModelState = ObservedObject(
            wrappedValue: appState.fluidAudioModelState
        )
        self.openSettingsAction = openSettingsAction
        self.closeAction = closeAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prepare MeetingScribe")
                        .font(.title2.weight(.semibold))
                    Text("You can leave any step and continue later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Later") {
                    appState.deferOnboarding()
                    closeAction()
                }
            }

            stepIndicator

            Divider()

            // A step can be taller than the window — the readiness list alone
            // needs roughly 950pt — so only the step body scrolls. The step
            // indicator and the navigation buttons stay reachable at any size.
            ScrollView {
                Group {
                    switch appState.onboardingStep {
                    case .welcome:
                        welcomeStep
                    case .audioPermissions:
                        audioPermissionsStep
                    case .transcriptionAndOutput:
                        transcriptionAndOutputStep
                    case .review:
                        reviewStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            // An ideal height keeps the window's natural size independent of
            // how tall the current step happens to be.
            .frame(minHeight: 160, idealHeight: 260, maxHeight: .infinity)

            HStack {
                Button("Back") {
                    appState.moveToPreviousOnboardingStep()
                }
                .disabled(appState.onboardingStep == .welcome)

                Spacer()

                if appState.onboardingStep == .review {
                    Button("Finish setup") {
                        appState.completeOnboarding()
                        closeAction()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") {
                        appState.advanceOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 420)
        .environment(\.locale, appState.selectedAppLanguage.locale)
        .task { await appState.refreshReadiness() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await appState.refreshReadiness() }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element.id) { index, step in
                Button {
                    appState.setOnboardingStep(step)
                } label: {
                    VStack(spacing: 3) {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption.weight(.bold))
                        Text(LocalizedStringKey(stepTitle(for: step)))
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        step == appState.onboardingStep ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(stepTitle(for: step))))
                .accessibilityAddTraits(step == appState.onboardingStep ? .isSelected : [])
            }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How MeetingScribe works")
                .font(.headline)
            Text("MeetingScribe records system audio and your microphone locally, transcribes the audio on this Mac, and exports Markdown. A missing transcription model does not prevent recording.")
            Text("AI analysis is optional. When it is enabled, the transcript and selected meeting metadata may be sent to the provider used by the selected CLI tool.")

            Divider()
            HStack {
                Text("Application language")
                Picker("Application language", selection: $appState.selectedAppLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }
                .labelsHidden()
                .onChange(of: appState.selectedAppLanguage) {
                    Task { await appState.persistApplicationSettings() }
                }
                Spacer()
            }
            Text("Transcription and output languages remain separate choices in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioPermissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sound and permissions")
                .font(.headline)
            Text("MeetingScribe records two separate tracks: system audio and your microphone. Permission is not proof that audio is arriving from a device.")

            HStack(spacing: 12) {
                permissionCard(
                    title: "System audio",
                    detail: "Needed to capture meeting sound from the system.",
                    actionTitle: "Allow system audio",
                    action: .requestSystemAudioPermission
                )
                permissionCard(
                    title: "Microphone",
                    detail: "Needed to capture your voice as a separate local track.",
                    actionTitle: "Allow microphone",
                    action: .requestMicrophonePermission
                )
            }

            Text("After returning from System Settings, use Check again. If a newly granted permission is still not visible, restart MeetingScribe.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptionAndOutputStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcription and storage")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(appState.fluidAudioASRDescriptor.displayName)
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Text("Model status")
                    Spacer()
                    Text(LocalizedStringKey(fluidAudioStatusText))
                        .foregroundStyle(.secondary)
                    fluidAudioAction
                }
                Text("The model is downloaded, imported, or repaired only when you choose that action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text("Markdown destination")
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: appState.outputFolderDescription)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Choose folder…") {
                        appState.chooseOutputFolder()
                        Task { await appState.refreshReadiness() }
                    }
                    Button("Use session folder") {
                        appState.useDefaultOutputFolder()
                        Task { await appState.refreshReadiness() }
                    }
                }
                Text("Choosing a folder verifies that the selected destination is writable; MeetingScribe creates only a temporary probe file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("AI analysis is optional.")
                Button("Open AI settings") {
                    appState.selectedSettingsSection = "ai"
                    openSettingsAction()
                }
                Spacer()
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Readiness results")
                    .font(.headline)
                Spacer()
                Button("Check again") {
                    Task { await appState.refreshReadiness() }
                }
                .disabled(appState.isRefreshingReadiness)
            }

            ReadinessOverviewView(
                appState: appState,
                openSettingsAction: openSettingsAction
            )

            HStack(alignment: .firstTextBaseline) {
                Text("Permission is not proof that audio is arriving. The ten-second setup test lives in Readiness.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open readiness settings") {
                    appState.selectedSettingsSection = "readiness"
                    openSettingsAction()
                }
                .controlSize(.small)
            }
        }
    }

    private func permissionCard(
        title: String,
        detail: LocalizedStringKey,
        actionTitle: String,
        action: ReadinessAction
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(actionTitle) {
                    Task {
                        await appState.performReadinessAction(action, openSettings: {})
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var fluidAudioStatusText: String {
                switch fluidAudioModelState.asrStatus {
                case .missing: return "Missing"
                case .ready: return "Ready"
                case .invalid: return "Invalid"
                }
    }

    @ViewBuilder
    private var fluidAudioAction: some View {
        if fluidAudioModelState.isInstallingASRModel {
            ProgressView(value: fluidAudioModelState.asrDownloadProgress?.fractionCompleted ?? 0) {
                Text("Installing")
            }
        } else {
            switch fluidAudioModelState.asrStatus {
            case .ready:
                HStack {
                    Button("Verify and repair") {
                        appState.installFluidAudioModel(.transcription, repair: true)
                    }
                    Button("Import verified folder…") {
                        Task { await appState.importFluidAudioModel(.transcription) }
                    }
                }
            case .missing:
                HStack {
                    Button {
                        appState.installFluidAudioModel(.transcription)
                    } label: {
                        Text("Download")
                            + Text(verbatim: " (\(modelSize()))")
                    }
                    Button("Import verified folder…") {
                        Task { await appState.importFluidAudioModel(.transcription) }
                    }
                }
            case .invalid:
                HStack {
                    Button("Repair") {
                        appState.installFluidAudioModel(.transcription, repair: true)
                    }
                    Button("Import verified folder…") {
                        Task { await appState.importFluidAudioModel(.transcription) }
                    }
                }
            }
        }
    }

    private func stepTitle(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "Welcome"
        case .audioPermissions: return "Sound"
        case .transcriptionAndOutput: return "Storage"
        case .review: return "Check"
        }
    }

    private func modelSize() -> String {
        ByteCountFormatter.string(
            fromByteCount: appState.fluidAudioASRDescriptor.approximateSizeBytes,
            countStyle: .file
        )
    }
}

/// The ten-second setup test. It is shown both in the guide and in the
/// readiness overview: a replaced microphone or a permission revoked by a
/// system update has to be re-checked without walking back through a guide
/// that is already finished.
struct SetupTestView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Markdown and exported files will be stored in")
                .font(.caption.weight(.semibold))
            Text(appState.onboardingTestArtifactDestinationURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Test audio will be stored in")
                .font(.caption.weight(.semibold))
                .padding(.top, 2)
            Text(appState.onboardingTestAudioDestinationURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                switch appState.onboardingTestPhase {
                case .idle, .completed, .failed:
                    Button("Run 10-second test") {
                        Task { await appState.startOnboardingTest() }
                    }
                    .disabled(!appState.canStartOnboardingTest)
                    .help(appState.canStartOnboardingTest ? "" : "The setup test is unavailable while MeetingScribe is busy.")
                case .starting:
                    ProgressView("Starting test…")
                case .recording:
                    Button("Stop test") {
                        Task { await appState.stopOnboardingTest() }
                    }
                case .processing:
                    ProgressView("Processing test…")
                }
                Spacer()
            }

            if appState.onboardingTestPhase == .recording {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let remaining = appState.onboardingTestRemainingSeconds(at: context.date) {
                        Text("Test stops automatically in \(remaining) seconds")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Say a short sentence. If testing system audio, play sound during the test.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = appState.onboardingTestError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let result = appState.onboardingTestResult {
                OnboardingTestResultView(result: result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingTestResultView: View {
    let result: OnboardingTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup test result")
                .font(.headline)
            OnboardingTestTrackResultRow(title: "System audio", result: result.systemAudio)
            OnboardingTestTrackResultRow(title: "Microphone", result: result.microphone)
            transcriptionRow
            outputRow
            if let error = result.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(result.sessionDirectoryURL.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var transcriptionRow: some View {
        if let status = result.transcriptionStatus {
            switch status {
            case .completed:
                Label("Transcription completed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .modelMissing:
                Label("Transcription not verified — model missing", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Transcription not run", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var outputRow: some View {
        if let markdownURL = result.markdownURL {
            Label("Markdown exported", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(markdownURL.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct OnboardingTestTrackResultRow: View {
    let title: String
    let result: OnboardingTestTrackResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(title, systemImage: result.bufferCount > 0 ? "waveform" : "waveform.slash")
                    .font(.caption.weight(.semibold))
                Spacer()
                summaryLabel
            }
            HStack(spacing: 8) {
                Text("Buffers: \(result.bufferCount)")
                Text("Frames: \(result.totalFrames)")
                if let duration = result.capturedDurationSeconds {
                    Text("Duration: \(duration.formatted(.number.precision(.fractionLength(1))))s")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summaryLabel: some View {
        Group {
            if let failureReason = result.failureReason {
                Text("Failed: \(failureReason)")
            } else if result.bufferCount == 0 {
                Text("No buffers received")
            } else if result.activityDetected {
                Text("Buffers received · audio activity detected")
            } else {
                Text("Buffers received · no audio activity detected")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
