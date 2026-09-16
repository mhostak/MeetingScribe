import Foundation
import UserNotifications
import XCTest
@testable import MeetingScribe

@MainActor
final class ProcessingNotificationsTests: XCTestCase {
    func testPayloadOnlyReportsSafeStageAndSuccessRequiresMarkdown() {
        let id = UUID()
        let notification = ProcessingNotification(
            id: id, sessionID: "session-7", title: "Meeting",
            failedSteps: [.analyzing], markdownURL: nil, language: .czech,
            occurredAt: Date(timeIntervalSince1970: 42)
        )
        XCTAssertEqual(notification.id, id)
        XCTAssertEqual(notification.failureStage, .analyzing)
        XCTAssertFalse(notification.succeeded)

        let success = ProcessingNotification(
            sessionID: "session-7", title: "Meeting",
            markdownURL: URL(fileURLWithPath: "/tmp/meeting.md")
        )
        XCTAssertTrue(success.succeeded)
    }

    func testSendDeduplicatesAttemptAndDoesNotExposeErrorText() async throws {
        let center = NotificationCenterSpy()
        let id = UUID()
        let service = ProcessingNotificationService(center: center)
        let notification = ProcessingNotification(
            id: id, sessionID: "session-1", title: "Private title",
            failedSteps: [.exporting], language: .english
        )
        await service.send(notification)
        await service.send(notification)

        XCTAssertEqual(center.requests.count, 1)
        let content = center.requests[0].content
        XCTAssertTrue(content.body.contains("Exporting Markdown".lowercased()) || content.body.contains("exporting"))
        XCTAssertFalse(content.body.contains("NSError"))
        XCTAssertEqual(center.requests[0].identifier, id.uuidString)
        XCTAssertEqual(content.userInfo["sessionID"] as? String, "session-1")
        XCTAssertEqual(content.userInfo["occurredAt"] as? Double, notification.occurredAt.timeIntervalSince1970)
        XCTAssertNotNil(try? PropertyListSerialization.data(fromPropertyList: content.userInfo, format: .binary, options: 0))
    }

    func testDeniedPermissionSkipsSendWithoutRequestingAuthorization() async {
        let center = NotificationCenterSpy(); center.status = .denied
        let service = ProcessingNotificationService(center: center)
        await service.send(ProcessingNotification(sessionID: "s", title: "T", markdownURL: URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
    }

    func testPermissionAndAddErrorsAreSwallowedAndDistinctAttemptsSend() async {
        let center = NotificationCenterSpy(); center.status = .notDetermined; center.authorizationError = TestError.example
        let service = ProcessingNotificationService(center: center)
        await service.send(ProcessingNotification(sessionID: "s", title: "T"))
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
        await service.requestAuthorization()
        XCTAssertEqual(center.authorizationRequests, 1)
        center.status = .authorized; center.addError = TestError.example
        await service.send(ProcessingNotification(sessionID: "s", title: "T", markdownURL: URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertTrue(center.requests.isEmpty)
        center.addError = nil
        await service.send(ProcessingNotification(sessionID: "s", title: "T", markdownURL: URL(fileURLWithPath: "/tmp/a.md")))
        await service.send(ProcessingNotification(sessionID: "s", title: "T", markdownURL: URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertNotEqual(center.requests.first?.identifier, center.requests.last?.identifier)
    }

    func testPartialFailureListsAIAndExportInAllLanguages() async {
        for language in [ProcessingNotificationLanguage.slovak, .czech, .english] {
            let center = NotificationCenterSpy()
            let service = ProcessingNotificationService(center: center)
            await service.send(ProcessingNotification(sessionID: "s", title: "T", failedSteps: [.analyzing, .exporting], markdownURL: URL(fileURLWithPath: "/tmp/a.md"), language: language))
            let body = center.requests[0].content.body
            XCTAssertTrue(body.contains(language == .english ? "ai analysis" : "AI analýza"))
            XCTAssertTrue(body.contains(language == .english ? "exporting markdown" : language == .czech ? "uložení výsledku" : "uloženie výsledku"))
            XCTAssertTrue(body.contains(language == .english ? "saved" : "uložený"))
        }
    }

    func testSelectionOpensSuccessAndPostsFailureForFallback() async {
        let center = NotificationCenterSpy(); let workspace = WorkspaceSpy(); let events = NotificationCenter()
        let service = ProcessingNotificationService(center: center, workspace: workspace, eventCenter: events)
        let url = URL(fileURLWithPath: "/tmp/meeting.md")
        service.handleSelection(userInfo: ["sessionID": "ok", "success": true, "markdownURL": url.absoluteString])
        XCTAssertEqual(workspace.opened, url)
        let failure = XCTNSNotificationExpectation(
            name: ProcessingNotificationService.failureSelectedNotification,
            object: nil, notificationCenter: events
        )
        failure.handler = { event in
            event.userInfo?["sessionID"] as? String == "bad"
                && event.userInfo?["occurredAt"] as? Double == 42
        }
        service.handleSelection(userInfo: ["sessionID": "bad", "success": false, "occurredAt": 42.0])
        await fulfillment(of: [failure], timeout: 1)
        workspace.shouldOpen = false
        let fallback = XCTNSNotificationExpectation(
            name: ProcessingNotificationService.failureSelectedNotification,
            object: nil, notificationCenter: events
        )
        fallback.handler = { event in
            event.userInfo?["sessionID"] as? String == "missing"
                && event.userInfo?["occurredAt"] as? Double == 43
        }
        service.handleSelection(userInfo: ["sessionID": "missing", "success": true, "markdownURL": url.absoluteString, "occurredAt": 43.0])
        await fulfillment(of: [fallback], timeout: 1)
    }

}

@MainActor
private final class NotificationCenterSpy: ProcessingNotificationCenter {
    var delegate: UNUserNotificationCenterDelegate?
    var requests: [UNNotificationRequest] = []
    var status: UNAuthorizationStatus = .authorized
    var authorizationError: Error?
    var addError: Error?
    var authorizationRequests = 0
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequests += 1
        if let authorizationError { throw authorizationError }
        return true
    }
    func add(_ request: UNNotificationRequest) async throws {
        if let addError { throw addError }
        requests.append(request)
    }
}

private enum TestError: Error { case example }

@MainActor
private final class WorkspaceSpy: ProcessingWorkspaceOpening {
    var opened: URL?
    var shouldOpen = true
    func open(_ url: URL) -> Bool { opened = url; return shouldOpen }
}
