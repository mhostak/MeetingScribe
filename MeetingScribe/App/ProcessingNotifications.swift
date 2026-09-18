import AppKit
import Foundation
import UserNotifications

/// The language used for the small, user visible processing notification.
enum ProcessingNotificationLanguage: String, Sendable {
    case slovak = "sk"
    case czech = "cs"
    case english = "en"
}

/// A safe summary of one processing attempt. It deliberately contains stages,
/// rather than an underlying error, so secrets and implementation details never
/// reach the notification banner.
struct ProcessingNotification: Identifiable, Sendable {
    let id: UUID
    let sessionID: String
    let title: String
    let failedSteps: [ProcessingStepID]
    let markdownURL: URL?
    let language: ProcessingNotificationLanguage
    let occurredAt: Date

    init(
        id: UUID = UUID(),
        sessionID: String,
        title: String,
        failedSteps: [ProcessingStepID] = [],
        markdownURL: URL? = nil,
        language: ProcessingNotificationLanguage = .english,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.failedSteps = failedSteps
        self.markdownURL = markdownURL
        self.language = language
        self.occurredAt = occurredAt
    }

    var succeeded: Bool { failedSteps.isEmpty && markdownURL != nil }
    var failureStage: ProcessingStepID? { failedSteps.first }
}

@MainActor
protocol ProcessingNotifying {
    func requestAuthorization() async
    func authorizationStatus() async -> UNAuthorizationStatus
    func send(_ notification: ProcessingNotification) async
}

@MainActor
protocol ProcessingNotificationCenter: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class SystemProcessingNotificationCenter: ProcessingNotificationCenter {
    private let base = UNUserNotificationCenter.current()
    var delegate: UNUserNotificationCenterDelegate? { get { base.delegate } set { base.delegate = newValue } }
    func authorizationStatus() async -> UNAuthorizationStatus { await base.notificationSettings().authorizationStatus }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { try await base.requestAuthorization(options: options) }
    func add(_ request: UNNotificationRequest) async throws { try await base.add(request) }
}

@MainActor
protocol ProcessingWorkspaceOpening {
    func open(_ url: URL) -> Bool
}

private struct SystemWorkspaceOpening: ProcessingWorkspaceOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

/// Posts one local notification per processing attempt and handles its action.
@MainActor
final class ProcessingNotificationService: NSObject, ProcessingNotifying, UNUserNotificationCenterDelegate {
    /// Posted when a failed notification is selected. The object is the session ID.
    static let failureSelectedNotification = Notification.Name("MeetingScribe.processingFailureSelected")

    private let injectedCenter: ProcessingNotificationCenter?
    private let workspace: ProcessingWorkspaceOpening
    private let eventCenter: NotificationCenter
    private lazy var systemCenter = SystemProcessingNotificationCenter()
    private var center: ProcessingNotificationCenter { injectedCenter ?? systemCenter }
    private var sentAttemptIDs = Set<UUID>()

    init(
        center: ProcessingNotificationCenter? = nil,
        workspace: ProcessingWorkspaceOpening? = nil,
        eventCenter: NotificationCenter = .default
    ) {
        self.injectedCenter = center
        self.workspace = workspace ?? SystemWorkspaceOpening()
        self.eventCenter = eventCenter
        super.init()
    }

    /// Registers the delegate for cold launch handling. Call from app startup,
    /// after constructing the service, rather than from a model initializer.
    func installDelegate() {
        center.delegate = self
    }

    func requestAuthorization() async {
        installDelegate()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Reads the delivery permission without requesting it, so readiness can
    /// report a granted opt-in as ready instead of unverified.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.authorizationStatus()
    }

    func send(_ notification: ProcessingNotification) async {
        installDelegate()
        guard sentAttemptIDs.insert(notification.id).inserted else { return }
        guard [.authorized, .provisional].contains(await center.authorizationStatus()) else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.sound = .default
        var userInfo: [AnyHashable: Any] = [
            UserInfoKey.sessionID: notification.sessionID,
            UserInfoKey.failedSteps: notification.failedSteps.map(\.rawValue),
            UserInfoKey.success: notification.succeeded,
            UserInfoKey.occurredAt: notification.occurredAt.timeIntervalSince1970,
        ]
        if let markdownURL = notification.markdownURL {
            userInfo[UserInfoKey.markdownURL] = markdownURL.absoluteString
        }
        content.userInfo = userInfo

        let copy = LocalizedCopy(notification: notification)
        content.body = copy.body
        let request = UNNotificationRequest(
            identifier: notification.id.uuidString,
            content: content,
            trigger: nil
        )
        // Authorization errors are intentionally ignored: processing has already completed.
        _ = try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let payload = SelectionPayload(userInfo: info)
        guard payload.sessionID != nil else { return }
        await handleSelection(payload: payload)
    }

    func handleSelection(userInfo info: [AnyHashable: Any]) {
        handleSelection(payload: SelectionPayload(userInfo: info))
    }

    private func handleSelection(payload: SelectionPayload) {
        guard let sessionID = payload.sessionID else { return }
        if payload.succeeded, let url = payload.markdownURL, workspace.open(url) {
            return
        }
        // A missing/unopenable Markdown file is treated like a failed attempt;
        // the coordinator can take the user to Recordings.
        var eventInfo: [AnyHashable: Any] = [UserInfoKey.sessionID: sessionID]
        if let occurredAt = payload.occurredAt {
            eventInfo[UserInfoKey.occurredAt] = occurredAt
        }
        eventCenter.post(
            name: Self.failureSelectedNotification,
            object: sessionID,
            userInfo: eventInfo
        )
    }

    private struct SelectionPayload: Sendable {
        let sessionID: String?
        let succeeded: Bool
        let markdownURL: URL?
        let occurredAt: Double?
        init(userInfo: [AnyHashable: Any]) {
            sessionID = userInfo[UserInfoKey.sessionID] as? String
            succeeded = userInfo[UserInfoKey.success] as? Bool ?? false
            markdownURL = (userInfo[UserInfoKey.markdownURL] as? String).flatMap(URL.init(string:))
            occurredAt = userInfo[UserInfoKey.occurredAt] as? Double
        }
    }

    private enum UserInfoKey {
        static let sessionID = "sessionID"
        static let failedSteps = "failedSteps"
        static let markdownURL = "markdownURL"
        static let success = "success"
        static let occurredAt = "occurredAt"
    }
}

private struct LocalizedCopy {
    let body: String

    init(notification: ProcessingNotification) {
        if notification.succeeded {
            switch notification.language {
            case .slovak: body = "Prepis je dokončený a uložený."
            case .czech: body = "Přepis je dokončený a uložený."
            case .english: body = "Transcription completed and saved."
            }
        } else {
            let stages = notification.failedSteps.map { $0.localizedDisplayName(for: notification.language) }
            let stage = stages.isEmpty ? nil : stages.joined(separator: ", ")
            switch notification.language {
            case .slovak:
                body = (notification.markdownURL == nil ? "Spracovanie sa nepodarilo dokončiť." : "Prepis je uložený, ale spracovanie zlyhalo.") + (stage.map { " Neúspešné kroky: \($0)." } ?? "") + " Podrobnosti nájdete v nahrávkach."
            case .czech:
                body = (notification.markdownURL == nil ? "Zpracování se nepodařilo dokončit." : "Přepis je uložený, ale zpracování selhalo.") + (stage.map { " Neúspěšné kroky: \($0)." } ?? "") + " Podrobnosti najdete v nahrávkách."
            case .english:
                body = (notification.markdownURL == nil ? "Processing could not be completed." : "Transcription was saved, but processing failed.") + (stage.map { " Failed steps: \($0)." } ?? "") + " Open Recordings for details."
            }
        }
    }
}

private extension ProcessingStepID {
    func localizedDisplayName(for language: ProcessingNotificationLanguage) -> String {
        switch (self, language) {
        case (.preparingAudio, .slovak): return "príprava audia"
        case (.transcribing, .slovak): return "prepis"
        case (.analyzing, .slovak): return "AI analýza"
        case (.exporting, .slovak): return "uloženie výsledku"
        case (.preparingAudio, .czech): return "příprava audia"
        case (.transcribing, .czech): return "přepis"
        case (.analyzing, .czech): return "AI analýza"
        case (.exporting, .czech): return "uložení výsledku"
        default: return displayName.lowercased()
        }
    }
}
