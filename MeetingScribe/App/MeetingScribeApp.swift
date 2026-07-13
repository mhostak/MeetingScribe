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

        Settings {
            SettingsView(appState: appState)
        }
    }
}
