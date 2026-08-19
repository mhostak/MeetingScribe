import SwiftUI

struct CalendarEventPickerView: View {
    @ObservedObject var appState: AppState
    let onCancel: () -> Void
    let onConfirmation: () -> Void
    let onOpenSettings: () -> Void
    @State private var selectedEventID: String?
    @State private var selectedParticipantIDs = Set<String>()
    @State private var includeEventDescription = false
    @State private var eventDescription = ""
    @State private var isApproving = false

    init(
        appState: AppState,
        onCancel: @escaping () -> Void = {},
        onConfirmation: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.onCancel = onCancel
        self.onConfirmation = onConfirmation
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Apple Calendar", systemImage: "calendar")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel", action: onCancel)
            }

            Divider()

            Group {
                if appState.calendarIntegrationEnabled,
                   appState.calendarAuthorizationStatus.canReadEvents {
                    eventSelectionContent
                } else {
                    settingsRequiredContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(width: 580, height: 680)
        .task {
            appState.refreshCalendarAuthorizationStatus()
            if appState.calendarAuthorizationStatus.canReadEvents {
                await appState.loadCalendarEventCandidates()
            }
        }
        .onExitCommand(perform: onCancel)
    }

    private var settingsRequiredContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Calendar setup is required", systemImage: "calendar.badge.exclamationmark")
                .font(.headline)
            Text("Calendar access is configured in MeetingScribe Settings. Event and participant selection remains specific to this meeting.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Calendar Settings") {
                openCalendarSettings()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var eventSelectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose an event")
                    .font(.headline)
                Spacer()
                if appState.isLoadingCalendarEvents {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") {
                        Task { await appState.loadCalendarEventCandidates() }
                    }
                    .controlSize(.small)
                }
            }

            if appState.calendarEventCandidates.isEmpty, !appState.isLoadingCalendarEvents {
                ContentUnavailableView(
                    "No nearby events",
                    systemImage: "calendar.badge.clock",
                    description: Text("No events were found for the current recording time. You can keep the manually entered meeting title.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.calendarEventCandidates) { candidate in
                            eventRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            if let selectedEvent {
                Divider()

                Text("People who actually attended")
                    .font(.headline)
                if selectedEvent.participants.isEmpty {
                    Text("This event has no invitees with a display name. You can still confirm the event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(selectedEvent.participants) { participant in
                                Toggle(isOn: participantBinding(participant.id)) {
                                    Text(verbatim: participant.displayName)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 105)
                }

                Text("Selected participant names are included in meeting metadata and AI analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Include event description", isOn: $includeEventDescription)
                TextEditor(text: $eventDescription)
                    .font(.body)
                    .frame(minHeight: 72, maxHeight: 96)
                    .padding(4)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(!includeEventDescription)
                    .opacity(includeEventDescription ? 1 : 0.55)
                if selectedEvent.eventDescription == nil, eventDescription.isEmpty {
                    Text("This event has no description. Enable the option to add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Text("Only the confirmed snapshot is saved with the recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Confirm event") { approveSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedEvent == nil || isApproving)
            }
        }
    }

    private func eventRow(_ candidate: CalendarEventCandidate) -> some View {
        Button {
            selectedEventID = candidate.id
            selectedParticipantIDs = Set(candidate.participants.map(\.id))
            eventDescription = candidate.eventDescription ?? ""
            includeEventDescription = candidate.eventDescription != nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedEventID == candidate.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedEventID == candidate.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: candidate.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if candidate.isAllDay {
                            Text("All day")
                        } else {
                            Text(candidate.startsAt, style: .time)
                            Text("–")
                            Text(candidate.endsAt, style: .time)
                        }
                        if !candidate.participants.isEmpty {
                            Text("•")
                            Text("\(candidate.participants.count) invitees")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(9)
            .contentShape(Rectangle())
            .background(
                selectedEventID == candidate.id
                    ? Color.accentColor.opacity(0.1)
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectedEvent: CalendarEventCandidate? {
        appState.calendarEventCandidates.first { $0.id == selectedEventID }
    }

    private func participantBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedParticipantIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedParticipantIDs.insert(id)
                } else {
                    selectedParticipantIDs.remove(id)
                }
            }
        )
    }

    private func approveSelection() {
        guard let selectedEvent, !isApproving else { return }
        isApproving = true
        Task {
            let approved = await appState.approveCalendarEvent(
                selectedEvent,
                participantIDs: selectedParticipantIDs,
                eventDescription: includeEventDescription ? eventDescription : nil
            )
            isApproving = false
            if approved { onConfirmation() }
        }
    }

    private func openCalendarSettings() {
        appState.selectedSettingsSection = "calendar"
        onOpenSettings()
    }
}
