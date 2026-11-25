import Foundation

/// Parsed iCalendar invite (RFC 5545 / iTIP RFC 5546) from a `text/calendar`
/// or `.ics` attachment. Pure value type — no network, no store.
struct CalendarInvite: Equatable, Sendable {
    enum Method: String, Equatable, Sendable {
        case request = "REQUEST"
        case reply = "REPLY"
        case cancel = "CANCEL"
        case publish = "PUBLISH"
        case counter = "COUNTER"
        case refresh = "REFRESH"
        case add = "ADD"
        case declineCounter = "DECLINECOUNTER"
        case unknown

        init(raw: String?) {
            guard let raw, let m = Method(rawValue: raw.uppercased()) else {
                self = .unknown
                return
            }
            self = m
        }
    }

    /// Guest RSVP for a METHOD:REPLY we send.
    enum RSVP: String, Equatable, Sendable, CaseIterable {
        case accepted = "ACCEPTED"
        case declined = "DECLINED"
        case tentative = "TENTATIVE"

        var buttonTitle: String {
            switch self {
            case .accepted: return "Accept"
            case .declined: return "Decline"
            case .tentative: return "Maybe"
            }
        }

        /// Subject prefix matching Gmail / Apple Mail (`Accepted: …`).
        var subjectPrefix: String {
            switch self {
            case .accepted: return "Accepted"
            case .declined: return "Declined"
            case .tentative: return "Tentative"
            }
        }

        var pastParticiple: String {
            switch self {
            case .accepted: return "accepted"
            case .declined: return "declined"
            case .tentative: return "tentatively accepted"
            }
        }
    }

    var method: Method
    var uid: String
    var summary: String
    var location: String
    var description: String
    var organizerEmail: String
    var organizerName: String
    /// Bare attendee emails from ATTENDEE lines (lowercased, mailto: stripped).
    /// Used to pick a send-as identity that the organizer's calendar already knows.
    var attendeeEmails: [String]
    var start: Date?
    var end: Date?
    var isAllDay: Bool
    var sequence: Int
    /// Full unfolded `RECURRENCE-ID…` property line from the request, when
    /// present (single-instance RSVP on a recurring series). Echoed verbatim
    /// into METHOD:REPLY so the organizer applies PARTSTAT to the right occurrence.
    var recurrenceIdLine: String?
    /// Raw ICS source (kept for debugging / future round-trips; reply is rebuilt).
    var sourceICS: String
    /// TZID of DTSTART / DTEND when nothing could resolve it (not IANA, not a
    /// Windows name, no usable VTIMEZONE). `start` / `end` then hold the wall
    /// time read in the local zone, which is NOT the real instant: the card
    /// shows the raw time with this name, and the reply echoes the raw lines.
    var unresolvedTZID: String? = nil
    /// Unfolded `DTSTART…` / `DTEND…` property lines from the request.
    var startLine: String? = nil
    var endLine: String? = nil
    /// VEVENT `STATUS` (uppercased): `CANCELLED` on a REQUEST cancels too.
    var status: String = ""
    /// The event's `RRULE` value, when it repeats (bounded length).
    var recurrenceRule: String? = nil
    /// The event has `RDATE` occurrences (repeats without a rule).
    var hasRecurrenceDates: Bool = false
    /// METHOD:REPLY only: who answered and how (the first ATTENDEE's
    /// address and `PARTSTAT`).
    var replyAttendeeEmail: String? = nil
    var replyPartstat: String? = nil

    /// True when Accept / Decline / Maybe should be offered.
    /// Gmail is conservative: only METHOD:REQUEST is actionable. PUBLISH /
    /// unknown (forwarded exports) would otherwise email whatever ORGANIZER
    /// the untrusted attachment author wrote. A cancelled event or an
    /// ORGANIZER that is not one plain address is never answered.
    var isActionable: Bool {
        method == .request && !isCancelled && hasValidOrganizer && replyIsSafe
    }

    /// Everything the reply copies from the invite (UID, RECURRENCE-ID)
    /// could be rebuilt into safe lines (`echoSafe`, `rebuildDateLine`).
    /// False: the invite can't be answered rather than echo what its author
    /// wrote.
    var replyIsSafe: Bool = true

    var isCancelled: Bool { method == .cancel || status == "CANCELLED" }

    /// ORGANIZER is one plain address the reply can go to (see
    /// `isPlainAddress`): never a list, a display name or a header fragment.
    var hasValidOrganizer: Bool { Self.isPlainAddress(organizerEmail) }

    var isRecurring: Bool { recurrenceRule != nil || hasRecurrenceDates }

    // MARK: - Limits

    /// An ICS is untrusted input: these bound the work and memory one
    /// attachment can cost. Past them the document is refused or cut short,
    /// never parsed without end.
    enum Limits {
        /// Larger documents are refused whole (real invites are a few KB;
        /// a long series with exceptions stays well under this).
        static let maxBytes = 1_048_576
        /// VEVENTs read from one document; later ones are ignored.
        static let maxEvents = 50
        /// Distinct ATTENDEE addresses kept per event.
        static let maxAttendees = 500
        /// Characters kept of SUMMARY, LOCATION and the organizer's name.
        static let maxDisplayLength = 1_000
        /// Characters kept of DESCRIPTION (not shown on the card).
        static let maxDescriptionLength = 20_000
        /// Characters kept of RRULE.
        static let maxRuleLength = 500
        /// Years accepted in DTSTART / DTEND; others read as no time.
        static let years = 1900...2200
        /// Longest event (DTEND or DURATION past DTSTART) accepted.
        static let maxDuration: TimeInterval = 10 * 366 * 24 * 3600
        /// Longest UID, RECURRENCE-ID or zone line the reply copies; past it
        /// the invite can't be answered (they are also a stored key).
        static let maxEchoBytes = 1_024
        /// Highest SEQUENCE kept; larger values are clamped.
        static let maxSequence = 1_000_000
    }

    // MARK: - Recipient checks

    /// One plain `local@domain` address. The reply's To is built from
    /// this, so a crafted ORGANIZER such as `a@x.com,b@y.com`,
    /// `"Boss" <a@x.com>`, `a@x.com?subject=y` or a `%` relay route is
    /// refused, not sent.
    /// - local part: RFC 5322 atom characters without `%`, `!` and `?`,
    ///   dot-separated, no empty segment, at most 64 octets;
    /// - domain: at least two dot-separated labels of letters, digits and
    ///   inner hyphens, each 1–63 octets.
    static func isPlainAddress(_ raw: String) -> Bool {
        guard (3...254).contains(raw.utf8.count) else { return false }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        guard (1...64).contains(local.utf8.count) else { return false }
        for segment in local.split(separator: ".", omittingEmptySubsequences: false) {
            guard !segment.isEmpty,
                  segment.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || localSpecials.contains($0) })
            else { return false }
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "-" })
            else { return false }
        }
        return true
    }

    private static let localSpecials = Set("#$&'*+-/=^_`{|}~".unicodeScalars)

    private static func isASCIIAlphanumeric(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (0x61...0x7A).contains(v) || (0x41...0x5A).contains(v) || (0x30...0x39).contains(v)
    }

    // MARK: - Reply echo

    /// Text the reply may copy from the invite: no control character
    /// (`Cc`, which includes CR, LF, VT, FF and NEL) and no line or
    /// paragraph separator, so nothing copied can start a line of its own.
    static func isEchoSafe(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: isLineBreakingOrControl)
    }

    /// Cc, Zl and Zp. Format characters (Cf, such as the zero-width joiner
    /// inside an emoji) are text and stay.
    static func isLineBreakingOrControl(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// `DTSTART`, `DTEND` or `RECURRENCE-ID` rebuilt for the reply from its
    /// parsed parts, never copied: only TZID (echo-safe, no DQUOTE), VALUE
    /// (DATE / DATE-TIME) and, on RECURRENCE-ID, RANGE=THISANDFUTURE are
    /// kept, and the value must be a DATE or DATE-TIME. Nil for anything
    /// else or a line over `Limits.maxEchoBytes`.
    static func rebuildDateLine(_ line: String) -> String? {
        guard line.utf8.count <= Limits.maxEchoBytes,
              let prop = splitProperty(line),
              ["DTSTART", "DTEND", "RECURRENCE-ID"].contains(prop.name) else { return nil }
        let value = prop.value.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^[0-9]{8}(T[0-9]{6}Z?)?$"#, options: .regularExpression) != nil
        else { return nil }
        // Unknown parameters (X-…) are dropped, not echoed.
        var out = prop.name
        if let raw = prop.params["TZID"] {
            let tzid = cleanTZID(raw)
            guard !tzid.isEmpty, isEchoSafe(tzid), !tzid.contains("\"") else { return nil }
            out += ";TZID=" + (tzid.contains(where: { ";:,".contains($0) }) ? "\"\(tzid)\"" : tzid)
        }
        if let raw = prop.params["VALUE"] {
            let v = raw.uppercased()
            guard v == "DATE" || v == "DATE-TIME" else { return nil }
            out += ";VALUE=\(v)"
        }
        if let raw = prop.params["RANGE"] {
            guard prop.name == "RECURRENCE-ID", raw.uppercased() == "THISANDFUTURE" else { return nil }
            out += ";RANGE=THISANDFUTURE"
        }
        return out + ":" + value
    }

    /// A VTIMEZONE rebuilt for the reply from its parsed properties: BEGIN
    /// and END (with or without parameters) must nest as VTIMEZONE >
    /// STANDARD / DAYLIGHT, only zone properties are kept (without
    /// parameters, echo-safe, each within `Limits.maxEchoBytes`), anything
    /// unknown is dropped. Nil when the block is malformed: the reply then
    /// carries no zone.
    static func echoableZoneLines(_ source: [String]) -> [String]? {
        let kept: Set<String> = ["TZID", "TZOFFSETFROM", "TZOFFSETTO", "TZNAME", "DTSTART", "RRULE", "RDATE"]
        var out: [String] = []
        var depth = 0
        var closed = false
        for line in source {
            guard !closed, line.utf8.count <= Limits.maxEchoBytes,
                  let prop = splitProperty(line) else { return nil }
            let value = prop.value.trimmingCharacters(in: .whitespaces)
            guard isEchoSafe(value) else { return nil }
            switch prop.name {
            case "BEGIN":
                let v = value.uppercased()
                if depth == 0, v == "VTIMEZONE", out.isEmpty { depth = 1 }
                else if depth == 1, v == "STANDARD" || v == "DAYLIGHT" { depth = 2 }
                else { return nil }
                out.append("BEGIN:\(v)")
            case "END":
                let v = value.uppercased()
                if depth == 2, v == "STANDARD" || v == "DAYLIGHT" { depth = 1 }
                else if depth == 1, v == "VTIMEZONE" { depth = 0; closed = true }
                else { return nil }
                out.append("END:\(v)")
            case let name where kept.contains(name):
                guard depth >= 1, !value.isEmpty else { return nil }
                if name == "TZID" { guard depth == 1 else { return nil } }
                else { guard depth == 2 else { return nil } }
                out.append("\(name):\(value)")
            default:
                guard depth >= 1 else { return nil }
            }
        }
        guard closed, out.count <= maxEchoedZoneLines else { return nil }
        return out
    }

    /// The reply goes to ORGANIZER, which the ICS author chose. False when
    /// that is not the address the message came from, so the card can say
    /// so before the user answers (a forged invite would otherwise make the
    /// user reply to a third party unseen).
    func organizerIsSender(senderEmail: String) -> Bool {
        let sender = senderEmail.trimmingCharacters(in: .whitespaces).lowercased()
        return !sender.isEmpty && sender == organizerEmail.lowercased()
    }

    /// "guest@example.org declined" for a received METHOD:REPLY, only when
    /// the answering ATTENDEE is the address the message came from (the
    /// ATTENDEE line alone is whatever the ICS author wrote).
    func replySummary(senderEmail: String) -> String? {
        guard method == .reply, let who = replyAttendeeEmail,
              who == senderEmail.trimmingCharacters(in: .whitespaces).lowercased()
        else { return nil }
        let name = Self.displaySafe(who, limit: 254)
        switch replyPartstat {
        case "ACCEPTED": return "\(name) accepted"
        case "DECLINED": return "\(name) declined"
        case "TENTATIVE": return "\(name) replied maybe"
        case "DELEGATED": return "\(name) delegated"
        default: return nil
        }
    }

    /// "Repeats weekly" for the card, from RRULE's FREQ and INTERVAL.
    var repeatDescription: String? {
        guard isRecurring else { return nil }
        guard let rule = recurrenceRule else { return "Repeats" }
        var freq = ""
        var interval = 1
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].uppercased() {
            case "FREQ": freq = kv[1].uppercased()
            case "INTERVAL": interval = Int(kv[1]) ?? 1
            default: break
            }
        }
        let units: [String: (one: String, many: String)] = [
            "DAILY": ("daily", "days"), "WEEKLY": ("weekly", "weeks"),
            "MONTHLY": ("monthly", "months"), "YEARLY": ("yearly", "years"),
        ]
        guard let unit = units[freq] else { return "Repeats" }
        if interval > 1, interval <= 999 { return "Repeats every \(interval) \(unit.many)" }
        return "Repeats \(unit.one)"
    }

    /// Attachment looks like a calendar invite by MIME or filename.
    static func isCalendarAttachment(mimeType: String, filename: String) -> Bool {
        let mime = mimeType.lowercased()
        if mime.hasPrefix("text/calendar") { return true }
        if mime.contains("application/ics") { return true }
        return filename.lowercased().hasSuffix(".ics")
    }

    /// Collapse Google-style duplicate calendar MIME parts to one row.
    ///
    /// Google Calendar invites almost always ship the same payload twice:
    /// `text/calendar` inside `multipart/alternative` **and** a downloadable
    /// `application/ics` / `invite.ics` sibling. Without collapsing, the
    /// reading pane renders two identical Accept/Decline/Maybe cards.
    ///
    /// Preference when keys collide: real Gmail `attachmentId` over the
    /// inline `text/calendar` sentinel (getAttachment is cheaper than a
    /// full-message re-fetch). Display order follows first occurrence of
    /// each dedupe key in the input.
    ///
    /// Distinct filenames (e.g. `standup.ics` + `retro.ics` on one mail)
    /// stay separate so multi-invite messages still get one card each.
    static func uniqueCalendarAttachments(_ attachments: [AttachmentRow]) -> [AttachmentRow] {
        let cals = attachments.filter {
            isCalendarAttachment(mimeType: $0.mimeType, filename: $0.filename)
        }
        guard cals.count > 1 else { return cals }

        var best: [String: (att: AttachmentRow, firstIndex: Int)] = [:]
        var keyOrder: [String] = []
        for (i, att) in cals.enumerated() {
            let key = calendarAttachmentDedupeKey(filename: att.filename)
            if let existing = best[key] {
                let existInline = AttachmentRow.isInlineCalendarId(
                    existing.att.gmailAttachmentId)
                let newInline = AttachmentRow.isInlineCalendarId(
                    att.gmailAttachmentId)
                // Prefer downloadable over inline when the same file appears twice.
                if existInline && !newInline {
                    best[key] = (att, existing.firstIndex)
                }
            } else {
                best[key] = (att, i)
                keyOrder.append(key)
            }
        }
        return keyOrder.compactMap { best[$0]?.att }
    }

    /// Normalized filename key for collapsing duplicate calendar parts.
    /// Empty / missing names (inline alternative parts) map to `invite.ics`,
    /// matching the synthetic name used at parse time.
    static func calendarAttachmentDedupeKey(filename: String) -> String {
        let name = filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return name.isEmpty ? "invite.ics" : name
    }

    /// Preferred single event from an ICS document (see `preferred(from:)`).
    static func parse(_ data: Data) -> CalendarInvite? {
        preferred(from: parseAll(data))
    }

    static func parse(_ ics: String) -> CalendarInvite? {
        preferred(from: parseAll(ics))
    }

    /// Every VEVENT in the document, sharing the calendar-level METHOD.
    /// Multi-event ICS (series + exceptions, or multi-slot bookings) yields
    /// one invite per VEVENT with a UID.
    static func parseAll(_ data: Data) -> [CalendarInvite] {
        guard data.count <= Limits.maxBytes, let text = decodeText(data) else { return [] }
        return parseAll(text)
    }

    /// ICS bytes as text. Gmail hands over the part already decoded from
    /// base64 / quoted-printable, but not from its charset: UTF-8 (with or
    /// without a BOM) is the norm, UTF-16 comes with a BOM, and anything
    /// else is read as Latin-1, which never fails.
    static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 2, (bytes[0], bytes[1]) == (0xFF, 0xFE) || (bytes[0], bytes[1]) == (0xFE, 0xFF) {
            return String(data: data, encoding: .utf16)
        }
        var body = data
        if bytes == [0xEF, 0xBB, 0xBF] { body = data.dropFirst(3) }
        // Unfold before decoding: some generators fold inside a multi-byte
        // UTF-8 character, and the halves alone are not valid UTF-8.
        body = unfoldBytes(body)
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
    }

    /// Removes RFC 5545 folds (CRLF or LF, then one SPACE or TAB) from raw
    /// bytes, in one pass.
    static func unfoldBytes(_ data: Data) -> Data {
        let src = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(src.count)
        var i = 0
        while i < src.count {
            let b = src[i]
            if b == 0x0D, i + 2 < src.count, src[i + 1] == 0x0A,
               src[i + 2] == 0x20 || src[i + 2] == 0x09 {
                i += 3
                continue
            }
            if b == 0x0A, i + 1 < src.count, src[i + 1] == 0x20 || src[i + 1] == 0x09 {
                i += 2
                continue
            }
            out.append(b)
            i += 1
        }
        return Data(out)
    }

    static func parseAll(_ ics: String) -> [CalendarInvite] {
        guard ics.utf8.count <= Limits.maxBytes else { return [] }
        let lines = unfold(ics)
        guard !lines.isEmpty else { return [] }

        var methodRaw: String?
        var inEvent = false
        /// Depth of nested components inside VEVENT (VALARM, etc.). Props
        /// belonging to those components must not overwrite VEVENT fields —
        /// Outlook VALARMs ship `DESCRIPTION:REMINDER` that would otherwise
        /// replace the meeting description under first-wins.
        var nestedDepth = 0
        var props: [String: (params: [String: String], value: String)] = [:]
        var attendeeEmails: [String] = []
        var seenAttendees = Set<String>()
        var firstAttendee: (email: String, partstat: String?)?
        var hasRDate = false
        var recurrenceIdLine: String?
        var unsafeRecurrenceId = false
        var events: [CalendarInvite] = []
        // VTIMEZONE blocks normally precede the VEVENTs, but a pre-pass keeps
        // the fallback independent of component order.
        let zones = ICSTimeZone.parseAll(lines)
        var rawLines: [String: String] = [:]

        func finishEvent() {
            if var invite = buildInvite(
                methodRaw: methodRaw, props: props, zones: zones,
                attendeeEmails: attendeeEmails,
                recurrenceIdLine: recurrenceIdLine, sourceICS: ics) {
                invite.startLine = rawLines["DTSTART"]
                invite.endLine = rawLines["DTEND"]
                invite.hasRecurrenceDates = hasRDate
                invite.replyIsSafe = !unsafeRecurrenceId
                    && invite.uid.utf8.count <= Limits.maxEchoBytes
                    && isEchoSafe(invite.uid)
                if invite.method == .reply, let firstAttendee {
                    invite.replyAttendeeEmail = firstAttendee.email
                    invite.replyPartstat = firstAttendee.partstat
                }
                events.append(invite)
            }
            rawLines = [:]
            props = [:]
            attendeeEmails = []
            seenAttendees = []
            firstAttendee = nil
            hasRDate = false
            recurrenceIdLine = nil
            unsafeRecurrenceId = false
            nestedDepth = 0
            inEvent = false
        }

        for line in lines {
            if events.count >= Limits.maxEvents { break }
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") {
                if inEvent { finishEvent() }
                inEvent = true
                nestedDepth = 0
                props = [:]
                attendeeEmails = []
                seenAttendees = []
                firstAttendee = nil
                hasRDate = false
                recurrenceIdLine = nil
                unsafeRecurrenceId = false
                continue
            }
            if upper.hasPrefix("END:VEVENT") {
                if inEvent { finishEvent() }
                continue
            }
            if !inEvent {
                // `METHOD;X-PARAM=…:REQUEST` is legal too; first one wins.
                if methodRaw == nil, upper.hasPrefix("METHOD"),
                   let prop = splitProperty(line), prop.name == "METHOD" {
                    methodRaw = prop.value.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            // Skip nested components entirely (VALARM is the common case).
            if upper.hasPrefix("BEGIN:") {
                nestedDepth += 1
                continue
            }
            if upper.hasPrefix("END:") {
                if nestedDepth > 0 { nestedDepth -= 1 }
                continue
            }
            if nestedDepth > 0 { continue }

            guard let nameAndValue = splitProperty(line) else { continue }
            let name = nameAndValue.name
            let params = nameAndValue.params
            let value = nameAndValue.value

            if name == "ATTENDEE" {
                let (email, _) = parseAddress(value: value, params: params)
                let lower = email.lowercased()
                if firstAttendee == nil, !lower.isEmpty {
                    firstAttendee = (lower, params["PARTSTAT"]?.uppercased())
                }
                // A Set, not `contains` on the array: thousands of attendees
                // would otherwise cost a quadratic scan.
                if !lower.isEmpty, attendeeEmails.count < Limits.maxAttendees,
                   seenAttendees.insert(lower).inserted {
                    attendeeEmails.append(lower)
                }
            }
            if name == "RDATE" { hasRDate = true }
            if name == "RECURRENCE-ID", recurrenceIdLine == nil, !unsafeRecurrenceId {
                // Rebuilt, not copied, for the reply; one that can't be
                // rebuilt makes the event unanswerable (answering the whole
                // series instead of one instance would be wrong).
                if let rebuilt = rebuildDateLine(line) {
                    recurrenceIdLine = rebuilt
                } else {
                    unsafeRecurrenceId = true
                }
            }
            // First wins for most props; later DTSTART/DTEND rarely appear twice.
            if props[name] == nil {
                props[name] = (params, value)
                if name == "DTSTART" || name == "DTEND" { rawLines[name] = rebuildDateLine(line) }
            }
        }
        if inEvent, events.count < Limits.maxEvents { finishEvent() }
        return events
    }

    /// Pick one event when the UI only wants a single card:
    /// 1. first with RECURRENCE-ID (instance invite on a series),
    /// 2. first METHOD:REQUEST,
    /// 3. first VEVENT.
    static func preferred(from invites: [CalendarInvite]) -> CalendarInvite? {
        if let inst = invites.first(where: { $0.recurrenceIdLine != nil }) {
            return inst
        }
        if let req = invites.first(where: { $0.method == .request }) {
            return req
        }
        return invites.first
    }

    private static func buildInvite(
        methodRaw: String?,
        props: [String: (params: [String: String], value: String)],
        zones: [String: ICSTimeZone],
        attendeeEmails: [String],
        recurrenceIdLine: String?,
        sourceICS: String
    ) -> CalendarInvite? {
        let uid = props["UID"]?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !uid.isEmpty else { return nil }

        let summary = displaySafe(unescape(props["SUMMARY"]?.value ?? ""),
                                  limit: Limits.maxDisplayLength)
        let location = displaySafe(unescape(props["LOCATION"]?.value ?? ""),
                                   limit: Limits.maxDisplayLength)
        let description = String(unescape(props["DESCRIPTION"]?.value ?? "")
            .prefix(Limits.maxDescriptionLength))
        let sequence = min(Limits.maxSequence,
                           max(0, Int(props["SEQUENCE"]?.value.trimmingCharacters(in: .whitespaces) ?? "") ?? 0))

        let (orgEmail, orgNameRaw) = parseAddress(
            value: props["ORGANIZER"]?.value ?? "",
            params: props["ORGANIZER"]?.params ?? [:])
        let orgName = displaySafe(orgNameRaw, limit: Limits.maxDisplayLength)

        let startParsed = parseDate(props["DTSTART"], zones: zones)
        let endParsed = startParsed == nil ? nil : parseDate(props["DTEND"], zones: zones)
        var end = endParsed?.date
        if end == nil, let start = startParsed?.date,
           let duration = props["DURATION"]?.value,
           let seconds = parseDuration(duration) {
            end = start.addingTimeInterval(seconds)
        }
        // An end before the start, or years after it, is not a real event:
        // keep the start and drop the end.
        if let start = startParsed?.date, let e = end,
           e < start || e.timeIntervalSince(start) > Limits.maxDuration {
            end = nil
        }
        let rule = props["RRULE"].map {
            String($0.value.trimmingCharacters(in: .whitespaces).prefix(Limits.maxRuleLength))
        }

        return CalendarInvite(
            method: Method(raw: methodRaw),
            uid: uid,
            summary: summary.isEmpty ? "Calendar event" : summary,
            location: location,
            description: description,
            organizerEmail: orgEmail,
            organizerName: orgName,
            attendeeEmails: attendeeEmails,
            start: startParsed?.date,
            end: end,
            isAllDay: startParsed?.allDay ?? false,
            sequence: sequence,
            recurrenceIdLine: recurrenceIdLine,
            sourceICS: sourceICS,
            unresolvedTZID: startParsed?.unresolvedTZID ?? endParsed?.unresolvedTZID,
            status: props["STATUS"]?.value.trimmingCharacters(in: .whitespaces).uppercased() ?? "",
            recurrenceRule: rule
        )
    }

    /// Untrusted text bound for the card (and the reply's SUMMARY and
    /// LOCATION): no control, line-separator or bidirectional
    /// override characters (a right-to-left override in an organizer's name
    /// could make the address after it read as another one), newlines and
    /// tabs as spaces, and a bounded length.
    static func displaySafe(_ value: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        for u in value.unicodeScalars {
            if u == "\n" || u == "\t" || u == "\r"
                || u.properties.generalCategory == .lineSeparator
                || u.properties.generalCategory == .paragraphSeparator {
                out.append(" ")
            } else if isLineBreakingOrControl(u) || bidiControls.contains(u.value) {
                continue
            } else {
                out.append(u)
            }
        }
        let s = String(out).trimmingCharacters(in: .whitespaces)
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    /// LRM, RLM, ALM and the embedding / override / isolate controls.
    private static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F, 0x061C,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    // MARK: - Reply

    /// Build a METHOD:REPLY ICS for this invite from `attendeeEmail`.
    /// Content lines longer than 75 octets are folded per RFC 5545 §3.1.
    func replyICS(status: RSVP, attendeeEmail: String, attendeeName: String = "") -> String {
        let email = attendeeEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cn = attendeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Self.formatUTC(Date())
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "PRODID:-//MishMail//Calendar RSVP//EN",
            "VERSION:2.0",
            "METHOD:REPLY",
            "CALSCALE:GREGORIAN",
        ]
        // The zone could not be resolved, so `start` / `end` are not the real
        // instants. Echo the organizer's own DTSTART / DTEND (and the zone
        // definition they refer to) instead of a wrong UTC time.
        let echoRawTimes = unresolvedTZID != nil && startLine != nil
        if echoRawTimes, let tzid = unresolvedTZID,
           let zone = ICSTimeZone.parseAll(Self.unfold(sourceICS))[tzid],
           let zoneLines = Self.echoableZoneLines(zone.lines) {
            lines.append(contentsOf: zoneLines)
        }
        lines.append(contentsOf: [
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(stamp)",
            "SEQUENCE:\(sequence)",
        ])
        // Instance RSVP on a recurring series — without this the organizer
        // applies PARTSTAT to the master / wrong occurrence.
        if let recurrenceIdLine, !recurrenceIdLine.isEmpty {
            lines.append(recurrenceIdLine)
        }
        if echoRawTimes, let startLine {
            lines.append(startLine)
            if let endLine { lines.append(endLine) }
        } else {
            if let start {
                lines.append(isAllDay
                    ? "DTSTART;VALUE=DATE:\(Self.formatDateOnly(start))"
                    : "DTSTART:\(Self.formatUTC(start))")
            }
            if let end {
                lines.append(isAllDay
                    ? "DTEND;VALUE=DATE:\(Self.formatDateOnly(end))"
                    : "DTEND:\(Self.formatUTC(end))")
            }
        }
        lines.append("SUMMARY:\(Self.escape(summary))")
        if !location.isEmpty {
            lines.append("LOCATION:\(Self.escape(location))")
        }
        if !organizerEmail.isEmpty {
            let orgCN = organizerName.isEmpty ? "" : ";CN=\(Self.escapeParam(organizerName))"
            lines.append("ORGANIZER\(orgCN):mailto:\(organizerEmail)")
        }
        var attendee = "ATTENDEE;PARTSTAT=\(status.rawValue);ROLE=REQ-PARTICIPANT"
        if !cn.isEmpty {
            attendee += ";CN=\(Self.escapeParam(cn))"
        }
        attendee += ":mailto:\(email)"
        lines.append(attendee)
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return Self.foldICS(lines)
    }

    /// Cap on a VTIMEZONE block copied into a reply (see `replyICS`).
    private static let maxEchoedZoneLines = 200

    /// RFC 5545 §3.1: fold content lines so no line exceeds 75 octets.
    /// Continuations begin with a single SPACE after CRLF.
    static func foldICS(_ lines: [String]) -> String {
        lines.map { foldLine($0) }.joined(separator: "\r\n") + "\r\n"
    }

    /// Fold one logical line to ≤75 UTF-8 octets per physical line.
    static func foldLine(_ line: String, limit: Int = 75) -> String {
        let bytes = Array(line.utf8)
        guard bytes.count > limit else { return line }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / limit * 3)
        var offset = 0
        var first = true
        while offset < bytes.count {
            let budget = first ? limit : max(1, limit - 1) // room for leading SPACE
            var end = min(offset + budget, bytes.count)
            // Don't split mid multi-byte UTF-8 sequence.
            if end < bytes.count {
                while end > offset && (bytes[end] & 0xC0) == 0x80 {
                    end -= 1
                }
                if end == offset {
                    // Pathological: single code point longer than budget — force.
                    end = min(offset + budget, bytes.count)
                }
            }
            if !first {
                out.append(0x0D); out.append(0x0A); out.append(0x20) // CRLF + SPACE
            }
            out.append(contentsOf: bytes[offset..<end])
            offset = end
            first = false
        }
        return String(bytes: out, encoding: .utf8) ?? line
    }

    /// Human subject for the RSVP message.
    func replySubject(status: RSVP) -> String {
        "\(status.subjectPrefix): \(summary)"
    }

    /// Short plain-text body for the RSVP message.
    func replyBody(status: RSVP, responderName: String) -> String {
        let who = responderName.isEmpty ? "The invitee" : responderName
        return "\(who) has \(status.pastParticiple) this invitation."
    }

    /// MIME attachment for the REPLY ICS.
    func replyAttachment(status: RSVP, attendeeEmail: String,
                         attendeeName: String = "") -> MIMEBuilder.Attachment {
        let ics = replyICS(status: status, attendeeEmail: attendeeEmail,
                           attendeeName: attendeeName)
        return .init(
            filename: "invite.ics",
            // method=REPLY is required so calendar agents treat this as iTIP.
            mimeType: "text/calendar; method=REPLY",
            data: Data(ics.utf8)
        )
    }

    /// When-string for the invite card (locale-aware).
    func whenDescription(now: Date = Date(),
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        guard let start else { return "Time not specified" }
        if isAllDay {
            let df = DateFormatter()
            df.locale = locale
            df.calendar = calendar
            df.doesRelativeDateFormatting = true
            df.dateStyle = .full
            df.timeStyle = .none
            if let end, end > start.addingTimeInterval(24 * 3600 - 1) {
                // Multi-day all-day: end is exclusive in iCal DATE form.
                let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
                if calendar.isDate(start, inSameDayAs: lastDay) {
                    return df.string(from: start)
                }
                return "\(df.string(from: start)) – \(df.string(from: lastDay))"
            }
            return df.string(from: start)
        }

        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeStyle = .short
        time.dateStyle = .none

        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        // "Today" / "Tomorrow" would be a claim about the reader's clock,
        // which an unresolved zone cannot support.
        day.doesRelativeDateFormatting = unresolvedTZID == nil
        day.dateStyle = .full
        day.timeStyle = .none

        if unresolvedTZID != nil {
            // `start` / `end` were read in the system zone at parse time, so
            // formatting in that same zone gives back the organizer's digits.
            time.timeZone = .current
            day.timeZone = .current
        }
        let suffix = unresolvedTZID.map {
            " (\(Self.displayZoneName($0)), not converted to your time zone)"
        } ?? ""

        let dayPart = day.string(from: start)
        if let end {
            if calendar.isDate(start, inSameDayAs: end) {
                return "\(dayPart) · \(time.string(from: start)) – \(time.string(from: end))\(suffix)"
            }
            let endDay = day.string(from: end)
            return "\(dayPart) \(time.string(from: start)) – \(endDay) \(time.string(from: end))\(suffix)"
        }
        return "\(dayPart) · \(time.string(from: start))\(suffix)"
    }

    /// TZID text for the card: untrusted, so one line and a bounded length.
    static func displayZoneName(_ tzid: String) -> String {
        let flat = tzid.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 64 ? String(flat.prefix(64)) + "…" : flat
    }

    // MARK: - Key for local RSVP state

    /// Stable key for the last RSVP sent for this UID (+ instance): the
    /// card's in-memory map, and the UserDefaults key earlier builds stored
    /// it under (now in `CalendarRSVPStore`; old keys are purged).
    static func rsvpDefaultsKey(accountId: String, uid: String,
                                recurrenceIdLine: String? = nil) -> String {
        // UID can contain `@` and punctuation; keep the key printable.
        let safeUID = uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? uid
        let safeAcct = accountId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? accountId
        var key = "calendar.rsvp.\(safeAcct).\(safeUID)"
        if let recurrenceIdLine, !recurrenceIdLine.isEmpty {
            let safeRID = recurrenceIdLine
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? recurrenceIdLine
            key += ".\(safeRID)"
        }
        return key
    }

    // MARK: - Parsing helpers

    /// RFC 5545 line unfolding: a line starting with SPACE/TAB continues the previous.
    static func unfold(_ ics: String) -> [String] {
        let raw = ics
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // Continuations are appended in place: rebuilding the logical line
        // for each one (`last + line`) made a line folded thousands of
        // times cost quadratic time and memory.
        var out: [String] = []
        var current: String?
        for line in raw {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), current != nil {
                current?.append(contentsOf: line.dropFirst())
            } else {
                if let current, !current.isEmpty { out.append(current) }
                current = line
            }
        }
        if let current, !current.isEmpty { out.append(current) }
        return out
    }

    /// Split `NAME;PARAM=val:value`, respecting double-quoted param values so
    /// `CN="Boger; Ron"` does not break on the semicolon / colon inside quotes.
    static func splitProperty(_ line: String)
        -> (name: String, params: [String: String], value: String)? {
        // Find the first unquoted colon — that separates name/params from value.
        var inQuotes = false
        var colonIndex: String.Index?
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" { inQuotes.toggle() }
            else if ch == ":", !inQuotes {
                colonIndex = i
                break
            }
            i = line.index(after: i)
        }
        guard let colonIndex else { return nil }
        let nameAndParams = String(line[..<colonIndex])
        let value = String(line[line.index(after: colonIndex)...])

        // Split params on unquoted semicolons.
        var segments: [String] = []
        var current = ""
        inQuotes = false
        for ch in nameAndParams {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == ";", !inQuotes {
                segments.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        segments.append(current)
        guard let namePart = segments.first, !namePart.isEmpty else { return nil }
        let name = namePart.uppercased()
        var params: [String: String] = [:]
        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let key = String(seg[..<eq]).uppercased()
            var val = String(seg[seg.index(after: eq)...])
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            params[key] = val.contains("^") ? decodeCaret(val) : val
        }
        return (name, params, value)
    }

    /// RFC 6868 parameter value decoding: `^n` newline, `^'` DQUOTE,
    /// `^^` caret; any other caret is kept as written.
    static func decodeCaret(_ value: String) -> String {
        var out = ""
        var pending = false
        for ch in value {
            if pending {
                switch ch {
                case "n": out.append("\n")
                case "'": out.append("\"")
                case "^": out.append("^")
                default: out.append("^"); out.append(ch)
                }
                pending = false
            } else if ch == "^" {
                pending = true
            } else {
                out.append(ch)
            }
        }
        if pending { out.append("^") }
        return out
    }

    /// RFC 5545 §3.3.11 TEXT unescape in one left-to-right pass, so an
    /// escaped backslash is consumed before the character after it is read
    /// (`\\\\notes` is `\\notes`, not backslash + newline + "otes").
    private static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var out = ""
        out.reserveCapacity(value.count)
        var escaped = false
        for ch in value {
            if escaped {
                switch ch {
                case "n", "N": out.append("\n")
                case ",", ";", "\\": out.append(ch)
                // Not an RFC escape: keep both characters as written.
                default: out.append("\\"); out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// PARAM value for the reply. RFC 5545 has no escape inside a quoted
    /// parameter, so a DQUOTE is written the RFC 6868 way (`^'`, with `^^`
    /// for a caret); control characters are dropped, so no value can end
    /// the line. Values with specials are double-quoted.
    static func escapeParam(_ value: String) -> String {
        var clean = String.UnicodeScalarView()
        for u in value.unicodeScalars where !isLineBreakingOrControl(u) {
            clean.append(u)
        }
        let escaped = String(clean)
            .replacingOccurrences(of: "^", with: "^^")
            .replacingOccurrences(of: "\"", with: "^'")
        if escaped.contains(where: { ";,:^".contains($0) || $0.isWhitespace }) {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private static func parseAddress(value: String, params: [String: String])
        -> (email: String, name: String) {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.lowercased().hasPrefix("mailto:") {
            v = String(v.dropFirst("mailto:".count))
        }
        let email = v.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        var name = params["CN"] ?? ""
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return (email, name)
    }

    private struct ParsedDate {
        let date: Date
        let allDay: Bool
        /// Set when the TZID could not be resolved; `date` is then the wall
        /// time read in the local zone (see `CalendarInvite.unresolvedTZID`).
        var unresolvedTZID: String? = nil
    }

    private static func parseDate(
        _ prop: (params: [String: String], value: String)?,
        zones: [String: ICSTimeZone] = [:]
    ) -> ParsedDate? {
        guard let prop else { return nil }
        let value = prop.value.trimmingCharacters(in: .whitespaces)
        let params = prop.params
        let isDate = (params["VALUE"]?.uppercased() == "DATE")
            || (value.count == 8 && value.allSatisfy(\.isNumber))

        if isDate {
            guard value.count >= 8,
                  let y = Int(value.prefix(4)),
                  let m = Int(value.dropFirst(4).prefix(2)),
                  let d = Int(value.dropFirst(6).prefix(2)),
                  isPlausibleDay(year: y, month: m, day: d) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: d))
            else { return nil }
            return ParsedDate(date: date, allDay: true)
        }

        // FORM #1 / #2: YYYYMMDDTHHMMSS[Z] with optional TZID.
        let isUTC = value.hasSuffix("Z")
        let core = isUTC ? String(value.dropLast()) : value
        guard core.count >= 15,
              core.dropFirst(8).first == "T" || core.dropFirst(8).first == "t",
              let y = Int(core.prefix(4)),
              let mo = Int(core.dropFirst(4).prefix(2)),
              let d = Int(core.dropFirst(6).prefix(2)),
              let h = Int(core.dropFirst(9).prefix(2)),
              let mi = Int(core.dropFirst(11).prefix(2)),
              let s = Int(core.dropFirst(13).prefix(2)),
              isPlausibleDay(year: y, month: mo, day: d),
              (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s)
        else { return nil }

        var cal = Calendar(identifier: .gregorian)
        var unresolved: String?
        let tzid = params["TZID"].map(cleanTZID) ?? ""
        if isUTC {
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
        } else if tzid.isEmpty {
            // Floating time (RFC 5545 FORM #1): the reader's local time.
            cal.timeZone = .current
        } else if let tz = resolveTimeZone(tzid) {
            cal.timeZone = tz
        } else if let wall = ICSTimeZone.wallTime(
                    year: y, month: mo, day: d, hour: h, minute: mi, second: s),
                  let offset = zones[tzid]?.offset(atLocal: wall) {
            // The document's own VTIMEZONE says which offset applies.
            return ParsedDate(
                date: Date(timeIntervalSince1970: wall - Double(offset)),
                allDay: false)
        } else {
            cal.timeZone = .current
            unresolved = tzid
        }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        guard let date = cal.date(from: comps) else { return nil }
        return ParsedDate(date: date, allDay: false, unresolvedTZID: unresolved)
    }

    /// A real calendar day inside `Limits.years`. Calendar would roll
    /// 2026-02-30 over to March and accept year 0 or 9999.
    static func isPlausibleDay(year: Int, month: Int, day: Int) -> Bool {
        guard Limits.years.contains(year), (1...12).contains(month), day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }

    private static func cleanTZID(_ tzid: String) -> String {
        tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Resolve an ICS TZID to a Foundation TimeZone: an IANA id, a Windows
    /// zone name (Outlook / Exchange), or a path-style id whose tail is an
    /// IANA id (`/mozilla.org/20050126_1/Europe/Berlin`). Nil when none
    /// match — `parseDate` then tries the document's VTIMEZONE.
    static func resolveTimeZone(_ tzid: String) -> TimeZone? {
        let cleaned = cleanTZID(tzid)
        guard !cleaned.isEmpty else { return nil }
        if let tz = TimeZone(identifier: cleaned) { return tz }
        if let iana = WindowsTimeZones.ianaIdentifier(for: cleaned),
           let tz = TimeZone(identifier: iana) { return tz }
        let parts = cleaned.split(separator: "/").map(String.init)
        // Three components first: `America/Argentina/Buenos_Aires`.
        for count in [3, 2] where parts.count > count {
            if let tz = TimeZone(identifier: parts.suffix(count).joined(separator: "/")) {
                return tz
            }
        }
        return nil
    }

    /// Parse RFC 5545 DURATION (`PT1H30M`, `P1D`, `-PT15M`).
    static func parseDuration(_ raw: String) -> TimeInterval? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var sign: Double = 1
        if s.hasPrefix("-") { sign = -1; s = String(s.dropFirst()) }
        guard s.hasPrefix("P") else { return nil }
        s = String(s.dropFirst())
        var total: Double = 0
        var num = ""
        var inTime = false
        for ch in s {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { num.append(ch); continue }
            guard let n = Double(num) else { return nil }
            num = ""
            switch ch {
            case "W": total += n * 7 * 24 * 3600
            case "D": total += n * 24 * 3600
            case "H" where inTime: total += n * 3600
            case "M" where inTime: total += n * 60
            case "S" where inTime: total += n
            default: return nil
            }
        }
        if !num.isEmpty { return nil }
        // `P99999…9W` overflows to infinity, which no Date survives.
        guard total.isFinite, total <= Limits.maxDuration else { return nil }
        return total * sign
    }

    static func formatUTC(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func formatDateOnly(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
