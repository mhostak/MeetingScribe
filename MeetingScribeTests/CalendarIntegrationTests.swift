import Foundation
import XCTest
@testable import MeetingScribe

final class CalendarIntegrationTests: XCTestCase {
    func testCalendarEntitlementIsDeclaredForHardenedRuntimePrompting() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = projectRoot
            .appendingPathComponent("MeetingScribe")
            .appendingPathComponent("MeetingScribe.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any]

        XCTAssertEqual(
            propertyList?["com.apple.security.personal-information.calendars"] as? Bool,
            true
        )
    }

    func testRankingPrefersOverlappingTimedEventThenNearbyEventThenAllDayEvent() {
        let target = DateInterval(
            start: Date(timeIntervalSince1970: 10_000),
            end: Date(timeIntervalSince1970: 11_000)
        )
        let nearby = candidate(id: "nearby", start: 11_100, end: 11_500)
        let allDay = candidate(id: "all-day", start: 0, end: 86_400, isAllDay: true)
        let overlapping = candidate(id: "overlap", start: 10_200, end: 10_800)

        let sorted = CalendarEventRanking.sorted(
            [nearby, allDay, overlapping],
            for: target
        )

        XCTAssertEqual(sorted.map(\.id), ["overlap", "nearby", "all-day"])
    }

    @MainActor
    func testCalendarIntegrationSettingDefaultsOffAndPersistsOptIn() {
        let suiteName = "CalendarIntegrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ApplicationSettingsStore(defaults: defaults)

        let initial = store.calendarIntegrationEnabled
        store.setCalendarIntegrationEnabled(true)
        let updated = store.calendarIntegrationEnabled

        XCTAssertFalse(initial)
        XCTAssertTrue(updated)
    }

    @MainActor
    func testApprovalPreservesManualTitleAndStoresOnlySelectedDisplayNames() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarAppStateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "CalendarAppStateDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let participant = CalendarParticipantCandidate(id: "person-1", displayName: "Jana Nováková")
        let event = CalendarEventCandidate(
            id: "event-1",
            title: "Calendar title",
            startsAt: Date(timeIntervalSince1970: 10_000),
            endsAt: Date(timeIntervalSince1970: 11_000),
            isAllDay: false,
            participants: [participant]
        )
        let appState = AppState(
            sessionManager: SessionManager(recordingsRoot: root),
            applicationSettingsStore: ApplicationSettingsStore(defaults: defaults),
            calendarEventProvider: FakeCalendarEventProvider(candidates: [event]),
            automaticallyManageVADModel: false
        )
        appState.meetingTitle = "Manual title"
        appState.setCalendarIntegrationEnabled(true)
        await appState.loadCalendarEventCandidates(now: Date(timeIntervalSince1970: 10_500))

        let approved = await appState.approveCalendarEvent(
            event,
            participantIDs: [participant.id],
            useEventTitle: false,
            shareParticipantNamesWithAnalysis: false,
            now: Date(timeIntervalSince1970: 9_500)
        )

        XCTAssertTrue(approved, "A valid event selection must succeed on the first confirmation")
        XCTAssertEqual(appState.meetingTitle, "Manual title")
        XCTAssertEqual(appState.pendingCalendarEvent?.participants.map(\.displayName), ["Jana Nováková"])
        XCTAssertFalse(appState.pendingCalendarEvent?.shareParticipantNamesWithAnalysis ?? true)
    }

    @MainActor
    func testCalendarAccessRequestLoadsEventsAfterFullAccessIsGranted() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarAccessGrantedTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "CalendarAccessGrantedDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let event = candidate(id: "event", start: 10_000, end: 11_000)
        let provider = FakeCalendarEventProvider(
            candidates: [event],
            authorizationStatus: .notDetermined,
            requestResult: true
        )
        let appState = AppState(
            sessionManager: SessionManager(recordingsRoot: root),
            applicationSettingsStore: ApplicationSettingsStore(defaults: defaults),
            calendarEventProvider: provider,
            automaticallyManageVADModel: false
        )
        appState.setCalendarIntegrationEnabled(true)

        await appState.requestCalendarAccess()

        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(appState.calendarAuthorizationStatus, .fullAccess)
        XCTAssertEqual(appState.calendarEventCandidates.map(\.id), [event.id])
        XCTAssertNil(appState.calendarAccessError)
        XCTAssertFalse(appState.isRequestingCalendarAccess)
    }

    @MainActor
    func testCalendarAccessRequestShowsErrorWhenAccessIsNotGranted() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarAccessDeniedTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "CalendarAccessDeniedDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = FakeCalendarEventProvider(
            authorizationStatus: .notDetermined,
            requestResult: false
        )
        let appState = AppState(
            sessionManager: SessionManager(recordingsRoot: root),
            applicationSettingsStore: ApplicationSettingsStore(defaults: defaults),
            calendarEventProvider: provider,
            automaticallyManageVADModel: false
        )
        appState.setCalendarIntegrationEnabled(true)

        await appState.requestCalendarAccess()

        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(appState.calendarAuthorizationStatus, .notDetermined)
        XCTAssertNotNil(appState.calendarAccessError)
        XCTAssertFalse(appState.isRequestingCalendarAccess)
    }

    func testSnapshotEncodingContainsNoCalendarIdentifierOrEmailField() throws {
        let snapshot = CalendarEventSnapshot(
            source: .appleCalendar,
            title: "Planning",
            startsAt: Date(timeIntervalSince1970: 10_000),
            endsAt: Date(timeIntervalSince1970: 11_000),
            selectedAt: Date(timeIntervalSince1970: 9_500),
            participants: [
                ConfirmedParticipant(displayName: "Jana Nováková"),
            ],
            shareParticipantNamesWithAnalysis: false
        )

        let json = String(decoding: try SessionJSONCoder.makeEncoder().encode(snapshot), as: UTF8.self)

        XCTAssertFalse(json.localizedCaseInsensitiveContains("email"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("eventIdentifier"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("calendarIdentifier"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("location"))
        XCTAssertTrue(json.contains("Jana Nováková"))
    }

    private func candidate(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        isAllDay: Bool = false
    ) -> CalendarEventCandidate {
        CalendarEventCandidate(
            id: id,
            title: id,
            startsAt: Date(timeIntervalSince1970: start),
            endsAt: Date(timeIntervalSince1970: end),
            isAllDay: isAllDay,
            participants: []
        )
    }
}

@MainActor
private final class FakeCalendarEventProvider: CalendarEventProviding {
    var authorizationStatus: CalendarAuthorizationStatus
    let candidates: [CalendarEventCandidate]
    let requestResult: Bool
    private(set) var requestCount = 0

    init(
        candidates: [CalendarEventCandidate] = [],
        authorizationStatus: CalendarAuthorizationStatus = .fullAccess,
        requestResult: Bool = true
    ) {
        self.candidates = candidates
        self.authorizationStatus = authorizationStatus
        self.requestResult = requestResult
    }

    func requestFullAccess() async throws -> Bool {
        requestCount += 1
        if requestResult {
            authorizationStatus = .fullAccess
        }
        return requestResult
    }

    func eventCandidates(for query: CalendarEventQuery) throws -> [CalendarEventCandidate] {
        CalendarEventRanking.sorted(candidates, for: query.targetInterval)
    }
}
