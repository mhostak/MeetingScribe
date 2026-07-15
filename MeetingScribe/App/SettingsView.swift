import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var isShowingCAFDeletionWarning = false
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
            "Delete original CAF recordings after successful processing?",
            isPresented: $isShowingCAFDeletionWarning,
            titleVisibility: .visible
        ) {
            Button("Enable automatic CAF deletion", role: .destructive) {
                appState.automaticallyDeleteSourceCAF = true
                appState.persistAudioRetentionSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Failed or incomplete sessions always keep their source audio.")
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
                Text("MeetingScribe uses pinned FluidAudio model bundles for local transcription and speaker diarization. Models are downloaded only when you request them and are verified before installation.")
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

            Section("Speaker diarization model") {
                fluidAudioModelControls(
                    descriptor: appState.fluidAudioDiarizationDescriptor,
                    status: appState.fluidAudioDiarizationModelStatus,
                    progress: appState.fluidAudioDiarizationDownloadProgress,
                    isInstalling: appState.isInstallingFluidAudioDiarizationModel,
                    kind: .diarization
                )
            }

            Section("Storage and attribution") {
                LabeledContent("Combined download size") {
                    Text(verbatim: ByteCountFormatter.string(
                        fromByteCount: fluidAudioCombinedSize,
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
                Toggle("Create AI summary and action items", isOn: $appState.aiAnalysisEnabled)
                    .onChange(of: appState.aiAnalysisEnabled) { appState.persistAnalysisSettings() }

                Picker("OpenAI model", selection: $appState.selectedOpenAIModel) {
                    ForEach(OpenAIModelDescriptor.supported) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .disabled(!appState.aiAnalysisEnabled)
                .onChange(of: appState.selectedOpenAIModel) { appState.persistAnalysisSettings() }
            }

            Section("API key") {
                Label {
                    if appState.hasOpenAIAPIKey {
                        Text("Stored in Keychain")
                    } else {
                        Text("API key is missing")
                    }
                } icon: {
                    Image(systemName: appState.hasOpenAIAPIKey ? "checkmark.circle.fill" : "key.slash")
                }
                .foregroundStyle(appState.hasOpenAIAPIKey ? .green : .orange)

                SecureField("OpenAI API key", text: $appState.openAIAPIKeyInput)

                HStack {
                    if appState.hasOpenAIAPIKey {
                        Button("Replace key") {
                            Task { await appState.saveOpenAIAPIKey() }
                        }
                        .disabled(cannotSaveOpenAIAPIKey)
                    } else {
                        Button("Save key") {
                            Task { await appState.saveOpenAIAPIKey() }
                        }
                        .disabled(cannotSaveOpenAIAPIKey)
                    }

                    if appState.hasOpenAIAPIKey {
                        Button("Delete key", role: .destructive) {
                            Task { await appState.deleteOpenAIAPIKey() }
                        }
                    }
                }

                Text("Only transcript text and meeting metadata are sent to OpenAI. Audio stays local.")
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

                Toggle("Delete legacy CAF after successful export", isOn: Binding(
                    get: { appState.automaticallyDeleteSourceCAF },
                    set: { enabled in
                        if enabled {
                            isShowingCAFDeletionWarning = true
                        } else {
                            appState.automaticallyDeleteSourceCAF = false
                            appState.persistAudioRetentionSettings()
                        }
                    }
                ))
                Text("This applies only after successful transcription and Markdown export.")
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

    private var fluidAudioCombinedSize: Int64 {
        appState.fluidAudioASRDescriptor.approximateSizeBytes
            + appState.fluidAudioDiarizationDescriptor.approximateSizeBytes
    }

    private var cannotSaveOpenAIAPIKey: Bool {
        appState.isSavingOpenAIAPIKey
            || appState.openAIAPIKeyInput
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unsupportedMarkdownTokens: [String] {
        MarkdownFileNameTemplate.unsupportedTokens(in: appState.markdownFileNameTemplate)
    }
}
