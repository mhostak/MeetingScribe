import SwiftUI

@MainActor
final class SpeakerEditorViewModel: ObservableObject {
    @Published var speakers: [SpeakerProfile] = []
    @Published private(set) var originalSpeakers: [SpeakerProfile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var segmentCount = 0
    @Published private(set) var summaries: [String: SpeakerProfileSummary] = [:]
    @Published var errorMessage: String?

    private let session: RecordingSession
    private let service: SpeakerEditingService

    init(
        session: RecordingSession,
        service: SpeakerEditingService = SpeakerEditingService()
    ) {
        self.session = session
        self.service = service
    }

    var hasChanges: Bool { speakers != originalSpeakers }

    func load() async {
        guard !isLoading, speakers.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await service.load(session: session)
            speakers = snapshot.speakers
            originalSpeakers = snapshot.speakers
            segmentCount = snapshot.diarizedSegmentCount
            summaries = Dictionary(uniqueKeysWithValues: snapshot.summaries.map {
                ($0.speakerID, $0)
            })
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() async -> Bool {
        guard hasChanges, !isSaving else { return !hasChanges }
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await service.save(session: session, speakers: speakers)
            speakers = result.artifact.speakers
            originalSpeakers = result.artifact.speakers
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func merge(_ sourceID: String, into targetID: String) {
        guard let index = speakers.firstIndex(where: { $0.id == sourceID }),
              sourceID != targetID else { return }
        speakers[index].mergedIntoSpeakerID = targetID
    }

    func undoMerge(_ speakerID: String) {
        guard let index = speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        speakers[index].mergedIntoSpeakerID = nil
    }

    func mergeTargets(for profile: SpeakerProfile) -> [SpeakerProfile] {
        speakers.filter {
            $0.id != profile.id
                && $0.source == profile.source
                && $0.mergedIntoSpeakerID == nil
        }
    }

    func displayName(for speakerID: String) -> String {
        speakers.first(where: { $0.id == speakerID })?.displayName ?? speakerID
    }

    func summary(for speakerID: String) -> SpeakerProfileSummary? {
        summaries[speakerID]
    }
}

struct SpeakerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SpeakerEditorViewModel
    let onSaved: () async -> Void

    init(session: RecordingSession, onSaved: @escaping () async -> Void) {
        _model = StateObject(wrappedValue: SpeakerEditorViewModel(session: session))
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            actions
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 520)
        .task { await model.load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speakers")
                    .font(.title2.bold())
                Text("Rename or merge anonymous speaker clusters. Raw transcripts and audio are never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.segmentCount > 0 {
                Text("\(model.segmentCount) turns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView("Loading speakers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.speakers.isEmpty {
            ContentUnavailableView(
                "Speakers unavailable",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text(error)
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($model.speakers) { $profile in
                        speakerRow(profile: $profile)
                    }
                }
                .padding()
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    private func speakerRow(profile: Binding<SpeakerProfile>) -> some View {
        let value = profile.wrappedValue
        return HStack(spacing: 12) {
            Image(systemName: value.source == .microphone ? "mic.fill" : "person.wave.2.fill")
                .frame(width: 24)
                .foregroundStyle(value.source == .microphone ? .blue : .secondary)

            if let target = value.mergedIntoSpeakerID {
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.displayName)
                        .font(.headline)
                    Text("Merged into \(model.displayName(for: target))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Undo merge") { model.undoMerge(value.id) }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Display name", text: profile.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                        .onChange(of: profile.wrappedValue.displayName) {
                            if profile.wrappedValue.state == .anonymous {
                                profile.wrappedValue.state = .named
                            }
                        }
                    if let summary = model.summary(for: value.id) {
                        Text("\(summary.turnCount) turns · \(Int(summary.durationSeconds.rounded())) s")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !summary.examples.isEmpty {
                            Text(summary.examples.joined(separator: " • "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }

                Picker("State", selection: profile.state) {
                    Text("Anonymous").tag(SpeakerProfileState.anonymous)
                    Text("Named").tag(SpeakerProfileState.named)
                    Text("Unknown").tag(SpeakerProfileState.unknown)
                }
                .frame(width: 150)

                if value.source == .system,
                   !model.mergeTargets(for: value).isEmpty {
                    Menu {
                        ForEach(model.mergeTargets(for: value)) { target in
                            Button(target.displayName) {
                                model.merge(value.id, into: target.id)
                            }
                        }
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actions: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                Task {
                    if await model.save() {
                        await onSaved()
                        dismiss()
                    }
                }
            } label: {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save speaker changes")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.hasChanges || model.isSaving)
        }
        .padding()
    }
}
