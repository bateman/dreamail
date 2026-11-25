import Foundation

/// Synthetic calendar invites, written by hand after RFC 5545 (iCalendar),
/// RFC 5546 (iTIP) and RFC 6047 (iMIP), in the shapes Google Calendar,
/// Outlook / Exchange and Apple Calendar send. No real data: every address
/// is on an `example.*` domain, every UID is made up.
///
/// Raw string literals, so ICS escapes (`\,`, `\n`) are what the file holds.
/// Line endings are LF here; `crlf(_:)` gives the wire form.
enum ICSCorpus {
    static func crlf(_ ics: String) -> String {
        ics.replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: - Senders

    /// Google Calendar: UTC times, folded ATTENDEE lines, conference data in
    /// X- properties and a DESCRIPTION with a link (never opened).
    static let google = #"""
        BEGIN:VCALENDAR
        PRODID:-//Google Inc//Google Calendar 70.9054//EN
        VERSION:2.0
        CALSCALE:GREGORIAN
        METHOD:REQUEST
        BEGIN:VEVENT
        DTSTART:20261203T090000Z
        DTEND:20261203T100000Z
        DTSTAMP:20261120T101500Z
        ORGANIZER;CN=Ada Organizer:mailto:ada@example.com
        UID:0a1b2c3d4e5f@google.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=
         TRUE;CN=Guest One;X-NUM-GUESTS=0:mailto:guest@example.org
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE
         ;CN=Ada Organizer;X-NUM-GUESTS=0:mailto:ada@example.com
        X-GOOGLE-CONFERENCE:https://meet.example.com/abc-defg-hij
        CREATED:20261120T101400Z
        DESCRIPTION:Join: https://meet.example.com/abc-defg-hij\nAgenda\, notes.
        LAST-MODIFIED:20261120T101500Z
        LOCATION:Room 4\, Building B
        SEQUENCE:0
        STATUS:CONFIRMED
        SUMMARY:Quarterly review
        TRANSP:OPAQUE
        END:VEVENT
        END:VCALENDAR
        """#

    /// Outlook / Exchange: a Windows zone name with its VTIMEZONE, a VALARM
    /// whose DESCRIPTION must not replace the meeting's, X-MICROSOFT props.
    static let outlook = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        PRODID:Microsoft Exchange Server 2010
        VERSION:2.0
        BEGIN:VTIMEZONE
        TZID:W. Europe Standard Time
        BEGIN:STANDARD
        DTSTART:16010101T030000
        TZOFFSETFROM:+0200
        TZOFFSETTO:+0100
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:16010101T020000
        TZOFFSETFROM:+0100
        TZOFFSETTO:+0200
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3
        END:DAYLIGHT
        END:VTIMEZONE
        BEGIN:VEVENT
        ORGANIZER;CN=Olaf Outlook:mailto:olaf@example.net
        ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=guest@exa
         mple.org:mailto:guest@example.org
        DESCRIPTION;LANGUAGE=en-US:Weekly sync.\n
        UID:040000008200E00074C5B7101A82E00800000000A0B1C2D3E4F5
        SUMMARY;LANGUAGE=en-US:Planning
        DTSTART;TZID=W. Europe Standard Time:20261203T100000
        DTEND;TZID=W. Europe Standard Time:20261203T110000
        CLASS:PUBLIC
        PRIORITY:5
        DTSTAMP:20261120T090000Z
        TRANSP:OPAQUE
        STATUS:CONFIRMED
        SEQUENCE:0
        LOCATION;LANGUAGE=en-US:Online
        X-MICROSOFT-CDO-APPT-SEQUENCE:0
        X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE
        BEGIN:VALARM
        DESCRIPTION:REMINDER
        TRIGGER;RELATED=START:-PT15M
        ACTION:DISPLAY
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """#

    /// Apple Calendar: an IANA TZID with its VTIMEZONE, an RFC 6868 caret
    /// escape in a CN, EMAIL parameters and X-APPLE props.
    static let apple = #"""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Apple Inc.//macOS 15.0//EN
        CALSCALE:GREGORIAN
        METHOD:REQUEST
        BEGIN:VTIMEZONE
        TZID:Europe/Rome
        BEGIN:DAYLIGHT
        TZOFFSETFROM:+0100
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
        DTSTART:19810329T020000
        TZNAME:CEST
        TZOFFSETTO:+0200
        END:DAYLIGHT
        BEGIN:STANDARD
        TZOFFSETFROM:+0200
        RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
        DTSTART:19961027T030000
        TZNAME:CET
        TZOFFSETTO:+0100
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        CREATED:20261101T080000Z
        UID:6F1E3C2A-0B4D-4E5F-9A8B-7C6D5E4F3A2B
        DTEND;TZID=Europe/Rome:20260710T160000
        ATTENDEE;CN="Guest One";CUTYPE=INDIVIDUAL;EMAIL="guest@example.org";PARTS
         TAT=NEEDS-ACTION;ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:guest@example.org
        ATTENDEE;CN="Bea ^'Boss^' Apple";CUTYPE=INDIVIDUAL;EMAIL="bea@example.it";PA
         RTSTAT=ACCEPTED;ROLE=CHAIR:mailto:bea@example.it
        TRANSP:OPAQUE
        X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC
        SUMMARY:Pranzo di lavoro
        DTSTART;TZID=Europe/Rome:20260710T150000
        DTSTAMP:20261101T080000Z
        ORGANIZER;CN="Bea ^'Boss^' Apple";EMAIL="bea@example.it":mailto:bea@exampl
         e.it
        SEQUENCE:0
        END:VEVENT
        END:VCALENDAR
        """#

    // MARK: - Time shapes

    static let floating = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:floating@example.com
        SUMMARY:Floating
        DTSTART:20261201T090000
        DTEND:20261201T093000
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        END:VCALENDAR
        """#

    static let allDayMultiDay = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:holiday@example.com
        SUMMARY:Offsite
        DTSTART;VALUE=DATE:20261224
        DTEND;VALUE=DATE:20261227
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        END:VCALENDAR
        """#

    static let durationOnly = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:duration@example.com
        SUMMARY:Call
        DTSTART:20261203T090000Z
        DURATION:PT1H30M
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        END:VCALENDAR
        """#

    // MARK: - Recurrence

    static let recurringWeekly = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:series@example.com
        SUMMARY:1:1
        DTSTART;TZID=Europe/Rome:20261207T100000
        DTEND;TZID=Europe/Rome:20261207T103000
        RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;COUNT=10
        EXDATE;TZID=Europe/Rome:20261221T100000
        ORGANIZER:mailto:ada@example.com
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:guest@example.org
        SEQUENCE:1
        END:VEVENT
        END:VCALENDAR
        """#

    /// The series and one moved instance in one document (same UID).
    static let seriesWithException = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:series@example.com
        SUMMARY:1:1
        DTSTART;TZID=Europe/Rome:20261207T100000
        DTEND;TZID=Europe/Rome:20261207T103000
        RRULE:FREQ=WEEKLY;BYDAY=MO
        ORGANIZER:mailto:ada@example.com
        SEQUENCE:1
        END:VEVENT
        BEGIN:VEVENT
        UID:series@example.com
        RECURRENCE-ID;TZID=Europe/Rome:20261214T100000
        SUMMARY:1:1 (moved)
        DTSTART;TZID=Europe/Rome:20261214T110000
        DTEND;TZID=Europe/Rome:20261214T113000
        ORGANIZER:mailto:ada@example.com
        SEQUENCE:2
        END:VEVENT
        END:VCALENDAR
        """#

    static let rdateOnly = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:rdate@example.com
        SUMMARY:Workshop days
        DTSTART:20261203T090000Z
        RDATE:20261210T090000Z,20261217T090000Z
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        END:VCALENDAR
        """#

    // MARK: - Updates and cancellations

    /// `google` moved one hour later: same UID, higher SEQUENCE.
    static let googleUpdated = google
        .replacingOccurrences(of: "DTSTART:20261203T090000Z", with: "DTSTART:20261203T100000Z")
        .replacingOccurrences(of: "DTEND:20261203T100000Z", with: "DTEND:20261203T110000Z")
        .replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:2")

    static let cancelWhole = #"""
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:0a1b2c3d4e5f@google.com
        SUMMARY:Quarterly review
        DTSTART:20261203T090000Z
        ORGANIZER:mailto:ada@example.com
        STATUS:CANCELLED
        SEQUENCE:3
        END:VEVENT
        END:VCALENDAR
        """#

    static let cancelInstance = #"""
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:series@example.com
        RECURRENCE-ID;TZID=Europe/Rome:20261214T100000
        SUMMARY:1:1
        DTSTART;TZID=Europe/Rome:20261214T100000
        ORGANIZER:mailto:ada@example.com
        STATUS:CANCELLED
        SEQUENCE:3
        END:VEVENT
        END:VCALENDAR
        """#

    /// Some servers cancel one instance with a REQUEST whose STATUS says so.
    static let requestMarkedCancelled = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:series@example.com
        RECURRENCE-ID:20261214T090000Z
        SUMMARY:1:1
        DTSTART:20261214T090000Z
        ORGANIZER:mailto:ada@example.com
        STATUS:CANCELLED
        END:VEVENT
        END:VCALENDAR
        """#

    // MARK: - Other methods

    /// An attendee's answer, as the organizer receives it.
    static let replyReceived = #"""
        BEGIN:VCALENDAR
        METHOD:REPLY
        BEGIN:VEVENT
        UID:0a1b2c3d4e5f@google.com
        DTSTAMP:20261121T080000Z
        SUMMARY:Quarterly review
        ORGANIZER:mailto:ada@example.com
        ATTENDEE;PARTSTAT=DECLINED;CN=Guest One:mailto:guest@example.org
        END:VEVENT
        END:VCALENDAR
        """#

    static let counter = #"""
        BEGIN:VCALENDAR
        METHOD:COUNTER
        BEGIN:VEVENT
        UID:0a1b2c3d4e5f@google.com
        SUMMARY:Quarterly review
        DTSTART:20261204T090000Z
        ORGANIZER:mailto:ada@example.com
        ATTENDEE;PARTSTAT=TENTATIVE:mailto:guest@example.org
        END:VEVENT
        END:VCALENDAR
        """#

    static let declineCounter = counter.replacingOccurrences(
        of: "METHOD:COUNTER", with: "METHOD:DECLINECOUNTER")

    static let publish = counter.replacingOccurrences(
        of: "METHOD:COUNTER", with: "METHOD:PUBLISH")

    /// METHOD with a parameter (legal, rare).
    static let methodWithParam = floating.replacingOccurrences(
        of: "METHOD:REQUEST", with: "METHOD;X-ORIGIN=test:REQUEST")

    static let twoEvents = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:slot-a@example.com
        SUMMARY:Slot A
        DTSTART:20261203T090000Z
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        BEGIN:VEVENT
        UID:slot-b@example.com
        SUMMARY:Slot B
        DTSTART:20261203T100000Z
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        END:VCALENDAR
        """#

    // MARK: - Text

    static let escapes = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:escapes@example.com
        SUMMARY:Budget\, Q3\; review \\ notes\nsecond line
        LOCATION:Via Roma 1\, Bari
        DTSTART:20261203T090000Z
        ORGANIZER;CN="Rossi, Anna":mailto:anna@example.it
        END:VEVENT
        END:VCALENDAR
        """#

    /// UTF-8 text folded inside a two-byte character ("é" = C3 A9).
    static var foldedInsideUTF8Character: Data {
        var bytes = Array("BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:fold@example.com\r\nSUMMARY:Caf".utf8)
        bytes += [0xC3, 0x0D, 0x0A, 0x20, 0xA9]
        bytes += Array(" del luned\u{EC}\r\nDTSTART:20261203T090000Z\r\nORGANIZER:mailto:ada@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        return Data(bytes)
    }

    /// A Latin-1 (ISO-8859-1) document, as old Exchange servers send.
    static var latin1: Data {
        let text = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:latin1@example.com\r\nSUMMARY:R\u{E9}union caf\u{E9}\r\nDTSTART:20261203T090000Z\r\nORGANIZER:mailto:ada@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        return text.data(using: .isoLatin1)!
    }

    static var utf16LE: Data {
        var data = Data([0xFF, 0xFE])
        data.append(crlf(floating).data(using: .utf16LittleEndian)!)
        return data
    }

    static var utf8BOM: Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(crlf(floating).utf8)
    }

    // MARK: - Hostile

    /// ORGANIZER naming two recipients: replying would mail a third party.
    static let organizerList = floating.replacingOccurrences(
        of: "ORGANIZER:mailto:ada@example.com",
        with: "ORGANIZER:mailto:ada@example.com,attacker@example.net")

    /// ORGANIZER with a display name and brackets in the value.
    static let organizerDisplayName = floating.replacingOccurrences(
        of: "ORGANIZER:mailto:ada@example.com",
        with: "ORGANIZER:mailto:Ada <ada@example.com>")

    static let noOrganizer = floating.replacingOccurrences(
        of: "ORGANIZER:mailto:ada@example.com\n", with: "")

    /// A right-to-left override in the CN, and a caret newline trying to
    /// add a line to the reply.
    static let spoofedOrganizerName = floating.replacingOccurrences(
        of: "ORGANIZER:mailto:ada@example.com",
        with: "ORGANIZER;CN=\"Ada\u{202E}gro.elpmaxe@ssob^nATTENDEE:mailto:x@example.net\":mailto:ada@example.com")

    static let absurdDates = #"""
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:absurd-1@example.com
        DTSTART:99991231T250000Z
        DTEND:00000101T000000Z
        ORGANIZER:mailto:ada@example.com
        SEQUENCE:-5
        END:VEVENT
        BEGIN:VEVENT
        UID:absurd-2@example.com
        DTSTART:20260230T100000Z
        ORGANIZER:mailto:ada@example.com
        SEQUENCE:99999999999999999999999
        END:VEVENT
        BEGIN:VEVENT
        UID:absurd-3@example.com
        DTSTART:20261203T090000Z
        DURATION:P99999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999W
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        BEGIN:VEVENT
        UID:absurd-4@example.com
        DTSTART:20261203T090000Z
        DTEND:20261202T090000Z
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        BEGIN:VEVENT
        UID:absurd-5@example.com
        DTSTART;VALUE=DATE:00000101
        DTSTART:2026120XT090000Z
        ORGANIZER:mailto:ada@example.com
        END:VEVENT
        END:VCALENDAR
        """#

    static func manyAttendees(_ count: Int) -> String {
        var lines = ["BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT",
                     "UID:crowd@example.com", "SUMMARY:Crowd",
                     "DTSTART:20261203T090000Z", "ORGANIZER:mailto:ada@example.com"]
        for i in 0..<count {
            lines.append("ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:guest\(i)@example.org")
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n")
    }

    static func manyEvents(_ count: Int) -> String {
        var lines = ["BEGIN:VCALENDAR", "METHOD:REQUEST"]
        for i in 0..<count {
            lines += ["BEGIN:VEVENT", "UID:e\(i)@example.com", "SUMMARY:E\(i)",
                      "DTSTART:20261203T090000Z", "ORGANIZER:mailto:ada@example.com",
                      "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    /// Thousands of nested components inside one VEVENT.
    static func deepNesting(_ depth: Int) -> String {
        var lines = ["BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT",
                     "UID:deep@example.com", "SUMMARY:Deep",
                     "DTSTART:20261203T090000Z", "ORGANIZER:mailto:ada@example.com"]
        lines += Array(repeating: "BEGIN:VALARM", count: depth)
        lines.append("DESCRIPTION:inner")
        lines += Array(repeating: "END:VALARM", count: depth)
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n")
    }

    /// One SUMMARY of `octets` bytes folded every 74 octets.
    static func giantFoldedSummary(_ octets: Int) -> String {
        let value = String(repeating: "x", count: octets)
        var folded = "SUMMARY:"
        var i = value.startIndex
        while i < value.endIndex {
            let j = value.index(i, offsetBy: 74, limitedBy: value.endIndex) ?? value.endIndex
            folded += value[i..<j]
            if j < value.endIndex { folded += "\r\n " }
            i = j
        }
        return ["BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT",
                "UID:giant@example.com", folded,
                "DTSTART:20261203T090000Z", "ORGANIZER:mailto:ada@example.com",
                "END:VEVENT", "END:VCALENDAR"].joined(separator: "\r\n")
    }
}
