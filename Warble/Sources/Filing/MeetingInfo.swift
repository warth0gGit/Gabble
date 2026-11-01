import EventKit
import Foundation

/// What the calendar says about the meeting a call belongs to.
struct MeetingInfo: Equatable {
    struct Person: Equatable, Hashable {
        var name: String
        var email: String?

        /// A stable key for matching the same person across meetings.
        var key: String { (email ?? name).lowercased() }
    }

    var title: String
    /// Everyone invited apart from you.
    var attendees: [Person]
    var organizer: String?
    /// The same for every meeting in a repeating series; nil for one-off meetings.
    var seriesID: String?
    var start: Date
    var end: Date
}

/// Finds the calendar meeting a call belongs to. Works with any calendar the
/// Mac's Calendar app shows (iCloud, Google, Exchange/Outlook).
@MainActor
final class CalendarLookup {
    private let store = EKEventStore()

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// The meeting happening at `date`, or nil if there isn't one (or no access).
    func meeting(at date: Date, appName: String) -> MeetingInfo? {
        guard isAuthorized else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-4 * 3600),
                                                 end: date.addingTimeInterval(3600), calendars: nil)
        let candidates = store.events(matching: predicate).compactMap { event -> MeetingCandidate<EKEvent>? in
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate else { return nil }
            let people = (event.attendees ?? []).filter { !$0.isCurrentUser }
            let text = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
            return MeetingCandidate(start: start, end: end, attendeeCount: people.count,
                                    mentionsCallApp: MeetingCandidate<EKEvent>.mentionsCallApp(text, appName: appName),
                                    payload: event)
        }
        guard let best = MeetingCandidate.best(of: candidates, at: date) else { return nil }
        return Self.info(from: best.payload)
    }

    private static func info(from event: EKEvent) -> MeetingInfo {
        let attendees = (event.attendees ?? []).filter { !$0.isCurrentUser }.map { participant in
            MeetingInfo.Person(name: displayName(of: participant), email: email(of: participant))
        }
        let series = event.hasRecurrenceRules
            ? (event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier) : nil
        return MeetingInfo(title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           attendees: attendees,
                           organizer: event.organizer.map(displayName(of:)),
                           seriesID: series,
                           start: event.startDate, end: event.endDate)
    }

    private static func email(of participant: EKParticipant) -> String? {
        let url = participant.url.absoluteString
        guard url.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(url.dropFirst("mailto:".count))
        return address.removingPercentEncoding ?? address
    }

    private static func displayName(of participant: EKParticipant) -> String {
        if let name = participant.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
           !name.contains("@") {
            return name
        }
        // No name: make one from the email address, e.g. "sarah.jones@x.com" → "Sarah Jones".
        let local = (email(of: participant) ?? participant.name ?? "Guest").split(separator: "@").first.map(String.init) ?? "Guest"
        return local.split(whereSeparator: { ".-_".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Picks which overlapping calendar event a call is. Pure, unit tested.
struct MeetingCandidate<Payload> {
    var start: Date
    var end: Date
    var attendeeCount: Int
    var mentionsCallApp: Bool
    var payload: Payload

    /// The event the call most likely belongs to: it must be under way (or
    /// about to start) when the call starts. Ties go to events with a call link,
    /// then with attendees, then the closest start time.
    static func best(of candidates: [MeetingCandidate], at date: Date) -> MeetingCandidate? {
        let live = candidates.filter {
            $0.start <= date.addingTimeInterval(15 * 60) && $0.end >= date.addingTimeInterval(-5 * 60)
        }
        return live.min { a, b in
            if a.mentionsCallApp != b.mentionsCallApp { return a.mentionsCallApp }
            if (a.attendeeCount > 0) != (b.attendeeCount > 0) { return a.attendeeCount > 0 }
            return abs(a.start.timeIntervalSince(date)) < abs(b.start.timeIntervalSince(date))
        }
    }

    static func mentionsCallApp(_ text: String, appName: String) -> Bool {
        let lower = text.lowercased()
        let hints = ["teams.microsoft", "zoom.us", "meet.google", "webex", "facetime", "slack.com/huddle"]
            + [appName.lowercased()]
        return hints.contains { !$0.isEmpty && lower.contains($0) }
    }
}
