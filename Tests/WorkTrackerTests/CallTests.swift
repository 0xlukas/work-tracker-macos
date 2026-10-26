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

    func testMarkdownForAnAIChat() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .en
        let calls = [
            call("Meier", "Mortgage | rates", .medium, at: time(day(10, 2), 14, 5), department: "Credit", solved: true,
                 note: "line one\nline two"),
            call("Huber", "", .short, at: time(day(10, 1), 9)),
        ]
        let text = CallExport.markdown(calls, scope: "October 2026")
        XCTAssertTrue(text.hasPrefix("# Calls: October 2026\n"))
        XCTAssertTrue(text.contains("- Calls: 2 (Under 15 minutes: 1, 15 minutes to 1 hour: 1, Over 1 hour: 0)"))
        XCTAssertTrue(text.contains("- Solved by me: 1 of 2"))
        XCTAssertTrue(text.contains("## By Department"))
        XCTAssertTrue(text.contains("| No topic | 1 | 1 | 0 | 0 | 0 |"))
        XCTAssertTrue(text.contains("| 2026-10-02 | Fri | 14:05 | Meier | Mortgage \\| rates | Credit | 15 minutes to 1 hour | Me | line one line two |"),
                      "pipes and line breaks don't break the table")
        let rows = text.components(separatedBy: "\n").filter { $0.hasPrefix("| 2026-") }
        XCTAssertEqual(rows.first?.contains("Huber"), true, "oldest first")

        XCTAssertFalse(CallExport.markdown([], scope: "Week").contains("## Calls"))
    }

    func testCSV() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .en
        let csv = CSVExporter(format: .excelGerman).calls([
            call("Meier", "Mortgage; rates", .long, at: time(day(10, 2), 14, 5), department: "Credit", solved: true),
        ])
        XCTAssertEqual(csv, "\u{FEFF}Date;Weekday;Time;Caller;Topic;Department;Length;Solved by;Note\n"
                       + "2026-10-02;Fri;14:05;Meier;\"Mortgage; rates\";Credit;Over 1 hour;Me;\n")
    }

    func testPeriods() {
        let week = CallPeriod(scope: .week, containing: time(day(10, 29), 15))
        XCTAssertEqual(week.from, day(10, 26))
        XCTAssertEqual(week.to, day(11, 1))
        XCTAssertEqual(week.shifted(by: -1).from, day(10, 19))
        let month = CallPeriod(scope: .month, containing: day(2, 14))
        XCTAssertEqual(month.from, day(2, 1))
        XCTAssertEqual(month.to, day(2, 28))
        XCTAssertEqual(month.shifted(by: 1).to, day(3, 31))
        let year = CallPeriod(scope: .year, containing: day(6, 1))
        XCTAssertEqual(year.from, day(1, 1))
        XCTAssertEqual(year.to, day(12, 31))
        XCTAssertTrue(year.contains(time(day(12, 31), 23, 59)))
        XCTAssertFalse(year.contains(day(2027, 1, 1)))
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
