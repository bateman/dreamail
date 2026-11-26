import XCTest

final class SnoozeDateParserTests: XCTestCase {
    /// Explicit English calendar: the tests must not depend on the Mac's
    /// language. Time zone stays the machine's (fixtures are built with it).
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    private var italian: Calendar {
        var c = cal
        c.locale = Locale(identifier: "it_IT")
        return c
    }

    // Tuesday July 7 2026, 10:00 local time.
    private var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 10))!
    }

    private func first(_ query: String) -> Date? {
        SnoozeDateParser.suggestions(for: query, now: now, calendar: cal).first?.date
    }
    private func comps(_ date: Date?) throws -> DateComponents {
        cal.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(date))
    }
    private func labels(_ query: String, calendar: Calendar) -> [String] {
        SnoozeDateParser.suggestions(for: query, now: now, calendar: calendar).map { $0.label.lowercased() }
    }

    func testTomorrowDefaultsToMorning() throws {
        let c = try comps(first("tom"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 8])
    }

    /// Undo toast must reuse the shared formatter (no DateFormatter alloc on
    /// the triage hot path) and stay readable for tomorrow vs later dates.
    func testUndoLabelUsesSharedFormat() throws {
        // `format` uses Calendar.isDateInTomorrow relative to wall-clock now,
        // not the fixture `now` used by the parser suggestion tests.
        let wall = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: wall)!
        let at9 = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        let label = SnoozeDateParser.undoLabel(until: at9)
        XCTAssertEqual(label, "Snoozed until \(SnoozeDateParser.format(at9))")
        XCTAssertTrue(label.hasPrefix("Snoozed until "))
        XCTAssertTrue(label.contains("tomorrow"), label)
    }

    func testWeekdayPrefixWithTime() throws {
        let c = try comps(first("fri 3pm"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 10, 15])
    }

    func testInNDays() throws {
        let c = try comps(first("in 2 weeks"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 21, 8])
    }

    func testMonthDayRollsToNextYearWhenPast() throws {
        let c = try comps(first("jan 5"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 1, 5])
    }

    func testMonthDayThisYear() throws {
        let c = try comps(first("aug 12 at 17:30"))
        XCTAssertEqual([c.month, c.day, c.hour, c.minute], [8, 12, 17, 30])
    }

    func testSlashDate() throws {
        let c = try comps(first("8/12"))
        XCTAssertEqual([c.month, c.day], [8, 12])
    }

    func testBareTimeTodayIfFuture() throws {
        let c = try comps(first("3pm"))
        XCTAssertEqual([c.day, c.hour], [7, 15])
    }

    func testBareTimePastRollsToTomorrow() throws {
        let s = SnoozeDateParser.suggestions(for: "9am", now: now, calendar: cal)
        // 9am already passed at 10:00 — only tomorrow qualifies.
        let c = try comps(s.first?.date)
        XCTAssertEqual([c.day, c.hour], [8, 9])
    }

    func testEveningKeyword() throws {
        let c = try comps(first("today evening"))
        XCTAssertEqual([c.day, c.hour], [7, 18])
    }

    func testNextWeekIsMonday() throws {
        let c = try comps(first("next week"))
        XCTAssertEqual([c.month, c.day], [7, 13])
    }

    func testTomorrowAbbreviationWithTime() throws {
        let c = try comps(first("tm 10am"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 10])
    }

    func testTomorrowAbbreviationVariants() throws {
        for q in ["tmrw", "tmr", "tmw"] {
            let c = try comps(first(q))
            XCTAssertEqual([c.month, c.day], [7, 8], "\(q) should be tomorrow")
        }
    }

    func testMonthDayWithFourDigitYear() throws {
        let c = try comps(first("aug 17 2027"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 8, 17])
    }

    func testMonthDayWithYearAndTime() throws {
        let c = try comps(first("aug 17 2027 3pm"))
        XCTAssertEqual([c.year, c.month, c.day, c.hour], [2027, 8, 17, 15])
    }

    func testSlashDateWithTwoDigitYear() throws {
        let c = try comps(first("8/12/27"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 8, 12])
    }

    func testDayMonthYear() throws {
        let c = try comps(first("17 aug 2027"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 8, 17])
    }

    func testBareHourIsMilitaryTime() throws {
        let c = try comps(first("tm 20"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 20])
    }

    func testBareHourMorning() throws {
        let c = try comps(first("tm 10"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 8, 10])
    }

    func testBareHourAfterWeekday() throws {
        let c = try comps(first("fri 15"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 10, 15])
    }

    func testMonthDayNotTreatedAsBareHour() throws {
        // "aug 12" must stay Aug 12, not August at hour 12.
        let c = try comps(first("aug 12"))
        XCTAssertEqual([c.month, c.day], [8, 12])
    }

    func testEmptyAndGarbage() throws {
        XCTAssertTrue(SnoozeDateParser.suggestions(for: "", now: now, calendar: cal).isEmpty)
        XCTAssertTrue(SnoozeDateParser.suggestions(for: "zzzz", now: now, calendar: cal).isEmpty)
    }

    func testOnlyFutureDates() throws {
        for s in SnoozeDateParser.suggestions(for: "today", now: now, calendar: cal) {
            XCTAssertGreaterThan(s.date, now)
        }
    }

    /// Typing `s` after `b` should surface weekend days + September — not
    /// leave the user with an empty suggestion list (or fall through to
    /// type-select, which is covered by DatePickQueryInputTests).
    func testSingleLetterSSuggestsSatSunSeptember() throws {
        let labels = SnoozeDateParser.suggestions(for: "s", now: now, calendar: cal).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("saturday") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("sunday") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("september") }), labels.joined(separator: ", "))
    }

    func testSatAndSunWeekdayPrefixes() throws {
        let sat = try comps(first("sat"))
        // Fixture now is Tuesday July 7 2026 → next Saturday is July 11.
        XCTAssertEqual([sat.month, sat.day], [7, 11])
        let sun = try comps(first("sun"))
        // Next Sunday is July 12.
        XCTAssertEqual([sun.month, sun.day], [7, 12])
    }

    func testBareMonthSeptember() throws {
        for q in ["sep", "sept", "september"] {
            let c = try comps(first(q))
            // July fixture → Sept 1 2026 still ahead.
            XCTAssertEqual([c.year, c.month, c.day, c.hour], [2026, 9, 1, 8], "\(q)")
        }
    }

    func testBareMonthPastRollsToNextYear() throws {
        // January is before July in the fixture year.
        let c = try comps(first("january"))
        XCTAssertEqual([c.year, c.month, c.day], [2027, 1, 1])
    }

    func testSingleLetterWeekdayWithBareHour() throws {
        // "s 10" → first matching weekday (Sunday in en_US calendar symbols)
        // at 10:00, not an empty suggestion list.
        let c = try comps(first("s 10"))
        XCTAssertEqual(c.hour, 10)
        XCTAssertNotNil(c.day)
    }

    // MARK: - Broader suggestion coverage

    func testLaterTodayAliasAndPrefix() throws {
        // Fixture is 10:00 → later today lands on afternoon (13:00).
        for q in ["l", "later", "later today", "lt"] {
            let c = try comps(first(q))
            XCTAssertEqual([c.day, c.hour], [7, 13], "\(q)")
        }
    }

    func testEndOfDayAliases() throws {
        for q in ["eod", "end of day", "end"] {
            let labels = SnoozeDateParser.suggestions(for: q, now: now, calendar: cal).map { $0.label.lowercased() }
            XCTAssertTrue(labels.contains(where: { $0.contains("end of day") }),
                          "\(q) → \(labels.joined(separator: ", "))")
        }
        let c = try comps(first("eod"))
        // Evening = 18:00 today (still ahead of 10:00).
        XCTAssertEqual([c.day, c.hour], [7, 18])
    }

    func testEndOfWeekAndMonthAliases() throws {
        let eow = try comps(first("eow"))
        // Next Friday after Tue Jul 7 2026 is Jul 10 at evening.
        XCTAssertEqual([eow.month, eow.day, eow.hour], [7, 10, 18])
        let eom = try comps(first("eom"))
        // Last day of July 2026.
        XCTAssertEqual([eom.month, eom.day], [7, 31])
    }

    func testInPrefixLadder() throws {
        let labels = SnoozeDateParser.suggestions(for: "in", now: now, calendar: cal).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("in 1 hour") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("in 1 day") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("in 1 week") }), labels.joined(separator: ", "))
    }

    func testSingleLetterISuggestsRelative() throws {
        let labels = SnoozeDateParser.suggestions(for: "i", now: now, calendar: cal).map { $0.label.lowercased() }
        XCTAssertFalse(labels.isEmpty, "i should offer the in-… ladder")
        XCTAssertTrue(labels.contains(where: { $0.contains("hour") || $0.contains("day") }),
                      labels.joined(separator: ", "))
    }

    func testCompactRelativeDurations() throws {
        let h = try comps(first("2h"))
        XCTAssertEqual(h.hour, 12)  // 10:00 + 2h
        let d = try comps(first("3d"))
        XCTAssertEqual([d.month, d.day, d.hour], [7, 10, 8])
        let w = try comps(first("1w"))
        XCTAssertEqual([w.month, w.day], [7, 14])
    }

    func testBareUnitWords() throws {
        let hour = try comps(first("hour"))
        XCTAssertEqual(hour.hour, 11)  // +1h from 10:00
        let day = try comps(first("day"))
        XCTAssertEqual([day.month, day.day], [7, 8])
        // "h" alone → in 1 hour
        let h = try comps(first("h"))
        XCTAssertEqual(h.hour, 11)
    }

    func testInNWithPartialUnit() throws {
        let c = try comps(first("in 2 da"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 9, 8])
    }

    func testBareTwoDaysWithoutIn() throws {
        let c = try comps(first("2 days"))
        XCTAssertEqual([c.month, c.day, c.hour], [7, 9, 8])
    }

    func testWeekendAlias() throws {
        let c = try comps(first("wknd"))
        // Next Saturday after Tue Jul 7 → Jul 11.
        XCTAssertEqual([c.month, c.day], [7, 11])
    }

    func testSingleLetterESuggestsEndOf() throws {
        let labels = SnoozeDateParser.suggestions(for: "e", now: now, calendar: cal).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.contains("end of day") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.contains("end of week") }), labels.joined(separator: ", "))
    }

    func testSingleLetterFStillFridayAndFebruary() throws {
        let labels = SnoozeDateParser.suggestions(for: "f", now: now, calendar: cal).map { $0.label.lowercased() }
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("friday") }), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("february") }), labels.joined(separator: ", "))
    }

    // MARK: - Italian locale: English names always work, local ones too

    /// On an Italian Mac the English abbreviations must still match, and the
    /// date must be the same as with an English calendar.
    func testItalianLocaleStillAcceptsEnglishNames() throws {
        for (q, expected) in [("fri", [7, 10]), ("sat", [7, 11]), ("sun", [7, 12]), ("sep", [9, 1])] {
            let out = SnoozeDateParser.suggestions(for: q, now: now, calendar: italian)
            let c = try comps(out.first?.date)
            XCTAssertEqual([c.month, c.day], expected, q)
        }
        let f = labels("f", calendar: italian)
        XCTAssertTrue(f.contains(where: { $0.hasPrefix("friday") }), f.joined(separator: ", "))
        XCTAssertTrue(f.contains(where: { $0.hasPrefix("february") }), f.joined(separator: ", "))
        let s = labels("s", calendar: italian)
        XCTAssertTrue(s.contains(where: { $0.hasPrefix("sunday") }), s.joined(separator: ", "))
        XCTAssertTrue(s.contains(where: { $0.hasPrefix("saturday") }), s.joined(separator: ", "))
        XCTAssertTrue(s.contains(where: { $0.hasPrefix("september") }), s.joined(separator: ", "))
    }

    func testItalianLocaleAcceptsItalianNames() throws {
        for (q, expected) in [("ven", [7, 10]), ("sab", [7, 11]), ("set", [9, 1])] {
            let out = SnoozeDateParser.suggestions(for: q, now: now, calendar: italian)
            XCTAssertFalse(out.isEmpty, q)
            let c = try comps(out.first?.date)
            XCTAssertEqual([c.month, c.day], expected, q)
        }
        // Italian names do nothing on an English calendar.
        XCTAssertTrue(labels("ven", calendar: cal).isEmpty)
        // Day-of-month form and a trailing hour work with Italian names too.
        let c = try comps(SnoozeDateParser.suggestions(for: "set 12", now: now, calendar: italian).first?.date)
        XCTAssertEqual([c.month, c.day], [9, 12])
        let v = try comps(SnoozeDateParser.suggestions(for: "ven 15", now: now, calendar: italian).first?.date)
        XCTAssertEqual([v.day, v.hour], [10, 15])
    }

    /// An input valid in both languages offers both, English first, and never
    /// the same date twice.
    func testItalianLocaleBothMatchesEnglishFirstNoDuplicates() throws {
        // "m": English Monday, then Italian martedì and mercoledì.
        let names = labels("m", calendar: italian)
        let joined = names.joined(separator: ", ")
        let monday = try XCTUnwrap(names.firstIndex(where: { $0.hasPrefix("monday") }), joined)
        let martedi = try XCTUnwrap(names.firstIndex(where: { $0.hasPrefix("martedì") }), joined)
        let mercoledi = try XCTUnwrap(names.firstIndex(where: { $0.hasPrefix("mercoledì") }), joined)
        XCTAssertLessThan(monday, martedi, joined)
        XCTAssertLessThan(martedi, mercoledi, joined)
        // "mar": March and marzo are the same date (one suggestion, English);
        // martedì is a different day and is offered as well.
        let out = SnoozeDateParser.suggestions(for: "mar", now: now, calendar: italian)
        let mar = out.map { $0.label.lowercased() }
        XCTAssertEqual(mar.filter { $0.hasPrefix("march") || $0.hasPrefix("marzo") }.count, 1, mar.joined(separator: ", "))
        XCTAssertTrue(mar.contains(where: { $0.hasPrefix("march") }), mar.joined(separator: ", "))
        XCTAssertTrue(mar.contains(where: { $0.hasPrefix("martedì") }), mar.joined(separator: ", "))
        XCTAssertEqual(out.count, Set(out.map(\.date)).count)
        XCTAssertEqual(out.count, Set(out.map(\.label)).count)
        // "nov" is November and novembre: one suggestion, not two.
        let nov = SnoozeDateParser.suggestions(for: "nov", now: now, calendar: italian)
        XCTAssertEqual(nov.count, 1)
        XCTAssertEqual(nov.first?.label.lowercased().hasPrefix("november"), true)
    }

    // MARK: - Day-part words

    /// "This evening" is a preset title, so people type it. It used to
    /// prefix-match "this weekend" and snooze to Saturday.
    func testThisDayPartMeansToday() throws {
        // Same list as a bare "evening": today first (Enter takes it), then
        // the usual ladder at that hour.
        let evening = SnoozeDateParser.suggestions(for: "this evening", now: now, calendar: cal)
        XCTAssertEqual(evening, SnoozeDateParser.suggestions(for: "evening", now: now, calendar: cal))
        XCTAssertTrue(evening.first?.label.hasPrefix("Today") ?? false)
        let e = try comps(evening.first?.date)
        XCTAssertEqual([e.month, e.day, e.hour], [7, 7, 18])

        let a = try comps(first("this afternoon"))
        XCTAssertEqual([a.month, a.day, a.hour], [7, 7, SnoozePresets.afternoonHour])
        // 08:00 has passed at the 10:00 fixture → the next morning.
        let m = try comps(first("this morning"))
        XCTAssertEqual([m.month, m.day, m.hour], [7, 8, SnoozePresets.morningHour])
    }

    /// "afternoon" also ends in "noon". The suffix table was a Dictionary,
    /// so which one matched changed from launch to launch.
    func testAfternoonIsNotNoon() throws {
        let t = try comps(first("tomorrow afternoon"))
        XCTAssertEqual([t.month, t.day, t.hour], [7, 8, SnoozePresets.afternoonHour])
        let bare = try comps(first("afternoon"))
        XCTAssertEqual([bare.month, bare.day, bare.hour], [7, 7, SnoozePresets.afternoonHour])
        let fri = try comps(first("fri afternoon"))
        XCTAssertEqual([fri.month, fri.day, fri.hour], [7, 10, SnoozePresets.afternoonHour])
    }

    /// The parser and the preset rows must agree on what each day part means.
    func testDayPartHoursMatchPresets() throws {
        XCTAssertEqual(try comps(first("tomorrow morning")).hour, SnoozePresets.morningHour)
        XCTAssertEqual(try comps(first("tomorrow afternoon")).hour, SnoozePresets.afternoonHour)
        XCTAssertEqual(try comps(first("tomorrow evening")).hour, SnoozePresets.eveningHour)
        let preset = SnoozePresets.presets(now: now, calendar: cal).first { $0.title == "This afternoon" }
        XCTAssertEqual(first("this afternoon"), preset?.date)
    }

    func testNoonStillParses() throws {
        let fri = try comps(first("fri noon"))
        XCTAssertEqual([fri.month, fri.day, fri.hour], [7, 10, 12])
        let tm = try comps(first("tomorrow at noon"))
        XCTAssertEqual([tm.month, tm.day, tm.hour], [7, 8, 12])
        let bare = try comps(first("at noon"))
        XCTAssertEqual([bare.month, bare.day, bare.hour], [7, 7, 12])
    }

    /// "tonight" ends in "night" but is its own keyword, not "to" + night.
    func testTonightIsNotSplit() throws {
        let out = SnoozeDateParser.suggestions(for: "tonight", now: now, calendar: cal)
        XCTAssertEqual(out.count, 1, out.map(\.label).joined(separator: ", "))
        XCTAssertTrue(out.first?.label.hasPrefix("Tonight") ?? false)
        let c = try comps(out.first?.date)
        XCTAssertEqual([c.month, c.day, c.hour], [7, 7, 20])
    }

    // MARK: - Hostile input (the field parses on every keystroke)

    /// Day/month habit ("25/12") and impossible months used to index
    /// `monthSymbols` out of range and take the app down.
    func testSlashDateWithMonthOutOfRangeDoesNotTrap() throws {
        let dec = try comps(first("25/12"))
        XCTAssertEqual([dec.year, dec.month, dec.day], [2026, 12, 25])
        let jan = try comps(first("13/1"))
        XCTAssertEqual([jan.year, jan.month, jan.day], [2027, 1, 13])
        for q in ["0/5", "5/0", "13/13", "0/0", "99/99", "25/12/0", "32/1"] {
            XCTAssertTrue(SnoozeDateParser.suggestions(for: q, now: now, calendar: cal).isEmpty, q)
        }
    }

    /// A day the month does not have must not roll into the next month under
    /// a label that names the typed (impossible) date.
    func testImpossibleDayOfMonthGivesNothing() throws {
        for q in ["2/30", "feb 30", "31 apr", "4/31"] {
            XCTAssertTrue(SnoozeDateParser.suggestions(for: q, now: now, calendar: cal).isEmpty, q)
        }
    }

    func testHugeNumbersDoNotTrap() throws {
        for q in ["99999999999999999999d", "in 99999999999999999999 days",
                  "in 99999999999999999999", "99999999999999999999h",
                  "9223372036854775807w", "9223372036854775807 months",
                  "in 9223372036854775807"] {
            for s in SnoozeDateParser.suggestions(for: q, now: now, calendar: cal) {
                XCTAssertGreaterThan(s.date, now, q)
            }
        }
    }

    /// `\d` matches every Unicode digit, `Int()` only ASCII ones.
    func testNonASCIIDigitsDoNotTrap() throws {
        for q in ["١٢/٣", "٣d", "in ٣ days", "aug ١٢", "١٢ aug", "tm ١٠", "٣pm", "１２/２５"] {
            for s in SnoozeDateParser.suggestions(for: q, now: now, calendar: cal) {
                XCTAssertGreaterThan(s.date, now, q)
            }
        }
    }

    /// Fuzz: a few thousand generated inputs built from the fragments the
    /// parser reacts to. It must never trap and never offer a date that is
    /// not in the future. Seeded, so a failure reproduces.
    func testFuzzNeverTrapsAndNeverReturnsPastDate() throws {
        var rng = SplitMix64(seed: 0x5EED_CAFE)
        let fragments: [String] = [
            "0", "1", "2", "3", "7", "8", "9", "12", "13", "24", "25", "29", "30", "31", "32",
            "59", "60", "99", "100", "2026", "2027", "9999", "0000", "00",
            "99999999999999999999", "9223372036854775807", "9223372036854775808",
            "/", "//", ":", ",", ".", "-", " ", "  ", "\t", "\n",
            "h", "hr", "hrs", "d", "w", "wk", "wks", "mo", "m", "min", "mins", "minutes",
            "hour", "hours", "day", "days", "week", "weeks", "month", "months", "s",
            "in", "in ", "at", " at ", "am", "pm", "a", "p",
            "jan", "feb", "february", "mar", "apr", "may", "jun", "jul", "aug", "sep",
            "sept", "oct", "nov", "dec", "december",
            "mon", "tue", "wed", "thu", "fri", "friday", "sat", "sun",
            "today", "tod", "tonight", "tomorrow", "tom", "tm", "tmrw", "later", "lt",
            "next", "next ", "this", "this ", "week", "weekend", "wknd", "end of", "eod",
            "eow", "eom", "noon", "morning", "afternoon", "evening", "night",
            "١٢", "٣", "１２", "é", "ß", "İ", "🙂", "👨‍👩‍👧", "日本", "\u{0301}", "\u{200B}",
            "\u{FEFF}", "\0", "(", ")", "[", "\\", "*", "+", "?", "$", "^",
        ]
        // Edges of the calendar as well as the plain fixture.
        let nows: [Date] = [
            now,
            cal.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59))!,
            cal.date(from: DateComponents(year: 2028, month: 2, day: 29, hour: 0, minute: 0))!,
            cal.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 19, minute: 30))!,
            cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 59))!,   // US DST start
            cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30))!,  // US DST end
            cal.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 17, minute: 59))!, // Friday
        ]
        var checked = 0
        var productive = 0
        for i in 0..<4000 {
            var q = ""
            let parts = Int(rng.next() % 6) + 1
            for _ in 0..<parts {
                q += fragments[Int(rng.next() % UInt64(fragments.count))]
                if rng.next() % 3 == 0 { q += " " }
            }
            if rng.next() % 16 == 0 { q = q.uppercased() }
            let fixture = nows[i % nows.count]
            let out = SnoozeDateParser.suggestions(for: q, now: fixture, calendar: cal)
            XCTAssertLessThanOrEqual(out.count, 5, q.debugDescription)
            if !out.isEmpty { productive += 1 }
            for s in out {
                XCTAssertGreaterThan(s.date, fixture, q.debugDescription)
            }
            checked += 1
        }
        // Very long inputs: one repeated fragment and one random mix.
        for fragment in ["9", "9/", "a", "in 9 ", "aug ", "🙂", "next ", "12:"] {
            let long = String(repeating: fragment, count: 5000)
            for s in SnoozeDateParser.suggestions(for: long, now: now, calendar: cal) {
                XCTAssertGreaterThan(s.date, now)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 4000)
        // Guards the corpus itself: if nothing parses, the loop proves nothing.
        XCTAssertGreaterThan(productive, 200, "fuzz corpus no longer reaches the date paths")
    }
}

/// Small deterministic generator so the fuzz corpus is the same on each run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
