import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    let openSettingsAction: () -> Void
    let openRecordingsAction: () -> Void
    let openCalendarPickerAction: () -> Void
    @State private var isEditingMeetingTitle = false
    @State private var meetingTitleDraft = ""
    @FocusState private var isMeetingTitleFocused: Bool

    init(
        appState: AppState,
        openSettingsAction: @escaping () -> Void = {},
        openRecordingsAction: @escaping () -> Void = {},
        openCalendarPickerAction: @escaping () -> Void = {}
    ) {
        self.appState = appState
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
            HStack {
                Text("Processing queue").font(.headline)
                Spacer()
                Text("\(visibleProcessingJobs.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            if let reason = appState.processingPauseReason {
                pausedBanner(reason)
            }
            ForEach(Array(visibleProcessingJobs.prefix(3)), id: \.metadata.id) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.metadata.title).lineLimit(1)
                        Text(LocalizedStringKey(
                            session.metadata.processing?
                                .statusLabel(queueStatus: appState.processingQueueStatus) ?? "Queued"
                        ))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if session.metadata.processing?.state == .failed {
                        Button("Retry") { Task { await appState.retryProcessing(session) } }
                    } else if session.metadata.processing?.state == .running {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            Button("Show recordings", action: openRecordingsAction)
        }
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

            HStack(spacing: 7) {
                settingsChip(
                    appState.fluidAudioASRDescriptor.displayName,
                    icon: "waveform",
                    section: "transcription",
                    localizeTitle: false
                )
                settingsChip(
                    appState.aiAnalysisEnabled ? "AI on" : "AI off",
                    icon: "sparkles",
                    section: "ai"
                )
                settingsChip(
                    appState.outputFolderURL?.lastPathComponent ?? "Output folder",
                    icon: "folder",
                    section: "output",
                    localizeTitle: appState.outputFolderURL == nil
                )
            }
        }
    }

    private var recordingContent: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                calendarPickerButton
                recordingTitleEditor
                clearCalendarSelectionButton
            }
            calendarSelectionSummary

            if let startedAt = appState.currentSession?.metadata.startedAt {
                RecordingDurationView(startedAt: startedAt)
            }

            LiveCaptureDiagnosticsView(
                model: appState.captureDiagnosticsModel,
                captureMode: appState.currentSession?.metadata.resolvedCaptureMode
                    ?? .systemAndMicrophone
            )

            Button {
                Task { await appState.stopRecording() }
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

    private func settingsChip(
        _ title: String,
        icon: String,
        section: String,
        localizeTitle: Bool = true
    ) -> some View {
        Button {
            appState.selectedSettingsSection = section
            openSettingsAction()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if localizeTitle {
                    Text(LocalizedStringKey(title))
                } else {
                    Text(verbatim: title)
                }
            }
            .font(.caption2)
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
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

                VStack(spacing: 7) {
                    if captureMode != .microphoneOnly {
                        AudioCaptureStatusView(
                            title: "System audio",
                            health: snapshot.systemAudio.health(at: context.date),
                            failureReason: snapshot.systemAudio.failureReason,
                            required: true
                        )
                        .equatable()
                    }
                    AudioCaptureStatusView(
                        title: "Microphone",
                        health: snapshot.microphone.health(at: context.date),
                        failureReason: snapshot.microphone.failureReason,
                        required: captureMode == .microphoneOnly
                    )
                    .equatable()
                }
            }
        }
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

private struct AudioCaptureStatusView: View, Equatable {
    let title: String
    let health: AudioCaptureHealth
    let failureReason: String?
    let required: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: audioIcon(for: health))
                .foregroundStyle(health == .stalled || health == .failed ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title)) + Text(": ") + Text(audioHealthKey(health))
                if let failureReason {
                    Text(verbatim: failureReason)
                        .foregroundStyle(required ? .red : .orange)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func audioHealthKey(_ health: AudioCaptureHealth) -> LocalizedStringKey {
        switch health {
        case .idle, .waitingForData: return "waiting for data"
        case .active: return "active"
        case .stalled: return "no recent data"
        case .failed: return "capture error"
        }
    }

    private func audioIcon(for health: AudioCaptureHealth) -> String {
        switch health {
        case .active: return "waveform.badge.checkmark"
        case .stalled, .failed: return "exclamationmark.triangle.fill"
        case .idle, .waitingForData: return "waveform"
        }
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
