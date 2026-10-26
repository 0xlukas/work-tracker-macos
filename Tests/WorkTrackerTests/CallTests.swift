import XCTest
import SwiftData
@testable import WorkTracker

@MainActor
final class CallTests: XCTestCase {
    private func call(_ caller: String, _ topic: String = "", _ length: CallLength = .short, at date: Date,
                      department: String = "", solved: Bool = false, note: String = "") -> PhoneCall {
        PhoneCall(date: date, length: length, caller: caller, topic: topic, department: department, note: note,
                  solvedByMe: solved)
    }

    func testNamesIgnoreCaseAndAccents() {
        XCTAssertEqual(CallNames.canonical("  müller ", in: ["Meier", "Müller"]), "Müller")
        XCTAssertEqual(CallNames.canonical("MULLER", in: ["Müller"]), "Müller")
        XCTAssertEqual(CallNames.canonical("Huber", in: ["Müller"]), "Huber")
        let uses = [("Meier", time(day(10, 1), 9)), ("Huber", time(day(10, 2), 9)), ("meier", time(day(10, 3), 9)),
                    ("Keller", time(day(10, 5), 9)), ("", time(day(10, 6), 9))]
        XCTAssertEqual(CallNames.ranked(uses), ["Meier", "Keller", "Huber"], "most used, then most recent")
        XCTAssertEqual(CallNames.recent(uses, limit: 2), ["Keller", "meier"])
    }

    func testSuggestionsFollowTheCaller() {
        let calls = [
            call("Meier", "Mortgage", at: time(day(10, 1), 9), department: "Credit"),
            call("Meier", "Limits", at: time(day(10, 2), 9)),
            call("Meier", "Mortgage", at: time(day(10, 3), 9), department: "Lending"),
            call("Huber", "Payments", at: time(day(10, 4), 9), department: "Operations"),
        ]
        let suggestions = CallSuggestions(calls: calls)
        XCTAssertEqual(suggestions.callers, ["Meier", "Huber"])
        XCTAssertEqual(suggestions.recentCallers, ["Huber", "Meier"])
        XCTAssertEqual(suggestions.topics(of: "meier"), ["Mortgage", "Limits"])
        XCTAssertEqual(suggestions.topicList(for: "Huber"), ["Payments", "Mortgage", "Limits"])
        XCTAssertEqual(suggestions.department(of: "Meier"), "Lending", "the latest one used with the caller")
        XCTAssertNil(suggestions.department(of: "Keller"))
        XCTAssertEqual(suggestions.topics(of: " "), [])
    }

    func testSiriNamesAndDefaults() {
        let known = ["Hans Meier", "Huber", "Anna Hubacher"]
        XCTAssertEqual(CallNames.matches("huber", in: known), ["Huber"], "a known name, nothing to choose")
        XCTAssertEqual(CallNames.matches("Meier", in: known), ["Hans Meier", "Meier"], "known names containing it, then a new one")
        XCTAssertEqual(CallNames.matches(" Keller ", in: known), ["Keller"])
        XCTAssertEqual(CallNames.matches("  ", in: known), [])

        let suggestions = CallSuggestions(calls: [
            call("Meier", at: time(day(10, 1), 9), department: "Credit"),
            call("Meier", at: time(day(10, 2), 9), department: "Legal"),
        ])
        XCTAssertEqual(suggestions.department(of: "meier", among: ["Credit", "Legal"]), "Legal")
        XCTAssertEqual(suggestions.department(of: "Meier", among: ["Credit"]), "", "removed from the list since")
        XCTAssertEqual(suggestions.department(of: "Huber", among: ["Credit"]), "")

        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .en
        XCTAssertEqual(CallLog.confirmation(call("Meier", "Mortgage", .short, at: day(10, 1), solved: true)),
                       "Logged the call from Meier about Mortgage (Under 15 minutes, solved by you).")
        XCTAssertEqual(CallLog.confirmation(call("Meier", "", .long, at: day(10, 1))),
                       "Logged the call from Meier (Over 1 hour, solved by the caller).")
        Localization.current = .de
        XCTAssertEqual(CallLog.confirmation(call("Meier", "Hypothek", .medium, at: day(10, 1), solved: true)),
                       "Anruf von Meier zu Hypothek erfasst (15 Minuten bis 1 Stunde, von Ihnen gelöst).")
    }

    func testReportCountsBlocksAndWhoSolved() {
        let calls = [
            call("Meier", "Mortgage", .short, at: time(day(10, 1), 9), solved: true),
            call("meier", "Mortgage", .long, at: time(day(10, 2), 9)),
            call("Huber", "", .medium, at: time(day(10, 3), 9), solved: true),
            call("Huber", "Payments", .short, at: time(day(10, 4), 9)),
            call("Keller", "Payments", .short, at: time(day(10, 5), 9)),
        ]
        let total = CallReport.total(calls)
        XCTAssertEqual(total.count, 5)
        XCTAssertEqual([total.count(.short), total.count(.medium), total.count(.long)], [3, 1, 1])
        XCTAssertEqual(total.solvedByMe, 2)

        let callers = CallReport.byCaller(calls)
        XCTAssertEqual(callers.map(\.name), ["meier", "Huber", "Keller"],
                       "most calls, then longer ones; the latest spelling")
        XCTAssertEqual(callers[0].count(.long), 1)
        XCTAssertEqual(callers[0].solvedByMe, 1)

        XCTAssertEqual(CallReport.byTopic(calls).map(\.name), ["Mortgage", "Payments", ""], "no topic last")
    }

    func testLoggingTakesKnownSpellingAndRenamingMerges() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        CallLog.add(caller: "Müller", topic: "Mortgage", length: .short, solvedByMe: false, at: time(day(10, 1), 9),
                    context: context)
        let second = CallLog.add(caller: " MÜLLER ", topic: "mortgage", department: "Credit", note: " follow up ",
                                 length: .long, solvedByMe: true, at: time(day(10, 2), 9), context: context)
        XCTAssertEqual(second.caller, "Müller")
        XCTAssertEqual(second.topic, "Mortgage")
        XCTAssertEqual(second.note, "follow up")
        XCTAssertNotNil(second.syncID)

        CallLog.add(caller: "Meyer", topic: "Limits", length: .medium, solvedByMe: false, at: time(day(10, 3), 9),
                    context: context)
        XCTAssertEqual(CallLog.rename("meyer", to: "müller", field: \.caller, context: context), 1)
        let calls = try context.fetch(FetchDescriptor<PhoneCall>())
        XCTAssertEqual(Set(calls.map(\.caller)), ["Müller"], "renaming onto a used name merges them")
        XCTAssertEqual(CallLog.rename("Credit", to: "Lending", field: \.department, context: context), 1)
        XCTAssertEqual(Set(calls.map(\.department)), ["", "Lending"])
    }

    func testMarkdownForAnAI() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .en
        let calls = [
            call("Meier", "Mortgage | rates", .medium, at: time(day(10, 2), 14, 5), department: "Credit", solved: true,
                 note: "line one\nline two ``` end"),
            call("Huber", "", .short, at: time(day(10, 1), 9)),
            call("meier", "Mortgage | rates", .long, at: time(day(10, 6), 9, 30)),
        ]
        let text = CallExport.markdown(calls, scope: "October 2026")
        XCTAssertTrue(text.hasPrefix("# Call log: October 2026\n"))
        XCTAssertTrue(text.contains("use them for totals and rankings rather than recounting the call list"))
        XCTAssertTrue(text.contains("- Date and time are when the call was logged"))
        XCTAssertTrue(text.contains("- Calls from 2026-10-01 to 2026-10-06 (6 days)"))
        XCTAssertFalse(text.contains("- Period:"))
        XCTAssertTrue(text.contains("- Calls: 3 (Under 15 minutes: 1, 15 minutes to 1 hour: 1, Over 1 hour: 1)"))
        XCTAssertTrue(text.contains("- Estimated time on calls: ≈ 2h 00m"), "7.5 + 37.5 + 75 minutes")
        XCTAssertTrue(text.contains("- Solved by me: 1 of 3 (33%)"))
        XCTAssertTrue(text.contains("| meier | 2 | 0 | 1 | 1 | ≈ 1h 53m | 1 | Mortgage \\| rates |"),
                      "per caller with the time, who solved it and the usual topic; pipes escaped")
        XCTAssertTrue(text.contains("| No topic | 1 | 1 | 0 | 0 | ≈ 0h 08m | 0 |"))
        XCTAssertTrue(text.contains("## By Department"))
        XCTAssertTrue(text.contains("| meier | Mortgage \\| rates | 2 | ≈ 1h 53m | 2026-10-06 |"), "recurring question")
        XCTAssertTrue(text.contains("| 2026-10 | 3 | ≈ 2h 00m |"))
        XCTAssertTrue(text.contains("| Tuesday | 1 |") && text.contains("| Thursday | 1 |") && text.contains("| Friday | 1 |"))
        XCTAssertTrue(text.contains("| 09:00–10:00 | 2 |") && text.contains("| 14:00–15:00 | 1 |"))
        XCTAssertTrue(text.contains("| 10:00–11:00 | 0 |"), "quiet hours between busy ones count too")
        XCTAssertFalse(text.contains("| 08:00–09:00 |") || text.contains("| 15:00–16:00 |"))

        let csv = text.components(separatedBy: "```csv\n")[1].components(separatedBy: "\n```")[0]
        XCTAssertTrue(csv.hasPrefix("Date,Weekday,Time,Caller,Topic,Department,Length,Estimated minutes,Solved by,Note\n"),
                      "comma-separated whatever the CSV setting")
        XCTAssertTrue(csv.contains("2026-10-01,Thu,09:00,Huber,,,Under 15 minutes,7.50,Caller,"), "oldest first")
        XCTAssertFalse(csv.contains("```"), "a note can't end the code block")
        XCTAssertTrue(text.hasSuffix("```\n"))

        // One period's calls: its days so far, and every month in it, quiet ones too.
        let period = CallExport.markdown(calls + [call("Huber", "", .short, at: time(day(12, 1), 9))],
                                         scope: "Autumn", days: day(9, 1)...day(12, 3))
        XCTAssertTrue(period.contains("- Period: 2026-09-01 to 2026-12-03 (94 days)"))
        XCTAssertTrue(period.contains("- Calls from 2026-10-01 to 2026-12-01\n"), "the period has the day count")
        XCTAssertTrue(period.contains("| 2026-09 | 0 | ≈ 0h 00m |\n| 2026-10 | 3 | ≈ 2h 00m |\n| 2026-11 | 0 | ≈ 0h 00m |\n| 2026-12 | 1 |"))

        // A month still to come with a call already in it: the days stretch to the call.
        let november = CallExport.markdown([call("Huber", "", .short, at: time(day(11, 15), 9))], scope: "November 2026",
                                           days: day(11, 1)...day(11, 1))
        XCTAssertTrue(november.contains("- Period: 2026-11-01 to 2026-11-15 (15 days)"))

        // Before 1894 Zurich's midnight wasn't on the hour: months still line up with the calls.
        let old = CallExport.markdown([call("A", "", .short, at: time(day(1890, 1, 5), 9)),
                                       call("A", "", .short, at: time(day(1890, 3, 5), 9))], scope: "Old")
        XCTAssertTrue(old.contains("| 1890-01 | 1 | ≈ 0h 08m |\n| 1890-02 | 0 | ≈ 0h 00m |\n| 1890-03 | 1 | ≈ 0h 08m |"))
        // A mistyped year doesn't list centuries of empty months.
        let typo = CallExport.markdown([call("A", "", .short, at: time(day(26, 10, 5), 9)),
                                        call("A", "", .short, at: time(day(10, 5), 9))], scope: "Typo")
        let typoMonths = typo.components(separatedBy: "## By Month")[1].components(separatedBy: "## By Weekday")[0]
        XCTAssertEqual(typoMonths.components(separatedBy: "\n").filter { $0.hasPrefix("| 0026-") || $0.hasPrefix("| 2026-") },
                       ["| 0026-10 | 1 | ≈ 0h 08m |", "| 2026-10 | 1 | ≈ 0h 08m |"])

        // Every recurring question, not just the first few.
        let many = (1...30).flatMap { n in (0..<2).map { call("Caller \(n)", "Topic", .short, at: time(day(10, 1), 9, $0)) } }
        XCTAssertEqual(CallExport.markdown(many, scope: "All").components(separatedBy: "| Topic | 2 |").count - 1, 30)

        let empty = CallExport.markdown([], scope: "Week")
        XCTAssertTrue(empty.contains("- Calls: 0"))
        XCTAssertFalse(empty.contains("```csv"))
    }

    func testCSV() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .en
        let csv = CSVExporter(format: .excelGerman).calls([
            call("Meier", "Mortgage; rates", .long, at: time(day(10, 2), 14, 5), department: "Credit", solved: true),
        ])
        XCTAssertEqual(csv, "\u{FEFF}Date;Weekday;Time;Caller;Topic;Department;Length;Estimated minutes;Solved by;Note\n"
                       + "2026-10-02;Fri;14:05;Meier;\"Mortgage; rates\";Credit;Over 1 hour;75,00;Me;\n")
    }

    func testPeriods() {
        let week = CallPeriod(scope: .week, containing: time(day(10, 29), 15))
        XCTAssertEqual(week.from, day(10, 26))
        XCTAssertEqual(week.to, day(11, 1))
        XCTAssertEqual(week.shifted(by: -1).from, day(10, 19))
        XCTAssertEqual(week.previous, week.shifted(by: -1))
        let month = CallPeriod(scope: .month, containing: day(2, 14))
        XCTAssertEqual(month.from, day(2, 1))
        XCTAssertEqual(month.to, day(2, 28))
        XCTAssertEqual(month.shifted(by: 1).to, day(3, 31))
        let year = CallPeriod(scope: .year, containing: day(6, 1))
        XCTAssertEqual(year.from, day(1, 1))
        XCTAssertEqual(year.to, day(12, 31))
        XCTAssertTrue(year.contains(time(day(12, 31), 23, 59)))
        XCTAssertFalse(year.contains(day(2027, 1, 1)))

        let custom = CallPeriod(from: day(10, 20), to: time(day(10, 6), 15))
        XCTAssertEqual([custom.from, custom.to], [day(10, 6), day(10, 20)], "either order, whole days")
        XCTAssertEqual(custom.days, 15)
        XCTAssertEqual(custom.previous, CallPeriod(from: day(9, 21), to: day(10, 5)), "the same length just before")
        XCTAssertEqual(custom.current(now: time(day(10, 26), 9)), CallPeriod(from: day(10, 12), to: day(10, 26)))

        let all = CallPeriod(scope: .all, containing: time(day(10, 26), 9))
        XCTAssertTrue(all.contains(day(1990, 1, 1)) && all.contains(day(2030, 1, 1)))
        XCTAssertEqual(all.current(now: day(2027, 3, 1)), all, "doesn't end on the day it was chosen")
        XCTAssertNil(all.previous)
        XCTAssertNil(all.comparisonCutoff(now: time(day(10, 26), 9)))
        XCTAssertNil(all.daysSoFar(now: time(day(10, 26), 9)))
        XCTAssertEqual(all.shifted(by: -1), all)

        // While a period runs, the one before counts only as far as this one has got.
        XCTAssertEqual(week.comparisonCutoff(now: time(day(10, 28), 10)), time(day(10, 21), 10))
        XCTAssertNil(week.comparisonCutoff(now: day(11, 2)), "over: the whole week before counts")
        let october = CallPeriod(scope: .month, containing: day(10, 1))
        XCTAssertEqual(october.comparisonCutoff(now: time(day(10, 26), 9)), time(day(9, 26), 9), "across the clock change")
        // `time` adds hours to midnight; on a clock-change Sunday the wall clock differs.
        func clock(_ date: Date, _ hour: Int) -> Date {
            Calendar.zurich.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        }
        let april = CallPeriod(scope: .month, containing: day(4, 1))
        XCTAssertEqual(april.comparisonCutoff(now: time(day(4, 29), 10)), clock(day(3, 29), 10), "onto the clock-change Sunday")
        let march = CallPeriod(scope: .month, containing: day(3, 1))
        XCTAssertEqual(march.comparisonCutoff(now: time(day(3, 31), 10)), time(day(2, 28), 10), "the end of a shorter month")
        let thisYear = CallPeriod(scope: .year, containing: day(1, 1))
        XCTAssertEqual(thisYear.comparisonCutoff(now: time(day(10, 26), 9)), clock(day(2025, 10, 26), 9))
        let leapYear = CallPeriod(scope: .year, containing: day(2028, 1, 1))
        XCTAssertEqual(leapYear.comparisonCutoff(now: time(day(2028, 10, 26), 9)), time(day(2027, 10, 26), 9), "same date")
        XCTAssertEqual(custom.comparisonCutoff(now: time(day(10, 20), 15)), time(day(10, 5), 15))
        XCTAssertEqual(october.daysSoFar(now: time(day(10, 26), 9)), day(10, 1)...day(10, 26))
        XCTAssertEqual(october.daysSoFar(now: day(12, 1)), day(10, 1)...day(10, 31))
        XCTAssertEqual(october.daysSoFar(now: day(9, 1)), day(10, 1)...day(10, 1), "not begun yet")
    }

    func testAllCallsWhateverTheirDate() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let dates = [time(day(1990, 1, 1), 9), time(day(10, 26), 9), time(day(2030, 1, 1), 9)]
        for date in dates.reversed() { context.insert(PhoneCall(date: date, length: .short, caller: "A")) }
        let all = CallPeriod(scope: .all, containing: day(10, 26))
        XCTAssertEqual(try context.fetch(all.descriptor).map(\.date), dates, "every call, oldest first")
        let october = CallPeriod(scope: .month, containing: day(10, 26))
        XCTAssertEqual(try context.fetch(october.descriptor).map(\.date), [dates[1]])
    }

    func testStatistics() {
        let calls = [
            call("Meier", "Mortgage", .short, at: time(day(10, 5), 9, 15)),   // Monday
            call("Meier", "mortgage", .medium, at: time(day(10, 6), 9, 45)),  // Tuesday
            call("Huber", "Limits", .long, at: time(day(10, 6), 14)),
            call("Huber", "Payments", .short, at: time(day(11, 2), 16)),      // Monday, next month
            call("Keller", "", .short, at: time(day(11, 3), 8)),
            call("Keller", "", .short, at: time(day(11, 4), 8)),
        ]
        XCTAssertEqual(CallReport.total(calls).estimatedMinutes, 7.5 * 4 + 37.5 + 75)
        XCTAssertEqual(CallReport.byCaller(calls).first { $0.name == "Huber" }?.estimatedMinutes, 82.5)
        XCTAssertEqual(CallReport.total(calls).solvedShare, 0)
        XCTAssertNil(CallReport.total([]).solvedShare)

        XCTAssertEqual(CallStats.Bucket.forSpan(from: day(10, 1), to: day(10, 31)), .day)
        XCTAssertEqual(CallStats.Bucket.forSpan(from: day(10, 1), to: day(12, 31)), .week)
        XCTAssertEqual(CallStats.Bucket.forSpan(from: day(1, 1), to: day(12, 31)), .month)

        let months = CallStats.timeline(calls, bucket: .month)
        XCTAssertEqual(months.map(\.start), [day(10, 1), day(10, 1), day(10, 1), day(11, 1)])
        XCTAssertEqual(months.map(\.length), [.short, .medium, .long, .short])
        XCTAssertEqual(months.map(\.count), [1, 1, 1, 3])
        let weeks = CallStats.timeline(calls, bucket: .week)
        XCTAssertEqual(Set(weeks.map(\.start)), [day(10, 5), day(11, 2)], "weeks start on Monday")

        XCTAssertEqual(CallStats.byWeekday(calls), [2, 3, 1, 0, 0, 0, 0])
        let hours = CallStats.byHour(calls)
        XCTAssertEqual(hours[8], 2)
        XCTAssertEqual(hours[9], 2)
        XCTAssertEqual(hours[14], 1)
        XCTAssertEqual(hours.reduce(0, +), 6)

        let recurring = CallStats.recurring(calls)
        XCTAssertEqual(recurring.count, 1, "a topic is needed, and one call isn't recurring")
        XCTAssertEqual(recurring.first?.caller, "Meier")
        XCTAssertEqual(recurring.first?.topic, "mortgage", "the latest spelling")
        XCTAssertEqual(recurring.first?.calls, 2)
        XCTAssertEqual(recurring.first?.estimatedMinutes, 45)
        XCTAssertEqual(recurring.first?.last, time(day(10, 6), 9, 45))

        XCTAssertEqual(CallStats.formatEstimate(minutes: 82.5), "≈ 1h 23m")
    }

    func testFilterIgnoresItsOwnColumn() {
        let meier = call("Meier", "Mortgage", at: day(10, 1))
        let filter = CallFilter(caller: "meier", topic: "Limits")
        XCTAssertFalse(filter.matches(meier))
        XCTAssertTrue(filter.matches(meier, ignoring: \.topic), "the topic column lists the caller's other topics")
        XCTAssertEqual(filter.summary, "meier · Limits")
    }

    func testV5StoreGainsCalls() throws {
        let url = try temporaryDirectory(self).appendingPathComponent("v5.store")
        do {
            let legacy = try ModelContainer(for: Schema(versionedSchema: WorkTrackerSchemaV5.self),
                                            configurations: ModelConfiguration(url: url))
            let project = Project(name: "Alpha")
            legacy.mainContext.insert(project)
            legacy.mainContext.insert(WorkSegment(date: day(10, 1), startTime: time(day(10, 1), 8),
                                                  endTime: time(day(10, 1), 12), project: project))
            try legacy.mainContext.save()
        }
        do {
            let container = try ModelContainer.workTracker(url: url)
            let context = container.mainContext
            XCTAssertEqual(try context.fetch(FetchDescriptor<WorkSegment>()).first?.project?.name, "Alpha")
            CallLog.add(caller: "Meier", topic: "", length: .short, solvedByMe: true, at: day(10, 2), context: context)
            try context.save()
        }
        let reopened = try ModelContainer.workTracker(url: url)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<PhoneCall>()).map(\.caller), ["Meier"])
    }
}

/// The Siri intent as Siri runs it: parameters filled in, then `perform()`.
@MainActor
final class LogCallIntentTests: XCTestCase {
    func testLoggingThroughSiri() async throws {
        let container = try inMemoryContainer()
        let preferences = Preferences.shared
        let saved = (preferences.callTrackingEnabled, preferences.callDepartments, IntentStore.container)
        defer {
            preferences.callTrackingEnabled = saved.0
            preferences.callDepartments = saved.1
            IntentStore.container = saved.2
        }
        IntentStore.container = container
        preferences.callDepartments = ["Credit", "Legal"]
        CallLog.add(caller: "Meier", topic: "Mortgage", department: "Legal", length: .short, solvedByMe: false,
                    at: time(day(10, 1), 9), context: container.mainContext)

        var intent = LogCallIntent()
        intent.caller = CallerEntity(id: "meier")
        intent.topic = CallTopicEntity(id: "mortgage")
        intent.length = .long
        intent.solvedByMe = true

        preferences.callTrackingEnabled = false
        do {
            _ = try await intent.perform()
            XCTFail("calls aren't tracked on this Mac")
        } catch let message as IntentMessage {
            XCTAssertTrue(message.text.contains("Track calls") || message.text.contains("protokollieren"))
        }

        preferences.callTrackingEnabled = true
        _ = try await intent.perform()
        let calls = try container.mainContext.fetch(FetchDescriptor<PhoneCall>(sortBy: [SortDescriptor(\.date)]))
        let logged = try XCTUnwrap(calls.last)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual([logged.caller, logged.topic, logged.department], ["Meier", "Mortgage", "Legal"],
                       "earlier spelling, and the caller's usual department")
        XCTAssertEqual(logged.length, .long)
        XCTAssertTrue(logged.solvedByMe)

        // A new intent: parameters are reference-backed, so a copy would share them.
        var blank = LogCallIntent()
        blank.caller = CallerEntity(id: "  ")
        blank.topic = CallTopicEntity(id: "mortgage")
        blank.length = .short
        blank.solvedByMe = false
        do {
            _ = try await blank.perform()
            XCTFail("a blank caller from Shortcuts is refused")
        } catch is IntentMessage {}
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PhoneCall>()), 2)

        intent.department = CallDepartmentEntity(id: "Credit")
        intent.note = " follow up "
        _ = try await intent.perform()
        let last = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<PhoneCall>(sortBy: [SortDescriptor(\.date)])).last)
        XCTAssertEqual(last.department, "Credit")
        XCTAssertEqual(last.note, "follow up")
    }
}
