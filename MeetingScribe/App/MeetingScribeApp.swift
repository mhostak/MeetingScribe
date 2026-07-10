import SwiftUI

@main
struct MeetingScribeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("MeetingScribe", systemImage: appState.status.menuBarSystemImage) {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
