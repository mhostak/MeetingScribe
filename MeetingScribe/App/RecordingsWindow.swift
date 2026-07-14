import AppKit
import SwiftUI

struct RecordingsWindow: View {
    @ObservedObject var appState: AppState
    @StateObject private var model: RecordingsWindowModel

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.entriesForSelectedDate) { entry in
                            RecordingSessionRow(
                                entry: entry,
                                liveStatus: liveStatus(for: entry)
                            )
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            }

            if !model.snapshot.issues.isEmpty {
                issuesFooter
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .environment(\.locale, appState.selectedAppLanguage.locale)
        .task { await model.reload() }
        .onChange(of: appState.status) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: appState.lastCompletedSession?.metadata.id) { _, _ in
            Task { await model.reload() }
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

    private let obsidianService = ObsidianService()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.session.metadata.title)
                    .font(.headline)
                Text(timeAndDuration)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 8) {
                statusBadge
                HStack(spacing: 6) {
                    ArtifactBadge(title: "Audio", state: entry.audio)
                    ArtifactBadge(title: "Transcript", state: entry.transcript)
                    ArtifactBadge(title: "Markdown", state: entry.markdown)
                }
                actionMenu
            }
        }
        .padding(.vertical, 14)
        .contextMenu { actionItems }
    }

    private var timeAndDuration: String {
        let time = entry.occurredAt.formatted(date: .omitted, time: .shortened)
        guard let duration = entry.duration else { return time }
        return "\(time) · \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))"
    }

    private var statusBadge: some View {
        Text(statusTitle)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(statusColor)
            .background(statusColor.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var actionMenu: some View {
        Menu {
            actionItems
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var actionItems: some View {
        Button("Show session in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.session.manifestURL])
        }

        if case let .available(markdownURL) = entry.markdown {
            Button("Open Markdown") {
                NSWorkspace.shared.open(markdownURL)
            }
            if let obsidianURL = obsidianService.openURL(for: markdownURL) {
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

    private var help: String {
        switch state {
        case .available: return "Available"
        case .missing: return "Expected file is missing"
        case .notProduced: return "Not produced"
        }
    }
}
