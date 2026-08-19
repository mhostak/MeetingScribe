import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var pendingAudioRetentionPolicy: AudioRetentionPolicy?
    @State private var isShowingLegacyModelDeletionWarning = false

    var body: some View {
        TabView(selection: $appState.selectedSettingsSection) {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")

            transcriptionSettings
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag("transcription")

            aiSettings
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag("ai")

            outputSettings
                .tabItem { Label("Output", systemImage: "doc.text") }
                .tag("output")

            calendarSettings
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag("calendar")

            advancedSettings
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag("advanced")
        }
        .padding(20)
        .frame(width: 680, height: 500)
        .environment(\.locale, appState.selectedAppLanguage.locale)
        .confirmationDialog(
            "Enable automatic recording audio deletion?",
            isPresented: Binding(
                get: { pendingAudioRetentionPolicy != nil },
                set: { if !$0 { pendingAudioRetentionPolicy = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Enable automatic audio deletion", role: .destructive) {
                guard let policy = pendingAudioRetentionPolicy else { return }
                pendingAudioRetentionPolicy = nil
                Task { await appState.setAudioRetentionPolicy(policy) }
            }
            Button("Cancel", role: .cancel) { pendingAudioRetentionPolicy = nil }
        } message: {
            Text("Transcript and Markdown will stay available, but repeat transcription and speaker editing require the original audio. Failed, incomplete, and protected recordings are never deleted.")
        }
        .confirmationDialog(
            "Remove unused legacy models?",
            isPresented: $isShowingLegacyModelDeletionWarning,
            titleVisibility: .visible
        ) {
            Button("Remove unused legacy models", role: .destructive) {
                appState.removeLegacyModels()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only old model files. Existing recordings, transcripts, and Markdown are not changed.")
        }
    }

    private var generalSettings: some View {
        settingsForm {
            Section("Application") {
                Picker("Application language", selection: $appState.selectedAppLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }
                .onChange(of: appState.selectedAppLanguage) { persistApplicationSettings() }

                Text("Controls the app interface, status messages, errors, notifications, and permission guidance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Launch MeetingScribe at login", isOn: Binding(
                    get: { appState.launchAtLoginEnabled },
                    set: { enabled in
                        Task { await appState.setLaunchAtLoginEnabled(enabled) }
                    }
                ))
            }

            Section("Languages") {
                Picker("Transcription language", selection: $appState.selectedTranscriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }
                .onChange(of: appState.selectedTranscriptionLanguage) {
                    appState.persistTranscriptionLanguageSelection()
                }

                Text("Controls the language expected in the recorded audio. Auto is best for mixed-language meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Output language", selection: $appState.selectedOutputLanguage) {
                    ForEach(OutputLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }
                .onChange(of: appState.selectedOutputLanguage) { persistApplicationSettings() }

                Text("Controls the language of the Markdown summary and action items. It does not change transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!appState.canEditSessionConfiguration)
        }
    }

    private var transcriptionSettings: some View {
        settingsForm {
            Section("FluidAudio") {
                Text("MeetingScribe uses a pinned FluidAudio model bundle for local transcription. The model is downloaded only when you request it and is verified before installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription model") {
                fluidAudioModelControls(
                    descriptor: appState.fluidAudioASRDescriptor,
                    status: appState.fluidAudioASRModelStatus,
                    progress: appState.fluidAudioASRDownloadProgress,
                    isInstalling: appState.isInstallingFluidAudioASRModel,
                    kind: .transcription
                )
            }

            Section("Storage and attribution") {
                LabeledContent("Download size") {
                    Text(verbatim: ByteCountFormatter.string(
                        fromByteCount: appState.fluidAudioASRDescriptor.approximateSizeBytes,
                        countStyle: .file
                    ))
                }
                Text("Finalized audio and inference stay on this Mac. Network access is used only for an explicit model installation or repair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Legacy model files from older versions are not used and are never removed automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.legacyModelCleanupReport.fileCount > 0 {
                    Button(role: .destructive) {
                        isShowingLegacyModelDeletionWarning = true
                    } label: {
                        Label(
                            "Remove unused legacy models (\(ByteCountFormatter.string(fromByteCount: appState.legacyModelCleanupReport.totalBytes, countStyle: .file)))",
                            systemImage: "trash"
                        )
                    }
                    .disabled(appState.isRemovingLegacyModels)
                }
            }
        }
        .disabled(!appState.canEditSessionConfiguration)
        .task {
            await appState.refreshFluidAudioModelStatuses()
            appState.refreshLegacyModelCleanupReport()
        }
    }

    private var aiSettings: some View {
        settingsForm {
            Section("Meeting analysis") {
                Toggle("Analyze completed meetings", isOn: $appState.aiAnalysisEnabled)
                    .onChange(of: appState.aiAnalysisEnabled) {
                        appState.analysisEnabledDidChange()
                    }

                Picker("Tool", selection: $appState.selectedAnalysisTool) {
                    ForEach(AnalysisTool.allCases) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .disabled(!appState.aiAnalysisEnabled)
                .onChange(of: appState.selectedAnalysisTool) {
                    appState.analysisToolSelectionDidChange()
                }

                TextField("Executable", text: $appState.analysisExecutablePath)
                    .disabled(!appState.aiAnalysisEnabled)
                    .onSubmit { appState.analysisExecutablePathDidChange() }

                HStack {
                    Button("Choose executable…") { appState.chooseAnalysisExecutable() }
                    Button("Auto-detect") { appState.useDetectedAnalysisExecutable() }
                    Button("Verify tool") {
                        Task { await appState.refreshAnalysisToolStatus() }
                    }
                    .disabled(appState.isCheckingAnalysisTool)
                }
                .disabled(!appState.aiAnalysisEnabled)

                Label(analysisToolStatusText, systemImage: analysisToolStatusIcon)
                    .foregroundStyle(analysisToolStatusColor)

                if case let .authenticationRequired(_, _, loginCommand) =
                    appState.analysisToolStatus {
                    Text("Sign in with the selected tool in Terminal, then verify it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: loginCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("Copy command and open Terminal") {
                        appState.copyAnalysisLoginCommandAndOpenTerminal()
                    }
                    .disabled(!appState.aiAnalysisEnabled)
                }

                Picker("Model", selection: $appState.selectedAnalysisModel) {
                    ForEach(appState.analysisModelOptions) { selection in
                        Text(LocalizedStringKey(selection.titleLocalizationKey))
                            .tag(selection)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!appState.aiAnalysisEnabled)
                .onChange(of: appState.selectedAnalysisModel) {
                    appState.persistAnalysisSettings()
                }

                if appState.selectedAnalysisModel == .custom {
                    TextField("Model identifier", text: $appState.customAnalysisModel)
                        .disabled(!appState.aiAnalysisEnabled)
                        .onChange(of: appState.customAnalysisModel) {
                            appState.persistAnalysisSettings()
                        }
                }

                Text(LocalizedStringKey(appState.selectedAnalysisModel.detailLocalizationKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!appState.aiAnalysisEnabled)

                if appState.selectedAnalysisModel == .custom,
                   appState.resolvedAnalysisModel == nil {
                    Label(
                        "Enter a model identifier. Until then, the tool default will be used.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Analysis prompt") {
                TextEditor(text: $appState.analysisPrompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 260)
                    .disabled(!appState.aiAnalysisEnabled)
                    .onChange(of: appState.analysisPrompt) {
                        appState.persistAnalysisSettings()
                    }

                HStack {
                    Button("Restore default prompt") { appState.resetAnalysisPrompt() }
                    Spacer()
                    Text("Variables: {{output_language}}, {{meeting_title}}, {{recording_id}}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Audio stays local. The transcript and selected meeting metadata may be sent to the provider used by the selected CLI tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!appState.canEditSessionConfiguration)
    }

    private var outputSettings: some View {
        settingsForm {
            Section("Markdown destination") {
                LabeledContent("Folder") {
                    Text(LocalizedStringKey(appState.outputFolderDescription))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose folder…") { appState.chooseOutputFolder() }
                    if appState.outputFolderURL != nil {
                        Button("Use session folder") { appState.useDefaultOutputFolder() }
                    }
                }

                Button("Open recordings folder") { appState.openRecordingsFolder() }
            }

            Section("Document") {
                TextField("File name template", text: $appState.markdownFileNameTemplate)
                    .onChange(of: appState.markdownFileNameTemplate) { persistApplicationSettings() }

                Text("Available tokens: {date}, {time}, {title}, {id}")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !unsupportedMarkdownTokens.isEmpty {
                    Label {
                        Text("Unsupported token:")
                            + Text(verbatim: " \(unsupportedMarkdownTokens.joined(separator: ", "))")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(!appState.canEditSessionConfiguration)
    }

    private var calendarSettings: some View {
        settingsForm {
            Section("Apple Calendar") {
                Toggle("Enable Apple Calendar integration", isOn: Binding(
                    get: { appState.calendarIntegrationEnabled },
                    set: { appState.setCalendarIntegrationEnabled($0) }
                ))

                Text("MeetingScribe never reads Calendar until you enable this integration. Each event and participant selection must also be confirmed for the individual meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.calendarIntegrationEnabled {
                Section("Permission") {
                    LabeledContent("Status") {
                        Text(LocalizedStringKey(appState.calendarAuthorizationStatus.displayName))
                    }

                    switch appState.calendarAuthorizationStatus {
                    case .notDetermined:
                        HStack {
                            Button("Request Calendar access") {
                                Task { await appState.requestCalendarAccess() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(appState.isRequestingCalendarAccess)

                            if appState.isRequestingCalendarAccess {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    case .denied, .restricted, .writeOnly:
                        Button("Open System Settings") {
                            appState.openCalendarPrivacySettings()
                        }
                    case .fullAccess:
                        Label("MeetingScribe can read calendar events.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    if let calendarAccessError = appState.calendarAccessError {
                        Label(calendarAccessError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Full access is used only to offer nearby event titles, times, and invitee display names. Email addresses, locations, notes, links, calendar names, and Apple event identifiers are not saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Saved meetings") {
                Text("Turning this integration off stops future Calendar reads. Confirmed snapshots already stored with recordings are preserved so their Markdown output remains reproducible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { appState.refreshCalendarAuthorizationStatus() }
    }

    private var advancedSettings: some View {
        settingsForm {
            Section("Recording safety") {
                Stepper(value: Binding(
                    get: { max(Int(appState.minimumStorageBytes / 1_073_741_824), 1) },
                    set: { gigabytes in
                        appState.minimumStorageBytes = Int64(gigabytes) * 1_073_741_824
                        persistApplicationSettings()
                    }
                ), in: 1...100) {
                    LabeledContent("Minimum free storage") {
                        Text(ByteCountFormatter.string(
                            fromByteCount: appState.minimumStorageBytes,
                            countStyle: .file
                        ))
                    }
                }

                Picker("Recording audio retention", selection: Binding(
                    get: { appState.audioRetentionPolicy },
                    set: { policy in
                        if policy == .keepForever {
                            Task { await appState.setAudioRetentionPolicy(policy) }
                        } else {
                            pendingAudioRetentionPolicy = policy
                        }
                    }
                )) {
                    ForEach(AudioRetentionPolicy.allCases) { policy in
                        Text(LocalizedStringKey(policy.displayName)).tag(policy)
                    }
                }

                Text("Automatic deletion applies only after successful transcription and Markdown export. Use Keep audio on an individual recording to exempt it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!appState.canEditSessionConfiguration)

            Section("Diagnostics") {
                Button("Reveal last session manifest") { appState.revealLastSession() }
                    .disabled(appState.currentSession == nil && appState.lastCompletedSession == nil)
                Button("Reveal processing log") { appState.revealLastProcessingLog() }
                    .disabled(appState.currentSession == nil && appState.lastCompletedSession == nil)
                if appState.status == .completed || appState.status == .failed {
                    Button("Reset application status") { appState.reset() }
                }
            }
        }
    }

    private func settingsForm<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            if !appState.canEditSessionConfiguration {
                Section {
                    Label(
                        "Session settings are locked while recording or processing.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            content()
        }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }

    private func persistApplicationSettings() {
        Task { await appState.persistApplicationSettings() }
    }

    @ViewBuilder
    private func fluidAudioModelControls(
        descriptor: FluidAudioModelDescriptor,
        status: FluidAudioModelStatus,
        progress: FluidAudioModelDownloadProgress?,
        isInstalling: Bool,
        kind: FluidAudioModelKind
    ) -> some View {
        LabeledContent("Model") {
            Text(verbatim: descriptor.displayName)
        }

        LabeledContent("Status") {
            Label {
                fluidAudioModelStatusLabel(status)
            } icon: {
                Image(systemName: fluidAudioModelIcon(status))
            }
            .foregroundStyle(fluidAudioModelColor(status))
        }

        if let progress {
            ProgressView(value: progress.fractionCompleted) {
                Text("Installing")
                    + Text(verbatim: " \(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))")
            } currentValueLabel: {
                Text(verbatim:
                    "\(ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        HStack {
            if isInstalling {
                Button("Cancel", role: .cancel) {
                    appState.cancelFluidAudioModelInstallation(kind)
                }
            } else {
                switch status {
                case .ready:
                    Button("Verify and repair") {
                        appState.installFluidAudioModel(kind, repair: true)
                    }
                    Button("Import verified folder…") {
                        Task { await appState.importFluidAudioModel(kind) }
                    }
                    Button("Delete model", role: .destructive) {
                        Task { await appState.deleteFluidAudioModel(kind) }
                    }
                case .missing:
                    Button {
                        appState.installFluidAudioModel(kind)
                    } label: {
                        Text("Download")
                            + Text(verbatim: " (\(modelSize(descriptor)))")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Import verified folder…") {
                        Task { await appState.importFluidAudioModel(kind) }
                    }
                case .invalid:
                    Button("Repair") {
                        appState.installFluidAudioModel(kind, repair: true)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Import verified folder…") {
                        Task { await appState.importFluidAudioModel(kind) }
                    }
                    Button("Delete invalid model", role: .destructive) {
                        Task { await appState.deleteFluidAudioModel(kind) }
                    }
                }
            }
        }

        HStack(spacing: 12) {
            Link("Model source", destination: descriptor.sourceURL)
            Text(verbatim: descriptor.licenseName)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func fluidAudioModelStatusLabel(_ status: FluidAudioModelStatus) -> some View {
        switch status {
        case .missing:
            Text("Missing")
        case let .ready(_, sizeBytes):
            Text("Ready")
                + Text(verbatim: " (\(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)))")
        case let .invalid(reason):
            Text("Invalid")
                + Text(verbatim: ": \(reason)")
        }
    }

    private func fluidAudioModelIcon(_ status: FluidAudioModelStatus) -> String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .invalid: return "exclamationmark.triangle.fill"
        case .missing: return "arrow.down.circle"
        }
    }

    private func fluidAudioModelColor(_ status: FluidAudioModelStatus) -> Color {
        switch status {
        case .ready: return .green
        case .invalid: return .orange
        case .missing: return .secondary
        }
    }

    private func modelSize(_ descriptor: FluidAudioModelDescriptor) -> String {
        ByteCountFormatter.string(
            fromByteCount: descriptor.approximateSizeBytes,
            countStyle: .file
        )
    }

    private var analysisToolStatusText: String {
        switch appState.analysisToolStatus {
        case .unknown: return String(localized: "Availability has not been checked")
        case .unavailable: return String(localized: "Executable not found")
        case let .available(path, version):
            return [version, path].compactMap { $0 }.joined(separator: " — ")
        case let .authenticationRequired(path, version, _):
            let toolDescription = [version, path].compactMap { $0 }.joined(separator: " — ")
            return "\(String(localized: "Authentication required")) — \(toolDescription)"
        case let .failed(path, reason): return "\(path) — \(reason)"
        }
    }

    private var analysisToolStatusIcon: String {
        switch appState.analysisToolStatus {
        case .available: return "checkmark.circle.fill"
        case .authenticationRequired: return "person.crop.circle.badge.exclamationmark"
        case .failed, .unavailable: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var analysisToolStatusColor: Color {
        switch appState.analysisToolStatus {
        case .available: return .green
        case .authenticationRequired, .failed, .unavailable: return .orange
        case .unknown: return .secondary
        }
    }

    private var unsupportedMarkdownTokens: [String] {
        MarkdownFileNameTemplate.unsupportedTokens(in: appState.markdownFileNameTemplate)
    }
}
