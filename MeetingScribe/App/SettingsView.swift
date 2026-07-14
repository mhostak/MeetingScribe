import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var isShowingCAFDeletionWarning = false

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

                Text("Controls the language Whisper expects in the recorded audio. Auto is best for mixed-language meetings.")
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
            Section("Whisper") {
                Picker("Model", selection: $appState.selectedWhisperModelID) {
                    ForEach(WhisperModelDescriptor.supported) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onChange(of: appState.selectedWhisperModelID) {
                    appState.persistWhisperModelSelection()
                    Task { await appState.refreshWhisperModelStatus() }
                }

                LabeledContent("Status") {
                    Label {
                        whisperModelStatusLabel
                    } icon: {
                        Image(systemName: whisperModelIcon)
                    }
                        .foregroundStyle(whisperModelColor)
                }

                if let progress = appState.whisperModelDownloadProgress {
                    ProgressView(value: progress) {
                        Text("Downloading")
                            + Text(verbatim: " \(progress.formatted(.percent.precision(.fractionLength(0))))")
                    }
                }

                if case .ready = appState.whisperModelStatus {
                    HStack {
                        Button("Replace from file…") {
                            Task { await appState.importSelectedWhisperModel() }
                        }
                        Button("Delete model", role: .destructive) {
                            Task { await appState.deleteSelectedWhisperModel() }
                        }
                    }
                } else {
                    HStack {
                        Button {
                            Task { await appState.downloadSelectedWhisperModel() }
                        } label: {
                            downloadModelButtonLabel
                        }
                        Button("Import from file…") {
                            Task { await appState.importSelectedWhisperModel() }
                        }
                    }
                    .disabled(appState.isDownloadingWhisperModel)
                }
            }
        }
        .disabled(!appState.canEditSessionConfiguration)
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

    private var whisperModelIcon: String {
        if case .ready = appState.whisperModelStatus { return "checkmark.circle.fill" }
        return "arrow.down.circle"
    }

    private var whisperModelColor: Color {
        if case .ready = appState.whisperModelStatus { return .green }
        return .secondary
    }

    @ViewBuilder
    private var whisperModelStatusLabel: some View {
        switch appState.whisperModelStatus {
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

    @ViewBuilder
    private var downloadModelButtonLabel: some View {
        if appState.isDownloadingWhisperModel {
            Text("Downloading Whisper model…")
        } else {
            Text("Download")
                + Text(verbatim: " \(appState.selectedWhisperModel.displayName) (\(selectedWhisperModelSize))")
        }
    }

    private var selectedWhisperModelSize: String {
        let size = ByteCountFormatter.string(
            fromByteCount: appState.selectedWhisperModel.approximateSizeBytes,
            countStyle: .file
        )
        return size
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
