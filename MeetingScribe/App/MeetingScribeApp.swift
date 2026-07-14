import SwiftUI

@main
struct MeetingScribeApp: App {
    @StateObject private var appState: AppState

    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)
        Task { @MainActor in
            await appState.prepareStorage()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarStatusLabel(
                status: appState.status,
                hasRecovery: !appState.recoveryCandidates.isEmpty
            )
        }
        .menuBarExtraStyle(.window)

        Window("Recordings", id: "recordings") {
            RecordingsWindow(appState: appState)
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView(appState: appState)
        }
    }
}
