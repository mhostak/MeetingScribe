import EventKit
import Foundation

@MainActor
protocol CalendarEventProviding {
    var authorizationStatus: CalendarAuthorizationStatus { get }

    func requestFullAccess() async throws -> Bool
    func eventCandidates(for query: CalendarEventQuery) throws -> [CalendarEventCandidate]
}

@MainActor
final class CalendarEventService: CalendarEventProviding {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var authorizationStatus: CalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .writeOnly: return .writeOnly
        case .fullAccess, .authorized: return .fullAccess
        @unknown default: return .restricted
        }
    }

    func requestFullAccess() async throws -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            throw CalendarIntegrationError.accessRequestFailed(error.localizedDescription)
        }
    }

    func eventCandidates(for query: CalendarEventQuery) throws -> [CalendarEventCandidate] {
        guard authorizationStatus.canReadEvents else {
            throw CalendarIntegrationError.fullAccessRequired
        }

        let predicate = eventStore.predicateForEvents(
            withStart: query.searchInterval.start,
            end: query.searchInterval.end,
            calendars: nil
        )
        let candidates = eventStore.events(matching: predicate).compactMap(makeCandidate)
        return CalendarEventRanking.sorted(candidates, for: query.targetInterval)
    }

    private func makeCandidate(from event: EKEvent) -> CalendarEventCandidate? {
        guard event.status != .canceled else { return nil }
        let normalizedTitle = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = normalizedTitle.isEmpty ? "Untitled calendar event" : normalizedTitle
        let eventID = CalendarEventIdentity.candidateID(
            eventIdentifier: event.eventIdentifier,
            calendarItemIdentifier: event.calendarItemIdentifier,
            startsAt: event.startDate
        )

        let attendees: [EKParticipant] = event.attendees ?? []
        let participants: [CalendarParticipantCandidate] = attendees.enumerated().compactMap {
            index, participant -> CalendarParticipantCandidate? in
            guard participant.participantType == .person,
                  !participant.isCurrentUser,
                  let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return nil
            }
            return CalendarParticipantCandidate(
                id: "\(eventID)#participant-\(index)",
                displayName: name
            )
        }

        return CalendarEventCandidate(
            id: eventID,
            title: title,
            startsAt: event.startDate,
            endsAt: max(event.endDate, event.startDate),
            isAllDay: event.isAllDay,
            participants: participants
        )
    }
}
