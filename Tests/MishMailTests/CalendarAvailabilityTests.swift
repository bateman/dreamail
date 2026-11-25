import XCTest

/// Pure availability logic for an invitation: time zones, all-day events,
/// recurring instances, and what does not count as busy.
final class CalendarAvailabilityTests: XCTestCase {

    private let rome = TimeZone(identifier: "Europe/Rome")!
    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ s: String) -> Date { CalendarClient.parseDateTime(s)! }

    private func timed(_ id: String, _ start: String, _ end: String, status: String = "confirmed",
                       transparency: String? = nil, uid: String? = nil,
                       me: String? = nil) -> GCalendarEvent {
        GCalendarEvent(id: id, status: status, summary: "S-\(id)", iCalUID: uid,
                       start: GEventDateTime(dateTime: start), end: GEventDateTime(dateTime: end),
                       transparency: transparency,
                       attendees: me.map { [GEventAttendee(email: "a@x.com", isSelf: true, responseStatus: $0)] })
    }

    private func allDay(_ id: String, _ start: String, _ end: String, zone: String? = nil,
                        transparency: String? = nil) -> GCalendarEvent {
        GCalendarEvent(id: id, start: GEventDateTime(date: start, timeZone: zone),
                       end: GEventDateTime(date: end, timeZone: zone), transparency: transparency)
    }

    private func ids(_ busy: [CalendarBusy]) -> [String] {
        busy.map {
            switch $0.source {
            case .event(_, let id, _): return id
            case .freeBusy(let calendar): return "fb:\(calendar)"
            }
        }
    }

    private func invite(_ start: String, _ end: String) -> CalendarSpan {
        CalendarSpan(start: at(start), end: at(end), isAllDay: false)
    }

    // MARK: - Spans

    func testTimedEventsUseTheirOwnOffsets() {
        let span = CalendarSpan.from(start: GEventDateTime(dateTime: "2026-03-10T10:00:00+01:00"),
                                     end: GEventDateTime(dateTime: "2026-03-10T11:30:00.000+01:00"),
                                     calendarTimeZone: "America/New_York", fallback: utc)
        XCTAssertEqual(span, CalendarSpan(start: at("2026-03-10T09:00:00Z"),
                                          end: at("2026-03-10T10:30:00Z"), isAllDay: false))
    }

    func testAllDayIsALocalDayInTheEventOrCalendarZoneWithExclusiveEnd() {
        let calendarZone = CalendarSpan.from(start: GEventDateTime(date: "2026-03-10"),
                                             end: GEventDateTime(date: "2026-03-11"),
                                             calendarTimeZone: "Europe/Rome", fallback: utc)
        XCTAssertEqual(calendarZone, CalendarSpan(start: at("2026-03-09T23:00:00Z"),
                                                  end: at("2026-03-10T23:00:00Z"), isAllDay: true))
        let eventZone = CalendarSpan.from(start: GEventDateTime(date: "2026-03-10", timeZone: "Asia/Tokyo"),
                                          end: GEventDateTime(date: "2026-03-11", timeZone: "Asia/Tokyo"),
                                          calendarTimeZone: "Europe/Rome", fallback: utc)
        XCTAssertEqual(eventZone?.start, at("2026-03-09T15:00:00Z"))
        let fallback = CalendarSpan.from(start: GEventDateTime(date: "2026-03-10"),
                                         end: GEventDateTime(date: "2026-03-11"),
                                         calendarTimeZone: "Not/AZone", fallback: utc)
        XCTAssertEqual(fallback?.start, at("2026-03-10T00:00:00Z"))
    }

    func testAllDayAcrossTheSpringDSTChangeIs23Hours() throws {
        let span = try XCTUnwrap(CalendarSpan.from(start: GEventDateTime(date: "2026-03-29"),
                                                   end: GEventDateTime(date: "2026-03-30"),
                                                   calendarTimeZone: "Europe/Rome", fallback: utc))
        XCTAssertEqual(span.end.timeIntervalSince(span.start), 23 * 3600)
    }

    func testUnreadableOrBackwardsTimesAreDropped() {
        XCTAssertNil(CalendarSpan.from(start: nil, end: GEventDateTime(date: "2026-01-01"),
                                       calendarTimeZone: nil, fallback: utc))
        XCTAssertNil(CalendarSpan.from(start: GEventDateTime(date: "2026-02-30"),
                                       end: GEventDateTime(date: "2026-03-01"),
                                       calendarTimeZone: nil, fallback: utc))
        XCTAssertNil(CalendarSpan.from(start: GEventDateTime(dateTime: "2026-01-01T10:00:00Z"),
                                       end: GEventDateTime(dateTime: "2026-01-01T09:00:00Z"),
                                       calendarTimeZone: nil, fallback: utc))
        XCTAssertNil(CalendarSpan.from(start: GEventDateTime(dateTime: "tomorrow"),
                                       end: GEventDateTime(dateTime: "2026-01-01T09:00:00Z"),
                                       calendarTimeZone: nil, fallback: utc))
        XCTAssertNil(CalendarSpan.from(start: GEventDateTime(date: "2026-01-01"),
                                       end: GEventDateTime(dateTime: "2026-01-01T09:00:00Z"),
                                       calendarTimeZone: nil, fallback: utc), "mixed kinds")
    }

    // MARK: - Overlap

    func testBackToBackIsNotAConflictButOverlapIs() {
        let meeting = invite("2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z")
        XCTAssertFalse(meeting.overlaps(invite("2026-01-05T11:00:00Z", "2026-01-05T12:00:00Z")))
        XCTAssertFalse(meeting.overlaps(invite("2026-01-05T09:00:00Z", "2026-01-05T10:00:00Z")))
        XCTAssertTrue(meeting.overlaps(invite("2026-01-05T10:59:00Z", "2026-01-05T12:00:00Z")))
        XCTAssertTrue(meeting.overlaps(invite("2026-01-05T09:00:00Z", "2026-01-05T13:00:00Z")))
    }

    func testZeroLengthInviteConflictsWithWhatIsRunningAtThatInstant() {
        let reminder = invite("2026-01-05T10:00:00Z", "2026-01-05T10:00:00Z")
        XCTAssertTrue(reminder.overlaps(invite("2026-01-05T09:30:00Z", "2026-01-05T10:30:00Z")))
        XCTAssertTrue(invite("2026-01-05T10:00:00Z", "2026-01-05T10:30:00Z").overlaps(reminder))
        XCTAssertFalse(reminder.overlaps(invite("2026-01-05T09:00:00Z", "2026-01-05T10:00:00Z")))
    }

    // MARK: - What counts as busy

    func testCancelledFreeDeclinedAndTheInviteItselfAreNotBusy() {
        let events = [
            timed("busy", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z"),
            timed("cancelled", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", status: "cancelled"),
            timed("free", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", transparency: "transparent"),
            timed("declined", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", me: "declined"),
            timed("tentative", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", me: "tentative"),
            timed("needsAction", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", me: "needsAction"),
            timed("itself", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", uid: "invite-uid@y.com"),
        ]
        let invite = CalendarInviteIdentity(uid: "invite-uid@y.com",
                                            span: self.invite("2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z"))
        let busy = CalendarAvailability.busy(events: events, calendarId: "primary",
                                             calendarTimeZone: "UTC", excluding: invite)
        XCTAssertEqual(ids(busy), ["busy", "tentative", "needsAction"])
        var empty = invite
        empty.uid = ""
        let withoutUID = CalendarAvailability.busy(events: events, calendarId: "primary",
                                                   calendarTimeZone: "UTC", excluding: empty)
        XCTAssertTrue(ids(withoutUID).contains("itself"), "an empty UID excludes nothing")
    }

    /// S3: a forged invitation that reuses a real event's UID, at another
    /// time, must not hide that event from the conflicts.
    func testAReusedUIDAtAnotherTimeDoesNotHideARealEvent() {
        let real = timed("real", "2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z", uid: "real-uid@google.com")
        let forged = CalendarInviteIdentity(uid: "real-uid@google.com",
                                            span: invite("2026-01-05T10:30:00Z", "2026-01-05T11:30:00Z"))
        let busy = CalendarAvailability.busy(events: [real], calendarId: "primary",
                                             calendarTimeZone: "UTC", excluding: forged)
        XCTAssertEqual(ids(busy), ["real"])
        XCTAssertEqual(ids(CalendarAvailability.check(invite: forged.span, against: busy).conflicts), ["real"])
    }

    /// R6: free/busy cannot tell the invitation's own event from another;
    /// a period at exactly its time is left out.
    func testFreeBusyPeriodAtTheInvitationsOwnTimeIsLeftOut() {
        let own = invite("2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z")
        let fb = [CalendarFreeBusy(calendarId: "primary",
                                   busy: [DateInterval(start: own.start, end: own.end),
                                          DateInterval(start: at("2026-01-05T10:30:00Z"), duration: 3600)],
                                   failed: false)]
        let busy = CalendarAvailability.busy(freeBusy: fb, invite: own)
        XCTAssertEqual(busy.map(\.span.start), [at("2026-01-05T10:30:00Z")])
        XCTAssertEqual(CalendarAvailability.busy(freeBusy: fb).count, 2, "without an invite, all count")
    }

    // MARK: - The check

    func testRecurringInstancesConflictOnlyWhereTheyOverlap() {
        // A weekly series expanded by Google (singleEvents=true), in Rome.
        let instances = ["05", "12", "19"].map { day in
            timed("weekly_202601\(day)", "2026-01-\(day)T10:00:00+01:00", "2026-01-\(day)T11:00:00+01:00")
        }
        let busy = CalendarAvailability.busy(events: instances, calendarId: "primary",
                                             calendarTimeZone: "Europe/Rome", excluding: nil)
        let result = CalendarAvailability.check(invite: invite("2026-01-12T09:30:00Z", "2026-01-12T10:30:00Z"),
                                                against: busy)
        XCTAssertEqual(ids(result.conflicts), ["weekly_20260112"])
        XCTAssertFalse(result.isFree)
    }

    func testInviteInAnotherZoneIsComparedInAbsoluteTime() {
        // 10:00 in New York is 16:00 in Rome.
        let busy = CalendarAvailability.busy(
            events: [timed("rome", "2026-01-05T16:00:00+01:00", "2026-01-05T17:00:00+01:00")],
            calendarId: "primary", calendarTimeZone: "Europe/Rome", excluding: nil)
        let clash = CalendarAvailability.check(
            invite: invite("2026-01-05T10:00:00-05:00", "2026-01-05T10:30:00-05:00"), against: busy)
        XCTAssertEqual(ids(clash.conflicts), ["rome"])
        let clear = CalendarAvailability.check(
            invite: invite("2026-01-05T11:00:00-05:00", "2026-01-05T11:30:00-05:00"), against: busy)
        XCTAssertTrue(clear.isFree)
    }

    func testAllDayBusyEventsAreReportedApartAndFreeOnesNotAtAll() {
        let events = [
            allDay("trip", "2026-01-05", "2026-01-07"),
            allDay("birthday", "2026-01-05", "2026-01-06", transparency: "transparent"),
            allDay("nextWeek", "2026-01-12", "2026-01-13"),
            timed("standup", "2026-01-05T09:00:00+01:00", "2026-01-05T09:15:00+01:00"),
        ]
        let busy = CalendarAvailability.busy(events: events, calendarId: "primary",
                                             calendarTimeZone: "Europe/Rome", excluding: nil)
        let result = CalendarAvailability.check(
            invite: invite("2026-01-05T08:00:00Z", "2026-01-05T09:00:00Z"), against: busy)
        XCTAssertEqual(ids(result.conflicts), ["standup"])
        XCTAssertEqual(ids(result.allDayConflicts), ["trip"])
    }

    func testAllDayInviteConflictsWithTimedEventsThatDay() {
        let invite = CalendarSpan.from(start: GEventDateTime(date: "2026-01-05"),
                                       end: GEventDateTime(date: "2026-01-06"),
                                       calendarTimeZone: "Europe/Rome", fallback: utc)!
        let busy = CalendarAvailability.busy(
            events: [timed("late", "2026-01-05T23:30:00+01:00", "2026-01-06T00:30:00+01:00"),
                     timed("nextDay", "2026-01-06T00:00:00+01:00", "2026-01-06T01:00:00+01:00")],
            calendarId: "primary", calendarTimeZone: "Europe/Rome", excluding: nil)
        XCTAssertEqual(ids(CalendarAvailability.check(invite: invite, against: busy).conflicts), ["late"])
    }

    func testFreeBusyPeriodsCountAndIncompleteIsKept() {
        let fb = [CalendarFreeBusy(calendarId: "work@x.com",
                                   busy: [DateInterval(start: at("2026-01-05T10:00:00Z"), duration: 1800)],
                                   failed: false)]
        let result = CalendarAvailability.check(
            invite: invite("2026-01-05T10:15:00Z", "2026-01-05T11:00:00Z"),
            against: CalendarAvailability.busy(freeBusy: fb), incomplete: true)
        XCTAssertEqual(ids(result.conflicts), ["fb:work@x.com"])
        XCTAssertTrue(result.isIncomplete)
    }

    func testConflictsAreSortedEarliestFirst() {
        let busy = CalendarAvailability.busy(
            events: [timed("b", "2026-01-05T10:30:00Z", "2026-01-05T11:30:00Z"),
                     timed("a", "2026-01-05T09:30:00Z", "2026-01-05T10:30:00Z")],
            calendarId: "primary", calendarTimeZone: "UTC", excluding: nil)
        let result = CalendarAvailability.check(invite: invite("2026-01-05T10:00:00Z", "2026-01-05T11:00:00Z"),
                                                against: busy)
        XCTAssertEqual(ids(result.conflicts), ["a", "b"])
    }

    // MARK: - Query window

    func testQueryWindowCoversWholeLocalDays() {
        let window = CalendarAvailability.queryWindow(
            for: invite("2026-01-05T22:30:00Z", "2026-01-05T23:30:00Z"), in: rome)
        // 23:30 and 00:30 in Rome: two local days.
        XCTAssertEqual(window.start, at("2026-01-04T23:00:00Z"))
        XCTAssertEqual(window.end, at("2026-01-06T23:00:00Z"))
        let point = CalendarAvailability.queryWindow(
            for: invite("2026-01-05T10:00:00Z", "2026-01-05T10:00:00Z"), in: utc)
        XCTAssertEqual(point, DateInterval(start: at("2026-01-05T00:00:00Z"), end: at("2026-01-06T00:00:00Z")))
    }
}
