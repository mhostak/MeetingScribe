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
        MenuBarExtra("MeetingScribe", systemImage: appState.status.menuBarSystemImage) {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
