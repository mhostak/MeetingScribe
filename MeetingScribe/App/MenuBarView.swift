import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    /// Observed separately so typing a note redraws the editor, not the
    /// whole popover.
    @ObservedObject private var meetingNotes: MeetingNotesModel
    let openSettingsAction: () -> Void
    let openRecordingsAction: () -> Void
    let openCalendarPickerAction: () -> Void
    @AppStorage("meetingNotesDisclosureIsExpanded") private var isMeetingNotesExpanded = false
    @State private var isEditingMeetingTitle = false
    @State private var meetingTitleDraft = ""
    @State private var meetingNotesSaveState: MeetingNotesSaveState?
    @State private var meetingNotesSaveTask: Task<Void, Never>?
    @FocusState private var isMeetingTitleFocused: Bool

    init(
        appState: AppState,
        openSettingsAction: @escaping () -> Void = {},
        openRecordingsAction: @escaping () -> Void = {},
        openCalendarPickerAction: @escaping () -> Void = {}
    ) {
        self.appState = appState
        _meetingNotes = ObservedObject(wrappedValue: appState.meetingNotesModel)
        self.openSettingsAction = openSettingsAction
        self.openRecordingsAction = openRecordingsAction
        self.openCalendarPickerAction = openCalendarPickerAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            statusContent

            if let candidate = activeRecoveryCandidate {
                recoveryContent(candidate)
            } else if let issue = activeRecoveryIssue {
                recoveryIssueContent(issue)
            }

            if !visibleProcessingJobs.isEmpty {
                Divider()
                processingQueueContent
            }

            if let lastError = appState.lastError, appState.status != .failed {
                messageBanner(lastError, color: .orange, icon: "exclamationmark.triangle.fill")
            }

            footer
        }
        .padding(18)
        .frame(width: 360)
        .environment(\.locale, appState.selectedAppLanguage.locale)
        .onChange(of: appState.currentSession?.metadata.id) {
            cancelMeetingTitleEditing()
            meetingNotesSaveTask?.cancel()
            meetingNotesSaveState = nil
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch appState.status {
        case .idle:
            readyContent
        case .recording:
            recordingContent
        case .completed:
            completedContent
        case .failed:
            failedContent
            if appState.currentSession != nil {
                Button("Retry saving recording") { Task { await appState.stopRecording() } }
            }
        case .preparing, .stopping, .transcribing, .analyzing, .exporting:
            processingContent
        }
    }

    private var visibleProcessingJobs: [RecordingSession] {
        appState.processingJobs.filter { $0.metadata.processing?.state != .completed }
    }

    private var processingQueueContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("Processing queue").font(.headline)
                Text(verbatim: "\(visibleProcessingJobs.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(Text("Queued recordings"))
                Spacer()
            }
            if let reason = appState.processingPauseReason {
                pausedBanner(reason)
            }
            ForEach(Array(visibleProcessingJobs.prefix(3)), id: \.metadata.id) { session in
                processingQueueRow(session)
            }
        }
    }

    /// The whole row opens the recording in the overview, so the queue needs no
    /// button of its own beside the one already in the footer.
    private func processingQueueRow(_ session: RecordingSession) -> some View {
        let job = session.metadata.processing
        let progress = job?.stageProgress(
            analysisConfigured: session.metadata.analysisConfiguration != nil
        )
        return HStack(spacing: 8) {
            Button {
                appState.requestRecordingsOverview(for: session)
                openRecordingsAction()
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.metadata.title).lineLimit(1)
                        if let progress, progress.isInFlight {
                            processingStageBar(progress)
                        }
                        processingQueueCaption(job, progress: progress)
                    }
                    Spacer(minLength: 4)
                    if job?.state != .failed {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show recording")

            if job?.state == .failed {
                Button("Retry") { Task { await appState.retryProcessing(session) } }
            }
        }
    }

    @ViewBuilder
    private func processingQueueCaption(
        _ job: ProcessingJob?,
        progress: ProcessingStageProgress?
    ) -> some View {
        let label = LocalizedStringKey(
            job?.statusLabel(queueStatus: appState.processingQueueStatus) ?? "Queued"
        )
        Group {
            if let progress, let step = progress.currentStepNumber {
                Text(label)
                    + Text(verbatim: " · ")
                    + Text("Step \(step) of \(progress.steps.count)")
            } else {
                Text(label)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// One segment per step this attempt will really run. There is no progress
    /// fraction inside a step, so the bar states the step boundaries only.
    private func processingStageBar(_ progress: ProcessingStageProgress) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(progress.steps.enumerated()), id: \.element) { index, _ in
                Capsule()
                    .fill(segmentStyle(at: index, progress: progress))
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func segmentStyle(
        at index: Int,
        progress: ProcessingStageProgress
    ) -> AnyShapeStyle {
        if index == progress.failedIndex {
            return AnyShapeStyle(Color.red)
        }
        if index == progress.activeIndex {
            return AnyShapeStyle(Color.accentColor.opacity(0.45))
        }
        if index < progress.completedCount {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(.quaternary)
    }

    /// A paused scheduler leaves every job on `.queued`, so the reason and the
    /// way out both have to be stated here.
    private func pausedBanner(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(reason, systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if appState.canResumeProcessing {
                Button("Resume processing") { Task { await appState.resumeProcessing() } }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeRecoveryCandidate: SessionRecoveryCandidate? {
        appState.status == .idle ? appState.recoveryCandidates.first : nil
    }

    private var activeRecoveryIssue: SessionRecoveryIssue? {
        appState.status == .idle ? appState.recoveryIssues.first : nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title3.weight(.semibold))
                .foregroundStyle(appState.status == .recording ? Color.red : Color.accentColor)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text("MeetingScribe")
                    .font(.headline)
                Text(LocalizedStringKey(appState.status.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.status == .recording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Recording")
            }

            Button {
                openSettingsAction()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit MeetingScribe")
            .accessibilityLabel("Quit MeetingScribe")
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            meetingTitleAndCalendarControl

            meetingNotesDisclosure

            Button {
                Task { await appState.startRecording() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                !appState.canStartRecording
            )

            Text("Make sure you have the required permission or participant consent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingContent: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                calendarPickerButton
                recordingTitleEditor
                clearCalendarSelectionButton
            }

            if let startedAt = appState.currentSession?.metadata.startedAt {
                RecordingDurationView(startedAt: startedAt)
            }

            LiveCaptureDiagnosticsView(
                model: appState.captureDiagnosticsModel,
                captureMode: appState.currentSession?.metadata.resolvedCaptureMode
                    ?? .systemAndMicrophone
            )

            if canShowMeetingNotesEditor {
                MeetingNotesEditor(
                    text: $meetingNotes.draft,
                    isTimestampVisible: true,
                    saveState: meetingNotesSaveState,
                    insertTimestamp: insertMeetingNotesTimestamp,
                    locale: appState.selectedAppLanguage.locale
                )
                .onChange(of: meetingNotes.draft) { _, _ in
                    scheduleMeetingNotesSave()
                }
                .onDisappear {
                    Task { @MainActor in
                        await saveMeetingNotesImmediately()
                    }
                }
                .task {
                    await appState.loadMeetingNotesFromDisk()
                }
            }

            Button {
                Task { @MainActor in
                    await saveMeetingNotesImmediately()
                    await appState.stopRecording()
                }
            } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Text("Recording continues if this popover is closed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var meetingNotesDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    isMeetingNotesExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("Meeting notes", systemImage: "note.text")
                    Spacer()
                    Image(systemName: isMeetingNotesExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isMeetingNotesExpanded {
                MeetingNotesEditor(
                    text: $meetingNotes.draft,
                    isTimestampVisible: false,
                    saveState: nil,
                    insertTimestamp: {},
                    locale: appState.selectedAppLanguage.locale
                )
            }
        }
    }

    private var canShowMeetingNotesEditor: Bool {
        !appState.isCurrentSessionOnboardingTest
    }

    private func scheduleMeetingNotesSave() {
        meetingNotesSaveTask?.cancel()
        meetingNotesSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            meetingNotesSaveState = .saving
            await persistMeetingNotes()
        }
    }

    private func saveMeetingNotesImmediately() async {
        meetingNotesSaveTask?.cancel()
        meetingNotesSaveTask = nil
        await persistMeetingNotes()
    }

    private func persistMeetingNotes() async {
        let didPersistNotes = await appState.updateMeetingNotes(appState.meetingNotesDraft)
        if didPersistNotes {
            meetingNotesSaveState = .saved(Date())
        } else {
            meetingNotesSaveState = .failed
        }
    }

    private func insertMeetingNotesTimestamp() {
        guard let timestamp = appState.meetingNotesTimestampLinePrefix() else { return }
        if !appState.meetingNotesDraft.isEmpty && !appState.meetingNotesDraft.hasSuffix("\n") {
            appState.meetingNotesDraft += "\n"
        }
        appState.meetingNotesDraft += timestamp
        scheduleMeetingNotesSave()
    }

    private var recordingTitleEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)

            if isEditingMeetingTitle {
                TextField("Meeting title (optional)", text: $meetingTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .focused($isMeetingTitleFocused)
                    .onSubmit { saveMeetingTitle() }

                Button(action: saveMeetingTitle) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .disabled(
                    meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Save meeting title")
                .accessibilityLabel("Save meeting title")

                Button(action: cancelMeetingTitleEditing) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityLabel("Cancel")
            } else {
                Text(appState.currentSession?.metadata.title ?? appState.meetingTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Button(action: beginMeetingTitleEditing) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit meeting title")
                .accessibilityLabel("Edit meeting title")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func beginMeetingTitleEditing() {
        meetingTitleDraft = appState.currentSession?.metadata.title ?? appState.meetingTitle
        isEditingMeetingTitle = true
        DispatchQueue.main.async {
            isMeetingTitleFocused = true
        }
    }

    private func saveMeetingTitle() {
        let normalizedTitle = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        isMeetingTitleFocused = false
        isEditingMeetingTitle = false
        Task { await appState.renameCurrentSession(to: normalizedTitle) }
    }

    private func cancelMeetingTitleEditing() {
        isMeetingTitleFocused = false
        isEditingMeetingTitle = false
    }

    private var processingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Processing meeting")
                    .font(.headline)
                Text("You can close this popover. Processing will continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(appState.processingSteps) { step in
                    processingRow(step)
                    if step.id != ProcessingStepID.allCases.last {
                        Divider().padding(.leading, 30)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            sessionSummary(appState.currentSession, includesSegments: false)

            Label("Original audio is preserved until processing completes.", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var completedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            completedBanner

            Divider()

            meetingTitleAndCalendarControl

            Button {
                Task { await appState.startRecording() }
            } label: {
                Label("Start new meeting", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                appState.aiAnalysisReprocessingSessionID != nil
                    || appState.fluidAudioReprocessingSessionID != nil
            )
        }
    }

    private var completedBanner: some View {
        Button {
            guard let session = appState.lastCompletedSession else { return }
            appState.requestRecordingsOverview(for: session)
            openRecordingsAction()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text("Meeting processed successfully")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(appState.lastCompletedSession == nil)
        .help("Show completed recording")
        .accessibilityLabel("Show completed recording")
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            messageBanner(
                appState.lastError ?? "Meeting processing failed.",
                color: .red,
                icon: "xmark.octagon.fill"
            )

            HStack {
                Button("Reveal session") { appState.revealLastSession() }
                Spacer()
                Button("Try another meeting") { appState.reset() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack {
                Button {
                    openRecordingsAction()
                } label: {
                    Label("Recordings overview", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)

                Spacer()

                // The entry is named after the readiness overview, so it has
                // to open that and not the first-run guide.
                Button {
                    appState.selectedSettingsSection = "readiness"
                    openSettingsAction()
                } label: {
                    Label("Readiness", systemImage: "checkmark.seal")
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
        }
    }

    private var meetingTitleAndCalendarControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                calendarPickerButton
                TextField("Meeting title (optional)", text: $appState.meetingTitle)
                    .textFieldStyle(.roundedBorder)
                clearCalendarSelectionButton
            }
            calendarSelectionSummary
        }
    }

    private var calendarPickerButton: some View {
        Button(action: openCalendarPickerOrSettings) {
            Image(systemName: appState.approvedCalendarEvent == nil
                ? "calendar"
                : "calendar.badge.checkmark")
                .foregroundStyle(appState.approvedCalendarEvent == nil ? Color.primary : .green)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!appState.canChooseCalendarEvent)
        .help(appState.approvedCalendarEvent == nil ? "Choose from Calendar" : "Change")
        .accessibilityLabel(appState.approvedCalendarEvent == nil ? "Choose from Calendar" : "Change")
    }

    @ViewBuilder
    private var clearCalendarSelectionButton: some View {
        if appState.approvedCalendarEvent != nil {
            Button {
                Task { await appState.clearCalendarSelection() }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove calendar selection")
            .accessibilityLabel("Remove calendar selection")
        }
    }

    @ViewBuilder
    private var calendarSelectionSummary: some View {
        if let event = appState.approvedCalendarEvent {
            HStack(spacing: 5) {
                Text(verbatim: event.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(event.participants.count) confirmed participants")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(.leading, 46)
        }
    }

    private func openCalendarPickerOrSettings() {
        appState.refreshCalendarAuthorizationStatus()
        guard appState.calendarIntegrationEnabled,
              appState.calendarAuthorizationStatus.canReadEvents else {
            appState.selectedSettingsSection = "calendar"
            openSettingsAction()
            return
        }
        openCalendarPickerAction()
    }

    private func processingRow(_ step: ProcessingStep) -> some View {
        HStack(spacing: 10) {
            Group {
                switch step.state {
                case .active:
                    ProgressView().controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)

            Text(LocalizedStringKey(step.id.displayName))
                .foregroundStyle(step.state == .pending ? .secondary : .primary)
            Spacer()
            if step.state == .skipped {
                Text("Skipped").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 38)
    }

    private func recoveryContent(_ candidate: SessionRecoveryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unfinished recording found", systemImage: "arrow.counterclockwise.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(candidate.session.metadata.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text(LocalizedStringKey(candidate.reason.displayName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                preservedTracks(candidate.artifacts)
            } icon: {
                Image(systemName: "waveform.badge.checkmark")
            }
            .font(.caption)

            if appState.recoveryCandidates.count > 1 {
                (Text("Further unfinished recordings:")
                    + Text(verbatim: " \(appState.recoveryCandidates.count - 1)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Recover and process") {
                Task { await appState.recoverSession(candidate) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(appState.isRecoveringSession)

            HStack {
                Button("Reveal") { appState.revealRecovery(candidate) }
                Spacer()
                Button("Close") { Task { await appState.closeRecovery(candidate) } }
            }
            .controlSize(.small)

            Text("Nothing is deleted when a recovery is closed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func recoveryIssueContent(_ issue: SessionRecoveryIssue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recording folder needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(issue.directoryName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text(verbatim: issue.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.recoveryIssues.count > 1 {
                (Text("Further folders needing attention:")
                    + Text(verbatim: " \(appState.recoveryIssues.count - 1)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Reveal") { appState.revealRecoveryIssue(issue) }
                Spacer()
                Button("Close") { Task { await appState.closeRecoveryIssue(issue) } }
            }
            .controlSize(.small)

            Text("Nothing is deleted when a recovery issue is closed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func preservedTracks(_ artifacts: SessionRecoveryArtifacts) -> some View {
        let hasSystem = artifacts.hasSystemAudio || artifacts.hasWorkingSystemAudio
        if hasSystem && artifacts.hasMicrophoneAudio {
            Text("Preserved tracks: system audio and microphone")
        } else if hasSystem {
            Text("Preserved track: system audio")
        } else if artifacts.hasMicrophoneAudio {
            Text("Preserved track: microphone")
        } else if artifacts.hasMergedTranscript {
            Text("Preserved artifact: transcript")
        } else {
            Text("Preserved session files")
        }
    }

    @ViewBuilder
    private func sessionSummary(_ session: RecordingSession?, includesSegments: Bool) -> some View {
        if let session {
            VStack(alignment: .leading, spacing: 6) {
                Label(session.metadata.title, systemImage: "text.quote")
                    .lineLimit(2)

                HStack(spacing: 14) {
                    if let duration = sessionDuration(session.metadata) {
                        Label(duration, systemImage: "clock")
                    }
                    if includesSegments,
                       let segments = session.metadata.transcription?.mergedSegmentCount {
                        Label {
                            Text(verbatim: "\(segments) ") + Text("segments")
                        } icon: {
                            Image(systemName: "text.bubble")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if includesSegments, let name = appState.lastMarkdownURL?.lastPathComponent {
                    Label(name, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sessionDuration(_ metadata: SessionMetadata) -> String? {
        guard let startedAt = metadata.startedAt else { return nil }
        let end = metadata.endedAt ?? Date()
        let elapsed = max(0, Int(end.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", elapsed / 3_600, (elapsed % 3_600) / 60, elapsed % 60)
    }

    private func messageBanner(_ message: String, color: Color, icon: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LiveCaptureDiagnosticsView: View {
    let model: CaptureDiagnosticsModel
    let captureMode: CaptureMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let snapshot = model.snapshot
            VStack(spacing: 14) {
                RecordingWaveformView(
                    levels: liveRecordingAudioLevels(
                        from: snapshot,
                        at: context.date
                    )
                )
                .frame(height: 42)

                CaptureSourcesView(sources: sources(from: snapshot, at: context.date))
                    .equatable()
            }
        }
    }

    private func sources(
        from snapshot: CaptureSessionDiagnostics,
        at date: Date
    ) -> [CaptureSourceStatus] {
        var sources: [CaptureSourceStatus] = []
        if captureMode != .microphoneOnly {
            sources.append(CaptureSourceStatus(
                title: "System audio",
                health: snapshot.systemAudio.health(at: date),
                failureReason: snapshot.systemAudio.failureReason,
                required: true
            ))
        }
        sources.append(CaptureSourceStatus(
            title: "Microphone",
            health: snapshot.microphone.health(at: date),
            failureReason: snapshot.microphone.failureReason,
            required: captureMode == .microphoneOnly
        ))
        return sources
    }

    private func liveRecordingAudioLevels(
        from snapshot: CaptureSessionDiagnostics,
        at date: Date
    ) -> [Double] {
        if captureMode == .microphoneOnly {
            return snapshot.microphone.recentLiveAudioLevels(at: date)
        }
        return snapshot.combinedRecentAudioLevels(at: date)
    }
}

private struct CaptureSourceStatus: Identifiable, Equatable {
    /// The localization key of the track name, which is also unique per row.
    let title: String
    let health: AudioCaptureHealth
    let failureReason: String?
    let required: Bool

    var id: String { title }

    var isHealthy: Bool { health == .active }

    var healthKey: LocalizedStringKey {
        switch health {
        case .idle, .waitingForData: return "waiting for data"
        case .active: return "active"
        case .stalled: return "no recent data"
        case .failed: return "capture error"
        }
    }

    var iconName: String {
        switch health {
        case .active: return "waveform.badge.checkmark"
        case .stalled, .failed: return "exclamationmark.triangle.fill"
        case .idle, .waitingForData: return "waveform"
        }
    }

    var tint: Color {
        switch health {
        case .active: return .green
        case .stalled, .failed: return required ? .red : .orange
        case .idle, .waitingForData: return .secondary
        }
    }
}

/// Both capture tracks in one row. A healthy track is carried by its icon
/// alone; anything else spells the state out, because that is when the user
/// has to read it.
private struct CaptureSourcesView: View, Equatable {
    let sources: [CaptureSourceStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ForEach(sources) { source in
                    chip(source)
                }
            }

            ForEach(sources) { source in
                if let failureReason = source.failureReason {
                    Text(verbatim: failureReason)
                        .font(.caption2)
                        .foregroundStyle(source.required ? .red : .orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func chip(_ source: CaptureSourceStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.iconName)
                .foregroundStyle(source.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(source.title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !source.isHealthy {
                    Text(source.healthKey)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(Text(LocalizedStringKey(source.title))): \(Text(source.healthKey))")
        )
    }
}

private struct RecordingDurationView: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(String(
                format: "%02d:%02d:%02d",
                elapsed / 3_600,
                (elapsed % 3_600) / 60,
                elapsed % 60
            ))
            .font(.system(size: 30, weight: .semibold, design: .monospaced))
            .foregroundStyle(.red)
            .contentTransition(.numericText())
        }
    }
}

private enum MeetingNotesSaveState {
    case saving
    case saved(Date)
    case failed
}

private struct MeetingNotesEditor: View {
    @Binding var text: String
    let isTimestampVisible: Bool
    let saveState: MeetingNotesSaveState?
    let insertTimestamp: () -> Void
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.subheadline.weight(.semibold))

                if isTimestampVisible {
                    Button(action: insertTimestamp) {
                        Image(systemName: "timer")
                    }
                    .buttonStyle(.plain)
                    .help("Insert note timestamp")
                    .accessibilityLabel("Insert note timestamp")
                }

                Spacer()

                if let saveState {
                    saveStateLabel(saveState)
                }
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func saveStateLabel(_ state: MeetingNotesSaveState) -> some View {
        switch state {
        case .saving:
            Text("Saving…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .saved(date):
            Text("Saved \(savedTime(date))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("Saving failed — text stays in the editor")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savedTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale
            )
        )
    }
}

private struct RecordingWaveformView: View {
    let levels: [Double]

    private let barCount = 22

    private var displayedLevels: [Double] {
        let recent = Array(levels.suffix(barCount)).map { min(1, max(0, $0)) }
        return Array(repeating: 0, count: max(0, barCount - recent.count)) + recent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(displayedLevels.indices, id: \.self) { index in
                let level = displayedLevels[index]
                Capsule()
                    .fill(.red.opacity(0.22 + level * 0.73))
                    .frame(width: 5, height: 4 + level * 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live recorded audio level")
    }
}
