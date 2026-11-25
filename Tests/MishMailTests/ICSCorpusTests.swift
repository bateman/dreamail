import XCTest
import GRDB

/// Walks the synthetic invite corpus (`ICSCorpus`): what each sender's
/// shape parses to, what the RSVP sends back, and the limits that keep a
/// malformed or hostile ICS from blocking the app or growing its memory.
final class ICSCorpusTests: XCTestCase {

    private func one(_ ics: String, file: StaticString = #filePath,
                     line: UInt = #line) throws -> CalendarInvite {
        try XCTUnwrap(CalendarInvite.parse(ICSCorpus.crlf(ics)), file: file, line: line)
    }

    private func replyLines(_ invite: CalendarInvite, _ status: CalendarInvite.RSVP = .accepted,
                            attendee: String = "guest@example.org",
                            name: String = "Guest One") -> [String] {
        CalendarInvite.unfold(invite.replyICS(status: status, attendeeEmail: attendee,
                                              attendeeName: name))
    }

    // MARK: - Senders

    func testGoogleInvite() throws {
        let invite = try one(ICSCorpus.google)
        XCTAssertEqual(invite.method, .request)
        XCTAssertTrue(invite.isActionable)
        XCTAssertEqual(invite.uid, "0a1b2c3d4e5f@google.com")
        XCTAssertEqual(invite.summary, "Quarterly review")
        XCTAssertEqual(invite.location, "Room 4, Building B")
        XCTAssertEqual(invite.organizerEmail, "ada@example.com")
        XCTAssertEqual(invite.organizerName, "Ada Organizer")
        XCTAssertEqual(invite.attendeeEmails, ["guest@example.org", "ada@example.com"])
        XCTAssertEqual(invite.start?.timeIntervalSince1970, 1_796_288_400)
        XCTAssertEqual(invite.end?.timeIntervalSince1970, 1_796_292_000)
        XCTAssertEqual(invite.status, "CONFIRMED")
        XCTAssertFalse(invite.isRecurring)
        XCTAssertTrue(invite.description.hasPrefix("Join: https://meet.example.com/"))
    }

    func testOutlookInviteWithWindowsZoneAndAlarm() throws {
        let invite = try one(ICSCorpus.outlook)
        XCTAssertTrue(invite.isActionable)
        XCTAssertEqual(invite.summary, "Planning")
        XCTAssertEqual(invite.description, "Weekly sync.\n", "VALARM DESCRIPTION must not win")
        XCTAssertEqual(invite.organizerEmail, "olaf@example.net")
        XCTAssertEqual(invite.attendeeEmails, ["guest@example.org"])
        // 10:00 W. Europe (CET in December) = 09:00 UTC.
        XCTAssertEqual(invite.start?.timeIntervalSince1970, 1_796_288_400)
        XCTAssertEqual(invite.end?.timeIntervalSince1970, 1_796_292_000)
        XCTAssertNil(invite.unresolvedTZID)
    }

    func testAppleInviteWithIANAZoneAndCaretEscapes() throws {
        let invite = try one(ICSCorpus.apple)
        XCTAssertTrue(invite.isActionable)
        XCTAssertEqual(invite.summary, "Pranzo di lavoro")
        XCTAssertEqual(invite.organizerEmail, "bea@example.it")
        XCTAssertEqual(invite.organizerName, "Bea \"Boss\" Apple")
        // 15:00 Europe/Rome in July (CEST) = 13:00 UTC.
        XCTAssertEqual(invite.start?.timeIntervalSince1970, 1_783_688_400)
        XCTAssertEqual(invite.end?.timeIntervalSince1970, 1_783_692_000)
        XCTAssertEqual(Set(invite.attendeeEmails), ["guest@example.org", "bea@example.it"])
    }

    func testLFAndCRLFAndBareCRParseAlike() throws {
        let lf = try XCTUnwrap(CalendarInvite.parse(ICSCorpus.google))
        let crlf = try one(ICSCorpus.google)
        let cr = try XCTUnwrap(CalendarInvite.parse(
            ICSCorpus.google.replacingOccurrences(of: "\n", with: "\r")))
        for other in [crlf, cr] {
            XCTAssertEqual(other.uid, lf.uid)
            XCTAssertEqual(other.start, lf.start)
            XCTAssertEqual(other.attendeeEmails, lf.attendeeEmails)
        }
    }

    // MARK: - Time shapes

    func testFloatingTimeIsReadInTheLocalZone() throws {
        let invite = try one(ICSCorpus.floating)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(invite.start))
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 12, 1, 9, 0])
        XCTAssertNil(invite.unresolvedTZID)
        XCTAssertFalse(invite.isAllDay)
    }

    func testAllDayMultiDayKeepsExclusiveEnd() throws {
        let invite = try one(ICSCorpus.allDayMultiDay)
        XCTAssertTrue(invite.isAllDay)
        let lines = replyLines(invite)
        XCTAssertTrue(lines.contains("DTSTART;VALUE=DATE:20261224"), "\(lines)")
        XCTAssertTrue(lines.contains("DTEND;VALUE=DATE:20261227"), "\(lines)")
        let when = invite.whenDescription(locale: Locale(identifier: "en_US"))
        XCTAssertTrue(when.contains("–"), "a three-day event shows a range: \(when)")
    }

    func testDurationGivesTheEnd() throws {
        let invite = try one(ICSCorpus.durationOnly)
        XCTAssertEqual(try XCTUnwrap(invite.end).timeIntervalSince(try XCTUnwrap(invite.start)), 5_400)
    }

    // MARK: - Recurrence

    func testRecurringSeriesIsLabelled() throws {
        let invite = try one(ICSCorpus.recurringWeekly)
        XCTAssertTrue(invite.isRecurring)
        XCTAssertEqual(invite.repeatDescription, "Repeats every 2 weeks")
        XCTAssertEqual(invite.summary, "1:1")
        XCTAssertEqual(invite.sequence, 1)
        XCTAssertTrue(invite.isActionable)
        XCTAssertEqual(try one(ICSCorpus.rdateOnly).repeatDescription, "Repeats")
        XCTAssertNil(try one(ICSCorpus.google).repeatDescription)
    }

    func testSeriesWithExceptionGivesBothAndPrefersTheInstance() throws {
        let all = CalendarInvite.parseAll(ICSCorpus.crlf(ICSCorpus.seriesWithException))
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.uid)), ["series@example.com"])
        let instance = try XCTUnwrap(CalendarInvite.preferred(from: all))
        XCTAssertEqual(instance.recurrenceIdLine,
                       "RECURRENCE-ID;TZID=Europe/Rome:20261214T100000")
        XCTAssertEqual(instance.sequence, 2)
        XCTAssertFalse(instance.isRecurring, "the instance carries no RRULE")
        // 11:00 Rome (CET) = 10:00 UTC.
        XCTAssertEqual(instance.start?.timeIntervalSince1970, 1_797_242_400)
        let lines = replyLines(instance)
        XCTAssertTrue(lines.contains("RECURRENCE-ID;TZID=Europe/Rome:20261214T100000"), "\(lines)")
        XCTAssertTrue(lines.contains("SEQUENCE:2"))
    }

    // MARK: - Updates and cancellations

    func testUpdateKeepsUIDAndRaisesSequence() throws {
        let first = try one(ICSCorpus.google)
        let update = try one(ICSCorpus.googleUpdated)
        XCTAssertEqual(first.uid, update.uid)
        XCTAssertEqual(update.sequence, 2)
        XCTAssertEqual(update.start?.timeIntervalSince1970, 1_796_292_000)
        XCTAssertTrue(replyLines(update).contains("SEQUENCE:2"))
    }

    func testCancellationsAreNeverAnswered() throws {
        for ics in [ICSCorpus.cancelWhole, ICSCorpus.cancelInstance, ICSCorpus.requestMarkedCancelled] {
            let invite = try one(ics)
            XCTAssertTrue(invite.isCancelled, ics)
            XCTAssertFalse(invite.isActionable, ics)
        }
        XCTAssertNotNil(try one(ICSCorpus.cancelInstance).recurrenceIdLine)
    }

    // MARK: - Other methods

    func testReceivedReplySaysWhoAnsweredAndHow() throws {
        let invite = try one(ICSCorpus.replyReceived)
        XCTAssertEqual(invite.method, .reply)
        XCTAssertFalse(invite.isActionable)
        XCTAssertEqual(invite.replyAttendeeEmail, "guest@example.org")
        XCTAssertEqual(invite.replyPartstat, "DECLINED")
        XCTAssertNil(try one(ICSCorpus.google).replyAttendeeEmail, "only for METHOD:REPLY")
    }

    func testOnlyRequestOffersButtons() throws {
        XCTAssertEqual(try one(ICSCorpus.counter).method, .counter)
        XCTAssertEqual(try one(ICSCorpus.declineCounter).method, .declineCounter)
        XCTAssertEqual(try one(ICSCorpus.publish).method, .publish)
        for ics in [ICSCorpus.counter, ICSCorpus.declineCounter, ICSCorpus.publish,
                    ICSCorpus.replyReceived] {
            XCTAssertFalse(try one(ics).isActionable, ics)
        }
        let withParam = try one(ICSCorpus.methodWithParam)
        XCTAssertEqual(withParam.method, .request)
        XCTAssertTrue(withParam.isActionable)
    }

    func testEveryEventOfAMultiEventDocument() {
        let all = CalendarInvite.parseAll(ICSCorpus.crlf(ICSCorpus.twoEvents))
        XCTAssertEqual(all.map(\.uid), ["slot-a@example.com", "slot-b@example.com"])
    }

    // MARK: - Text and encodings

    func testTextEscapes() throws {
        let invite = try one(ICSCorpus.escapes)
        // The newline is shown as a space on the card.
        XCTAssertEqual(invite.summary, "Budget, Q3; review \\ notes second line")
        XCTAssertEqual(invite.location, "Via Roma 1, Bari")
        XCTAssertEqual(invite.organizerName, "Rossi, Anna")
        let lines = replyLines(invite)
        XCTAssertTrue(lines.contains(#"SUMMARY:Budget\, Q3\; review \\ notes second line"#), "\(lines)")
        XCTAssertTrue(lines.contains(#"ORGANIZER;CN="Rossi, Anna":mailto:anna@example.it"#), "\(lines)")
    }

    func testFoldInsideAUTF8CharacterIsJoinedBeforeDecoding() throws {
        let invite = try XCTUnwrap(CalendarInvite.parse(ICSCorpus.foldedInsideUTF8Character))
        XCTAssertEqual(invite.summary, "Café del lunedì")
    }

    func testCharsets() throws {
        XCTAssertEqual(try XCTUnwrap(CalendarInvite.parse(ICSCorpus.latin1)).summary,
                       "Réunion café")
        XCTAssertEqual(try XCTUnwrap(CalendarInvite.parse(ICSCorpus.utf16LE)).uid,
                       "floating@example.com")
        XCTAssertEqual(try XCTUnwrap(CalendarInvite.parse(ICSCorpus.utf8BOM)).uid,
                       "floating@example.com")
    }

    /// Outlook / Calendly: the invite is only an inline `text/calendar`
    /// part (base64url in the Gmail payload, no attachmentId).
    func testInlineCalendarPartIsDecodedFromTheGmailPayload() throws {
        let ics = ICSCorpus.crlf(ICSCorpus.outlook)
        let json = """
        {
          "id": "m-inline", "threadId": "t-inline", "internalDate": "0",
          "payload": {
            "mimeType": "multipart/alternative",
            "headers": [{"name": "From", "value": "Olaf <olaf@example.net>"}],
            "parts": [
              {"mimeType": "text/plain", "body": {"data": "\(Data("Planning".utf8).base64URLEncoded())"}},
              {"mimeType": "text/calendar; charset=\\"utf-8\\"; method=REQUEST",
               "body": {"size": \(ics.utf8.count), "data": "\(Data(ics.utf8).base64URLEncoded())"}}
            ]
          }
        }
        """
        let g = try JSONDecoder().decode(GMessage.self, from: Data(json.utf8))
        let data = try XCTUnwrap(MessageParser.inlineCalendarData(in: g))
        XCTAssertEqual(CalendarInvite.parse(data)?.uid,
                       "040000008200E00074C5B7101A82E00800000000A0B1C2D3E4F5")
        let (_, attachments) = MessageParser.parse(g, accountId: "guest@example.org")
        XCTAssertEqual(attachments.filter { AttachmentRow.isInlineCalendarId($0.gmailAttachmentId) }.count, 1)
    }

    // MARK: - Reply (iTIP REPLY)

    func testReplyCarriesWhatTheOrganizerMatchesOn() throws {
        let invite = try one(ICSCorpus.google)
        for status in CalendarInvite.RSVP.allCases {
            let raw = invite.replyICS(status: status, attendeeEmail: "alias@example.org",
                                      attendeeName: "Guest One")
            XCTAssertTrue(raw.hasSuffix("\r\n"))
            XCTAssertFalse(raw.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                           "CRLF only")
            for physical in raw.components(separatedBy: "\r\n") {
                XCTAssertLessThanOrEqual(physical.utf8.count, 75, physical)
            }
            let lines = CalendarInvite.unfold(raw)
            XCTAssertTrue(lines.contains("METHOD:REPLY"))
            XCTAssertTrue(lines.contains("UID:0a1b2c3d4e5f@google.com"))
            XCTAssertTrue(lines.contains("SEQUENCE:0"))
            XCTAssertTrue(lines.contains("ORGANIZER;CN=\"Ada Organizer\":mailto:ada@example.com"),
                          "\(lines)")
            // The send-as alias the invite was answered from, with its PARTSTAT.
            XCTAssertTrue(lines.contains(
                "ATTENDEE;PARTSTAT=\(status.rawValue);ROLE=REQ-PARTICIPANT;CN=\"Guest One\":mailto:alias@example.org"),
                "\(lines)")
            XCTAssertEqual(lines.filter { $0.hasPrefix("ATTENDEE") }.count, 1)
            let stamp = try XCTUnwrap(lines.first { $0.hasPrefix("DTSTAMP:") })
            XCTAssertNotNil(stamp.range(of: #"^DTSTAMP:\d{8}T\d{6}Z$"#, options: .regularExpression))
        }
        let att = invite.replyAttachment(status: .declined, attendeeEmail: "guest@example.org")
        XCTAssertEqual(att.mimeType, "text/calendar; method=REPLY")
        XCTAssertEqual(invite.replySubject(status: .declined), "Declined: Quarterly review")
    }

    func testReplyParamsCannotAddLines() throws {
        let invite = try one(ICSCorpus.spoofedOrganizerName)
        let lines = replyLines(invite, name: "Me \"Quoted\"\r\nATTENDEE:mailto:y@example.net")
        XCTAssertEqual(lines.filter { $0.hasPrefix("ATTENDEE") }.count, 1, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("mailto:x@example.net") && !$0.hasPrefix("ORGANIZER") })
        let attendee = try XCTUnwrap(lines.first { $0.hasPrefix("ATTENDEE") })
        XCTAssertTrue(attendee.contains("^'Quoted^'"), attendee)
        XCTAssertEqual(CalendarInvite.escapeParam("a^b"), "\"a^^b\"")
        XCTAssertEqual(CalendarInvite.escapeParam("Plain"), "Plain")
    }

    // MARK: - Hostile input

    func testOrganizerMustBeOnePlainAddress() throws {
        for ics in [ICSCorpus.organizerList, ICSCorpus.organizerDisplayName, ICSCorpus.noOrganizer] {
            let invite = try one(ics)
            XCTAssertEqual(invite.method, .request)
            XCTAssertFalse(invite.hasValidOrganizer, ics)
            XCTAssertFalse(invite.isActionable, ics)
        }
        for bad in ["", "a", "a@b", "@example.com", "a@.example.com", "a@example.com.",
                    "a@exa..mple.com", "a b@example.com", "a@example.com\r\nBcc: x@y.z",
                    "a@b@example.com", "\"a\"@example.com", "ä@example.com",
                    "a@example.com\u{202E}"] {
            XCTAssertFalse(CalendarInvite.isPlainAddress(bad), bad)
        }
        for good in ["ada@example.com", "first.last+tag@sub.example.co.uk", "x_y-z@example.it"] {
            XCTAssertTrue(CalendarInvite.isPlainAddress(good), good)
        }
    }

    func testOrganizerNameIsCleanedForDisplay() throws {
        let invite = try one(ICSCorpus.spoofedOrganizerName)
        XCTAssertTrue(invite.hasValidOrganizer)
        XCTAssertFalse(invite.organizerName.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertFalse(invite.organizerName.contains("\n"))
        XCTAssertEqual(CalendarInvite.displaySafe("a\u{2066}b\u{0007}c\nd", limit: 10), "abc d")
        XCTAssertEqual(CalendarInvite.displaySafe(String(repeating: "y", count: 20), limit: 5), "yyyyy…")
    }

    func testOrganizerOtherThanTheSenderIsDetected() throws {
        let invite = try one(ICSCorpus.google)
        XCTAssertTrue(invite.organizerIsSender(senderEmail: "ADA@example.com"))
        XCTAssertFalse(invite.organizerIsSender(senderEmail: "notifications@example.net"))
        XCTAssertFalse(invite.organizerIsSender(senderEmail: ""))
    }

    func testAbsurdDatesReadAsNoTime() {
        let all = CalendarInvite.parseAll(ICSCorpus.crlf(ICSCorpus.absurdDates))
        XCTAssertEqual(all.count, 5)
        let byUID = Dictionary(uniqueKeysWithValues: all.map { ($0.uid, $0) })
        XCTAssertNil(byUID["absurd-1@example.com"]?.start)
        XCTAssertNil(byUID["absurd-1@example.com"]?.end)
        XCTAssertEqual(byUID["absurd-1@example.com"]?.sequence, 0)
        XCTAssertNil(byUID["absurd-2@example.com"]?.start, "Feb 30 must not roll into March")
        XCTAssertEqual(byUID["absurd-2@example.com"]?.sequence, 0)
        XCTAssertNotNil(byUID["absurd-3@example.com"]?.start)
        XCTAssertNil(byUID["absurd-3@example.com"]?.end, "an endless DURATION is dropped")
        XCTAssertNil(byUID["absurd-4@example.com"]?.end, "an end before the start is dropped")
        XCTAssertNil(byUID["absurd-5@example.com"]?.start)
        XCTAssertEqual(byUID["absurd-1@example.com"]?.whenDescription(), "Time not specified")
        XCTAssertNil(CalendarInvite.parseDuration("P" + String(repeating: "9", count: 400) + "W"))
        XCTAssertFalse(CalendarInvite.isPlausibleDay(year: 2025, month: 2, day: 29))
        XCTAssertTrue(CalendarInvite.isPlausibleDay(year: 2028, month: 2, day: 29))
    }

    func testThousandsOfAttendeesAreCapped() throws {
        let invite = try one(ICSCorpus.manyAttendees(5_000))
        XCTAssertEqual(invite.attendeeEmails.count, CalendarInvite.Limits.maxAttendees)
        XCTAssertEqual(invite.attendeeEmails.first, "guest0@example.org")
    }

    func testThousandsOfEventsAreCapped() {
        let all = CalendarInvite.parseAll(ICSCorpus.manyEvents(5_000))
        XCTAssertEqual(all.count, CalendarInvite.Limits.maxEvents)
    }

    func testDeepNestingIsSkippedWithoutRecursion() throws {
        let invite = try XCTUnwrap(CalendarInvite.parse(ICSCorpus.deepNesting(20_000)))
        XCTAssertEqual(invite.summary, "Deep")
        XCTAssertEqual(invite.description, "", "nested DESCRIPTION is not the event's")
    }

    func testGiantFoldedLineIsUnfoldedAndBounded() throws {
        let ics = ICSCorpus.giantFoldedSummary(900_000)
        let invite = try XCTUnwrap(CalendarInvite.parse(ics))
        XCTAssertEqual(invite.summary.count, CalendarInvite.Limits.maxDisplayLength + 1)
        XCTAssertTrue(invite.summary.hasSuffix("…"))
        // Same through the byte path.
        XCTAssertEqual(CalendarInvite.parse(Data(ics.utf8))?.uid, "giant@example.com")
    }

    func testOversizedDocumentIsRefusedWhole() {
        let ics = ICSCorpus.giantFoldedSummary(CalendarInvite.Limits.maxBytes + 1)
        XCTAssertTrue(CalendarInvite.parseAll(ics).isEmpty)
        XCTAssertTrue(CalendarInvite.parseAll(Data(ics.utf8)).isEmpty)
    }

    func testGarbageIsNotAnInvite() {
        XCTAssertTrue(CalendarInvite.parseAll(Data([0x00, 0xFF, 0x13, 0x37])).isEmpty)
        XCTAssertTrue(CalendarInvite.parseAll("BEGIN:VEVENT\r\nSUMMARY:no uid\r\nEND:VEVENT").isEmpty)
        XCTAssertTrue(CalendarInvite.parseAll("").isEmpty)
    }
}
