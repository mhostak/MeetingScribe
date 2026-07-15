import Foundation

enum CalendarAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess

    var displayName: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .writeOnly: return "Write-only access"
        case .fullAccess: return "Allowed"
        }
    }

    var canReadEvents: Bool {
        self == .fullAccess
    }
}

struct CalendarParticipantCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
}

struct CalendarEventCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let isAllDay: Bool
    let participants: [CalendarParticipantCandidate]

    var interval: DateInterval {
        DateInterval(start: startsAt, end: max(endsAt, startsAt))
    }
}

struct CalendarEventQuery: Equatable, Sendable {
    let targetInterval: DateInterval
    let searchInterval: DateInterval
}

enum CalendarMetadataSource: String, Codable, Equatable, Sendable {
    case appleCalendar
}

struct ConfirmedParticipant: Codable, Equatable, Sendable {
    var displayName: String
}

struct CalendarEventSnapshot: Codable, Equatable, Sendable {
    var source: CalendarMetadataSource
    var title: String
    var startsAt: Date
    var endsAt: Date
    var selectedAt: Date
    var participants: [ConfirmedParticipant]
    var shareParticipantNamesWithAnalysis: Bool
}

enum CalendarIntegrationError: Error, Equatable, LocalizedError {
    case integrationDisabled
    case fullAccessRequired
    case accessRequestFailed(String)
    case eventLoadingFailed(String)

    var errorDescription: String? {
        switch self {
        case .integrationDisabled:
            return "Apple Calendar integration is disabled."
        case .fullAccessRequired:
            return "Full Calendar access is required to read events."
        case let .accessRequestFailed(detail):
            return "Calendar access could not be requested: \(detail)"
        case let .eventLoadingFailed(detail):
            return "Calendar events could not be loaded: \(detail)"
        }
    }
}

enum CalendarEventRanking {
    static func sorted(
        _ candidates: [CalendarEventCandidate],
        for targetInterval: DateInterval
    ) -> [CalendarEventCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return !lhs.isAllDay }
            let lhsOverlaps = lhs.interval.intersects(targetInterval)
            let rhsOverlaps = rhs.interval.intersects(targetInterval)
            if lhsOverlaps != rhsOverlaps { return lhsOverlaps }

            let lhsDistance = distance(from: lhs.interval, to: targetInterval)
            let rhsDistance = distance(from: rhs.interval, to: targetInterval)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func distance(from event: DateInterval, to target: DateInterval) -> TimeInterval {
        if event.intersects(target) { return 0 }
        if event.end < target.start { return target.start.timeIntervalSince(event.end) }
        return event.start.timeIntervalSince(target.end)
    }
}
