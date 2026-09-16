import AppKit
import Combine
import SwiftUI

@main
enum MeetingScribeEntryPoint {
    @MainActor
    static func main() async {
        if let code = await FluidAudioASRWorker.runIfRequested() { exit(code) }
        MeetingScribeApp.main()
    }
}

struct MeetingScribeApp: App {
    @StateObject private var appState: AppState
    @StateObject private var windowCoordinator: AppWindowCoordinator

    init() {
        let notifier = ProcessingNotificationService()
        notifier.installDelegate()
        let appState = AppState(processingNotifier: notifier)
        _appState = StateObject(wrappedValue: appState)
        _windowCoordinator = StateObject(
            wrappedValue: AppWindowCoordinator(appState: appState)
        )
        Task { @MainActor in
            await appState.prepareStorage()
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(appState: appState)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppWindowCoordinator: NSObject, ObservableObject, NSApplicationDelegate {
    private var terminationPending = false
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var processingObservation: AnyCancellable?
    private var statusObservation: AnyCancellable?
    private var failureNotificationObservation: AnyCancellable?
    private var recordingsWindow: NSWindow?
    private var calendarPickerWindow: NSWindow?
    private var renderedStatusIcon: (state: MenuBarIconState, colorScheme: ColorScheme)?

    init(appState: AppState) {
        self.appState = appState
        super.init()

        statusObservation = Publishers.CombineLatest3(
            appState.$status,
            appState.$recoveryCandidates.map { !$0.isEmpty },
            appState.$recoveryIssues.map { !$0.isEmpty }
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIcon()
            }
        }

        processingObservation = appState.$processingJobs.sink { [weak self] _ in
            Task { @MainActor in self?.refreshStatusIcon() }
        }

        // Keep the observer alive with the coordinator so clicks also work
        // when the recordings window has not been opened yet.
        failureNotificationObservation = NotificationCenter.default.publisher(
            for: ProcessingNotificationService.failureSelectedNotification
        ).sink { [weak self] event in
            guard let self, let sessionID = event.object as? String else { return }
            let occurredAt: Date = if let value = event.userInfo?["occurredAt"] as? TimeInterval {
                Date(timeIntervalSince1970: value)
            } else if let value = event.userInfo?["occurredAt"] as? Date {
                value
            } else {
                Date()
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState.requestRecordingsOverview(
                    sessionID: sessionID,
                    occurredAt: occurredAt
                )
                self.openRecordings()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.installStatusItem()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateCancel }
        terminationPending = true
        Task { @MainActor in
            let ready = await appState.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: ready)
            if !ready { terminationPending = false }
        }
        return .terminateLater
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        NSApplication.shared.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageOnly
        button.toolTip = "MeetingScribe"
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                appState: appState,
                openSettingsAction: { [weak self] in self?.openSettings() },
                openRecordingsAction: { [weak self] in self?.openRecordings() },
                openCalendarPickerAction: { [weak self] in self?.openCalendarPicker() }
            )
        )
        refreshStatusIcon()
    }

    @objc private func togglePopover() {
        if let calendarPickerWindow {
            present(calendarPickerWindow)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let colorScheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let state = MenuBarIconState(
            status: appState.status,
            hasRecovery: !appState.recoveryCandidates.isEmpty || !appState.recoveryIssues.isEmpty,
            hasProcessing: appState.isProcessingInBackground,
            hasProcessingFailures: appState.hasProcessingFailures
        )
        button.toolTip = state.accessibilityLabel + " · " + String(appState.processingJobs.filter {
            $0.metadata.processing?.state != .completed && $0.metadata.processing?.state != .failed
        }.count)
        guard renderedStatusIcon?.state != state
                || renderedStatusIcon?.colorScheme != colorScheme else {
            return
        }
        button.image = MenuBarIconRenderer.image(for: state, colorScheme: colorScheme)
        button.setAccessibilityLabel(state.accessibilityLabel)
        renderedStatusIcon = (state, colorScheme)
    }

    private func openSettings() {
        popover.performClose(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let didOpen = performNativeSettingsCommand()
        if !didOpen {
            let accepted = NSApplication.shared.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
            if !accepted {
                NSApplication.shared.sendAction(
                    Selector(("showPreferencesWindow:")),
                    to: nil,
                    from: nil
                )
            }
        }

        bringNativeSettingsToFront()
    }

    private func performNativeSettingsCommand() -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: ",",
            charactersIgnoringModifiers: ",",
            isARepeat: false,
            keyCode: 43
        ) else {
            return false
        }
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private func bringNativeSettingsToFront() {
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                NSApplication.shared.activate(ignoringOtherApps: true)
                let popoverWindow = self.popover.contentViewController?.view.window
                let window = NSApplication.shared.keyWindow
                    ?? NSApplication.shared.windows.first {
                        $0.isVisible
                            && $0.canBecomeKey
                            && $0 !== popoverWindow
                            && $0 !== self.recordingsWindow
                            && $0 !== self.calendarPickerWindow
                    }
                window?.makeKeyAndOrderFront(nil)
                window?.orderFrontRegardless()
            }
        }
    }

    private func openRecordings() {
        popover.performClose(nil)
        let window = recordingsWindow ?? makeWindow(
            title: "Recordings",
            size: NSSize(width: 900, height: 620),
            rootView: RecordingsWindow(appState: appState),
            isResizable: true
        )
        recordingsWindow = window
        present(window)
    }

    private func openCalendarPicker() {
        popover.performClose(nil)
        if let calendarPickerWindow {
            present(calendarPickerWindow)
            return
        }

        let window = makeWindow(
            title: "Apple Calendar",
            size: NSSize(width: 580, height: 560),
            rootView: CalendarEventPickerView(
                appState: appState,
                onCancel: { [weak self] in
                    self?.closeCalendarPicker(reopenPopover: true)
                },
                onConfirmation: { [weak self] in
                    self?.closeCalendarPicker(reopenPopover: true)
                },
                onOpenSettings: { [weak self] in
                    self?.closeCalendarPicker(reopenPopover: false)
                    self?.openSettings()
                }
            )
            .environment(\.locale, appState.selectedAppLanguage.locale),
            isResizable: false,
            isClosable: false
        )
        calendarPickerWindow = window
        present(window)
    }

    private func closeCalendarPicker(reopenPopover: Bool) {
        calendarPickerWindow?.orderOut(nil)
        calendarPickerWindow = nil
        guard reopenPopover else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    private func present(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        rootView: Content,
        isResizable: Bool,
        isClosable: Bool = true
    ) -> NSWindow {
        var styleMask: NSWindow.StyleMask = [.titled, .miniaturizable]
        if isClosable { styleMask.insert(.closable) }
        if isResizable { styleMask.insert(.resizable) }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.setContentSize(size)
        window.center()
        return window
    }
}
