import AppKit
import SwiftUI

struct RecordingsWindow: View {
    @ObservedObject var appState: AppState
    @StateObject private var model: RecordingsWindowModel
    @State private var focusedSessionID: String?
    @State private var isShowingStorageManager = false

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
        .onChange(of: appState.processingJobs) { _, _ in
            Task { await model.reload() }
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
        .sheet(isPresented: $isShowingStorageManager) {
            RecordingAudioStorageView(
                appState: appState,
                reload: { await model.reload() }
            )
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
                isShowingStorageManager = true
                Task { await appState.refreshRecordingAudioCleanupPlan() }
            } label: {
                Label("Manage storage", systemImage: "internaldrive")
            }

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

private struct RecordingAudioStorageView: View {
    @ObservedObject var appState: AppState
    let reload: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingDeletionConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Recording storage", systemImage: "internaldrive")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            if appState.isScanningRecordingAudio,
               appState.recordingAudioCleanupPlan.generatedAt == .distantPast {
                ProgressView("Scanning recordings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        Text("Stored recording audio")
                        Text(byteCount(appState.recordingAudioCleanupPlan.totalAudioBytes))
                            .fontWeight(.semibold)
                    }
                    GridRow {
                        Text("Can be removed now")
                        Text(byteCount(appState.recordingAudioCleanupPlan.reclaimableBytes))
                            .fontWeight(.semibold)
                    }
                    GridRow {
                        Text("Eligible recordings")
                        Text(verbatim: "\(appState.recordingAudioCleanupPlan.candidates.count)")
                    }
                    if appState.recordingAudioCleanupPlan.keptSessionCount > 0 {
                        GridRow {
                            Text("Protected recordings")
                            Text(verbatim: "\(appState.recordingAudioCleanupPlan.keptSessionCount)")
                        }
                    }
                }

                Label(
                    "Transcript and Markdown remain available. Repeat transcription and speaker editing will no longer be possible for cleaned recordings.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                if let report = appState.recordingAudioCleanupReport,
                   report.reclaimedBytes > 0 {
                    Label(
                        "Last cleanup freed \(byteCount(report.reclaimedBytes)) from \(report.cleanedSessionIDs.count) recordings.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }

                if let error = appState.recordingAudioCleanupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        Task { await appState.refreshRecordingAudioCleanupPlan() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        appState.isScanningRecordingAudio
                            || appState.isCleaningRecordingAudio
                    )

                    Spacer()

                    Button(role: .destructive) {
                        isShowingDeletionConfirmation = true
                    } label: {
                        if appState.isCleaningRecordingAudio {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Remove processed audio…", systemImage: "trash")
                        }
                    }
                    .disabled(
                        appState.recordingAudioCleanupPlan.reclaimableBytes == 0
                            || appState.isScanningRecordingAudio
                            || appState.isCleaningRecordingAudio
                            || appState.fluidAudioReprocessingSessionID != nil
                            || appState.aiAnalysisReprocessingSessionID != nil
                            || appState.status == .recording
                            || appState.status.isProcessing
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 330)
        .confirmationDialog(
            "Permanently remove processed recording audio?",
            isPresented: $isShowingDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove audio permanently", role: .destructive) {
                Task {
                    await appState.cleanProcessedRecordingAudio()
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \(byteCount(appState.recordingAudioCleanupPlan.reclaimableBytes)) from \(appState.recordingAudioCleanupPlan.candidates.count) processed recordings. This cannot be undone.")
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                if processingJob?.state == .failed {
                    Button("Retry") { Task { await appState.retryProcessing(entry.session) } }
                        .disabled(!appState.canEnqueueProcessing(sessionID: entry.id))
                } else if isHeldByPausedQueue {
                    // A held job has no Retry, so this is the only control that
                    // can get it moving from the recordings overview.
                    Button("Resume processing") { Task { await appState.resumeProcessing() } }
                        .disabled(!appState.canResumeProcessing)
                }
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
                    .textSelection(.enabled)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reprocessingError {
                Label(reprocessingError, systemImage: "exclamationmark.triangle.fill")
                    .textSelection(.enabled)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                ArtifactBadge(title: "Audio", state: entry.audio)
                ArtifactBadge(title: "Transcript", state: entry.transcript)
                ArtifactBadge(title: "Markdown", state: entry.markdown)
                if entry.session.metadata.keepsRecordingAudio {
                    Label("Audio kept", systemImage: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
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
                            reprocessingError = appState.errorMessage(for: error)
                        }
                    }
                } label: {
                    if appState.fluidAudioReprocessingSessionID == entry.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Repeat transcription", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(
                    !appState.canEnqueueProcessing(sessionID: entry.id)
                        || !entry.audio.isAvailable
                )

                Button {
                    toggleAudioProtection()
                } label: {
                    Image(systemName: entry.session.metadata.keepsRecordingAudio
                        ? "pin.slash"
                        : "pin")
                }
                .help(entry.session.metadata.keepsRecordingAudio
                    ? "Allow automatic audio cleanup"
                    : "Keep audio")
                .disabled(
                    !entry.audio.isAvailable
                        || !appState.canEnqueueProcessing(sessionID: entry.id)
                        || appState.isCleaningRecordingAudio
                        || appState.fluidAudioReprocessingSessionID != nil
                        || appState.aiAnalysisReprocessingSessionID != nil
                )

                Button {
                    Task {
                        do {
                            reprocessingError = nil
                            try await appState.reanalyze(session: entry.session)
                            await reload()
                        } catch {
                            reprocessingError = appState.errorMessage(for: error)
                        }
                    }
                } label: {
                    if appState.aiAnalysisReprocessingSessionID == entry.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            LocalizedStringKey(analysisActionTitle),
                            systemImage: "sparkles"
                        )
                    }
                }
                .disabled(
                    !appState.canEnqueueProcessing(sessionID: entry.id)
                        || !entry.transcript.isAvailable
                        || !entry.markdown.isAvailable
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

    private var analysisActionTitle: String {
        entry.hasAnalysis ? "Repeat AI analysis" : "AI analysis"
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

        if entry.audio.isAvailable {
            Button(entry.session.metadata.keepsRecordingAudio
                ? "Allow audio cleanup"
                : "Keep audio") {
                toggleAudioProtection()
            }
        }

    }

    private func toggleAudioProtection() {
        Task {
            do {
                reprocessingError = nil
                try await appState.setKeepRecordingAudio(
                    !entry.session.metadata.keepsRecordingAudio,
                    for: entry.session
                )
                await reload()
            } catch {
                reprocessingError = appState.errorMessage(for: error)
            }
        }
    }

    private var processingJob: ProcessingJob? {
        appState.processingJobs.first { $0.metadata.id == entry.id }?.metadata.processing
            ?? entry.session.metadata.processing
    }

    private var isHeldByPausedQueue: Bool {
        guard appState.processingQueueStatus.isPaused, let state = processingJob?.state else {
            return false
        }
        return state == .queued || state == .paused
    }

    private var statusTitle: String {
        if let job = processingJob {
            return job.statusLabel(queueStatus: appState.processingQueueStatus)
        }
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
        if let job = processingJob, job.state != .completed {
            return job.statusDetail(queueStatus: appState.processingQueueStatus)
        }
        if let liveStatus, liveStatus == .recording || liveStatus.isProcessing {
            return nil
        }
        return entry.message
    }

    private var statusColor: Color {
        if let job = processingJob {
            let isHeld = appState.processingQueueStatus.isPaused
                && (job.state == .queued || job.state == .paused)
            if isHeld { return .orange }
            switch job.state {
            case .completed: return .green
            case .failed: return .red
            case .paused, .pauseRequested: return .orange
            case .queued, .running: return .blue
            }
        }
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
            if state.isRemoved {
                Text("Audio removed")
            } else {
                Text(title)
            }
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
        case .removed: return "trash.circle.fill"
        case .notProduced: return "minus.circle"
        }
    }

    private var color: Color {
        switch state {
        case .available: return .green
        case .missing: return .orange
        case .removed: return .secondary
        case .notProduced: return .secondary
        }
    }

    private var help: LocalizedStringKey {
        switch state {
        case .available: return "Available"
        case .missing: return "Expected file is missing"
        case .removed: return "Removed to save space"
        case .notProduced: return "Not produced"
        }
    }
}
