import Foundation

/// When an event happens, in absolute time.
struct CalendarSpan: Equatable, Sendable {
    var start: Date
    /// Exclusive. Equal to `start` for a zero-length event.
    var end: Date
    var isAllDay: Bool

    /// The span of a Calendar API time pair. Timed events carry their own
    /// offset; an all-day `date` is a local day in the event's time zone
    /// (`start.timeZone`), else the calendar's, else `fallback`. Its end
    /// date is exclusive, as Google sends it. Nil when unreadable or when
    /// the end comes before the start.
    static func from(start: GEventDateTime?, end: GEventDateTime?,
                     calendarTimeZone: String?, fallback: TimeZone) -> CalendarSpan? {
        guard let start, let end else { return nil }
        if let s = start.dateTime, let e = end.dateTime {
            guard let a = CalendarClient.parseDateTime(s), let b = CalendarClient.parseDateTime(e),
                  b >= a else { return nil }
            return CalendarSpan(start: a, end: b, isAllDay: false)
        }
        if let s = start.date, let e = end.date {
            let zone = [start.timeZone, calendarTimeZone].lazy.compactMap { $0 }
                .compactMap(TimeZone.init(identifier:)).first ?? fallback
            guard let a = localMidnight(s, in: zone), let b = localMidnight(e, in: zone),
                  b >= a else { return nil }
            return CalendarSpan(start: a, end: b, isAllDay: true)
        }
        return nil
    }

    /// Midnight of `yyyy-MM-dd` in `zone` (DST days are 23 or 25 hours).
    static func localMidnight(_ day: String, in zone: TimeZone) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, day.count == 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        // `date(from:)` is lenient (Feb 30 becomes Mar 2): read it back.
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
        return date
    }

    /// The same time, within a second (RFC 3339 and ICS carry whole
    /// seconds). How an invitation is matched with Google's event: a shared
    /// UID alone is something any sender can copy.
    func sameTime(as other: CalendarSpan) -> Bool {
        abs(start.timeIntervalSince(other.start)) < 1 && abs(end.timeIntervalSince(other.end)) < 1
    }

    /// Half-open overlap: back-to-back events do not conflict. A
    /// zero-length span conflicts with what is running at its instant.
    func overlaps(_ other: CalendarSpan) -> Bool {
        func contains(_ span: CalendarSpan, _ instant: Date) -> Bool {
            span.start <= instant && instant < span.end
        }
        if start == end { return contains(other, start) }
        if other.start == other.end { return contains(self, other.start) }
        return start < other.end && other.start < end
    }
}

/// A busy period that can conflict with an invitation.
struct CalendarBusy: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// An event the user can see (title stays local, never logged).
        case event(calendarId: String, eventId: String, summary: String?)
        /// A free/busy period: no details.
        case freeBusy(calendarId: String)
    }
    var span: CalendarSpan
    var source: Source
}

/// What the invitation card would say.
struct CalendarAvailabilityResult: Equatable, Sendable {
    /// Timed events (or busy periods) overlapping the invitation.
    var conflicts: [CalendarBusy]
    /// All-day busy events on the same day(s): shown softly, they are often
    /// trips or holidays rather than a clash.
    var allDayConflicts: [CalendarBusy]
    /// Some calendar could not be checked, so "free" is not certain.
    var isIncomplete: Bool

    var isFree: Bool { conflicts.isEmpty && allDayConflicts.isEmpty }
}

/// The invitation being checked: its UID and its time, as the ICS says.
struct CalendarInviteIdentity: Equatable, Sendable {
    var uid: String
    var span: CalendarSpan
}

/// Pure availability logic for an invitation against the user's calendars.
/// Recurring events must come expanded (`singleEvents`), as the client asks.
enum CalendarAvailability {
    /// The busy periods among `events` of one calendar. Not busy: cancelled
    /// events, events marked free ("transparent"), events the user declined,
    /// and the invitation itself: same iCalendar UID *and* same time (Google
    /// puts an invite on the calendar as soon as it arrives; a forged invite
    /// that reuses a real event's UID with another time must not hide it).
    static func busy(events: [GCalendarEvent], calendarId: String, calendarTimeZone: String?,
                     excluding invite: CalendarInviteIdentity?,
                     fallback: TimeZone = .current) -> [CalendarBusy] {
        events.compactMap { event in
            guard event.status != "cancelled",
                  event.transparency != "transparent",
                  event.selfResponse != "declined" else { return nil }
            guard let span = CalendarSpan.from(start: event.start, end: event.end,
                                               calendarTimeZone: calendarTimeZone,
                                               fallback: fallback) else { return nil }
            if let invite, !invite.uid.isEmpty, event.iCalUID == invite.uid,
               span.sameTime(as: invite.span) { return nil }
            return CalendarBusy(span: span, source: .event(calendarId: calendarId, eventId: event.id,
                                                           summary: event.summary))
        }
    }

    /// Busy periods from free/busy-only calendars. Free/busy cannot tell the
    /// invitation's own event from another one, so a period at exactly the
    /// invitation's time is left out; the caller marks the result
    /// incomplete whenever free/busy was used.
    static func busy(freeBusy: [CalendarFreeBusy], invite: CalendarSpan? = nil) -> [CalendarBusy] {
        freeBusy.flatMap { calendar in
            calendar.busy.filter { period in
                guard let invite else { return true }
                return !CalendarSpan(start: period.start, end: period.end, isAllDay: false)
                    .sameTime(as: invite)
            }.map {
                CalendarBusy(span: CalendarSpan(start: $0.start, end: $0.end, isAllDay: false),
                             source: .freeBusy(calendarId: calendar.calendarId))
            }
        }
    }

    /// The conflicts of `invite` among `busy`, earliest first.
    static func check(invite: CalendarSpan, against busy: [CalendarBusy],
                      incomplete: Bool = false) -> CalendarAvailabilityResult {
        let overlapping = busy.filter { $0.span.overlaps(invite) }
            .sorted { ($0.span.start, $0.span.end) < ($1.span.start, $1.span.end) }
        return CalendarAvailabilityResult(
            conflicts: overlapping.filter { !$0.span.isAllDay },
            allDayConflicts: overlapping.filter { $0.span.isAllDay },
            isIncomplete: incomplete)
    }

    /// The window to ask Google about for one invitation: its own span,
    /// widened to whole days in `zone` so all-day events are included.
    static func queryWindow(for invite: CalendarSpan, in zone: TimeZone) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: invite.start)
        let lastInstant = invite.end > invite.start ? invite.end.addingTimeInterval(-1) : invite.start
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastInstant))
            ?? invite.end
        return DateInterval(start: start, end: max(end, start))
    }
}
