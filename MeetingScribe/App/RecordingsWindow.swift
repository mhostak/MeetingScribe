import AppKit
import SwiftUI

struct RecordingsWindow: View {
    @ObservedObject var appState: AppState
    @StateObject private var model: RecordingsWindowModel
    @State private var focusedSessionID: String?

    init(appState: AppState) {
        self.appState = appState
        _model = StateObject(wrappedValue: RecordingsWindowModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
                .padding()

            Divider()

            if let loadError = model.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding()
            }

            if model.isLoading && model.snapshot.entries.isEmpty {
                ProgressView("Loading recordings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entriesForSelectedDate.isEmpty {
                ContentUnavailableView(
                    "No recordings for this day",
                    systemImage: "calendar",
                    description: Text("Choose another day to browse saved recordings and transcripts.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.entriesForSelectedDate) { entry in
                                RecordingSessionRow(
                                    entry: entry,
                                    liveStatus: liveStatus(for: entry),
                                    isFocused: entry.id == focusedSessionID,
                                    appState: appState,
                                    reload: { await model.reload() }
                                )
                                .id(entry.id)
                            }
                        }
                        .padding()
                    }
                    .task(id: focusedSessionID) {
                        guard let focusedSessionID else { return }
                        await Task.yield()
                        withAnimation {
                            proxy.scrollTo(focusedSessionID, anchor: .center)
                        }
                    }
                }
            }

            if !model.snapshot.issues.isEmpty {
                issuesFooter
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .environment(\.locale, appState.selectedAppLanguage.locale)
        .task {
            if let request = appState.recordingsNavigationRequest {
                await focus(request)
            } else {
                await model.reload()
            }
        }
        .onChange(of: appState.status) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: appState.lastCompletedSession?.metadata.id) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: appState.recordingsNavigationRequest) { _, request in
            guard let request else { return }
            Task { await focus(request) }
        }
        .onChange(of: model.selectedDate) { _, _ in
            focusedSessionID = nil
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button(action: model.previousDay) {
                Label("Previous day", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Previous day")

            DatePicker("Date", selection: $model.selectedDate, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()

            Button(action: model.nextDay) {
                Label("Next day", systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Next day")

            Button("Today", action: model.goToToday)

            Spacer()

            Button {
                Task { await model.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
        }
    }

    private func liveStatus(for entry: SessionCatalogEntry) -> AppStatus? {
        guard entry.id == appState.currentSession?.metadata.id else { return nil }
        return appState.status
    }

    private func focus(_ request: RecordingsNavigationRequest) async {
        model.selectDate(containing: request.occurredAt)
        await model.reload()
        guard model.entriesForSelectedDate.contains(where: { $0.id == request.sessionID }) else {
            return
        }
        focusedSessionID = request.sessionID
    }

    private var issuesFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Some session folders could not be read.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ForEach(model.snapshot.issues) { issue in
                Text("\(issue.directoryName): \(issue.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4))
    }
}

private struct RecordingSessionRow: View {
    let entry: SessionCatalogEntry
    let liveStatus: AppStatus?
    let isFocused: Bool
    @ObservedObject var appState: AppState
    let reload: () async -> Void
    @State private var reprocessingError: String?

    private let obsidianService = ObsidianService()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.session.metadata.title)
                    .font(.headline)

                Spacer(minLength: 12)

                statusBadge
            }

            HStack(spacing: 16) {
                Label(timeText, systemImage: "clock")

                if let durationText {
                    Label(durationText, systemImage: "timer")
                }

                if let segmentCount = entry.session.metadata.transcription?.mergedSegmentCount {
                    Label {
                        Text(verbatim: "\(segmentCount) ") + Text("segments")
                    } icon: {
                        Image(systemName: "text.bubble")
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let markdownFileName {
                Label(markdownFileName, systemImage: "doc.text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reprocessingError {
                Label(reprocessingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                ArtifactBadge(title: "Audio", state: entry.audio)
                ArtifactBadge(title: "Transcript", state: entry.transcript)
                ArtifactBadge(title: "Markdown", state: entry.markdown)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    if let obsidianURL {
                        NSWorkspace.shared.open(obsidianURL)
                    }
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(obsidianURL == nil)

                Button {
                    if let markdownURL {
                        NSWorkspace.shared.open(markdownURL)
                    }
                } label: {
                    Label("Open Markdown", systemImage: "doc.text")
                }
                .disabled(markdownURL == nil)

                Button {
                    Task {
                        do {
                            reprocessingError = nil
                            let result = try await appState.reprocessWithFluidAudio(
                                session: entry.session
                            )
                            await reload()
                            NSWorkspace.shared.activateFileViewerSelecting([
                                result.directoryURL
                            ])
                        } catch {
                            reprocessingError = error.localizedDescription
                        }
                    }
                } label: {
                    if appState.fluidAudioReprocessingSessionID == entry.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Reprocess with FluidAudio", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(
                    appState.status == .recording
                        || appState.status.isProcessing
                        || appState.fluidAudioReprocessingSessionID != nil
                        || entry.session.metadata.audioFinalization == nil
                )

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([finderTarget])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(
            isFocused ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
        .contextMenu { actionItems }
    }

    private var timeText: String {
        entry.occurredAt.formatted(date: .omitted, time: .shortened)
    }

    private var durationText: String? {
        guard let duration = entry.duration else { return nil }
        let elapsed = max(0, Int(duration))
        return String(
            format: "%02d:%02d:%02d",
            elapsed / 3_600,
            (elapsed % 3_600) / 60,
            elapsed % 60
        )
    }

    private var statusBadge: some View {
        Text(LocalizedStringKey(statusTitle))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(statusColor)
            .background(statusColor.opacity(0.14), in: Capsule())
    }

    private var markdownURL: URL? {
        guard case let .available(url) = entry.markdown else { return nil }
        return url
    }

    private var obsidianURL: URL? {
        markdownURL.flatMap(obsidianService.openURL(for:))
    }

    private var markdownFileName: String? {
        markdownURL?.lastPathComponent ?? entry.session.metadata.output?.markdownFileName
    }

    private var finderTarget: URL {
        markdownURL ?? entry.session.manifestURL
    }

    @ViewBuilder
    private var actionItems: some View {
        Button("Show session in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.session.manifestURL])
        }

        if let markdownURL {
            Button("Open Markdown") {
                NSWorkspace.shared.open(markdownURL)
            }
            if let obsidianURL {
                Button("Open in Obsidian") {
                    NSWorkspace.shared.open(obsidianURL)
                }
            }
        }

    }

    private var statusTitle: String {
        if let liveStatus {
            return liveStatus.displayName
        }
        switch entry.status {
        case .completed: return "Completed"
        case .transcriptReady: return "Transcript ready"
        case .needsModel: return "Model required"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .incomplete: return "Incomplete"
        }
    }

    private var message: String? {
        if let liveStatus, liveStatus == .recording || liveStatus.isProcessing {
            return nil
        }
        return entry.message
    }

    private var statusColor: Color {
        if let liveStatus {
            if liveStatus == .recording { return .red }
            if liveStatus.isProcessing { return .blue }
            if liveStatus == .failed { return .red }
        }
        switch entry.status {
        case .completed: return .green
        case .transcriptReady, .needsModel, .incomplete: return .orange
        case .failed, .interrupted: return .red
        }
    }
}

private struct ArtifactBadge: View {
    let title: LocalizedStringKey
    let state: SessionArtifactState

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: image)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .help(help)
    }

    private var image: String {
        switch state {
        case .available: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.triangle.fill"
        case .notProduced: return "minus.circle"
        }
    }

    private var color: Color {
        switch state {
        case .available: return .green
        case .missing: return .orange
        case .notProduced: return .secondary
        }
    }

    private var help: LocalizedStringKey {
        switch state {
        case .available: return "Available"
        case .missing: return "Expected file is missing"
        case .notProduced: return "Not produced"
        }
    }
}
