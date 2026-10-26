import XCTest
import SwiftData
@testable import WorkTracker

/// A Work Tracker with its tools, at Friday 23 October 2026, 15:00, tracking since 1 October.
@MainActor
private final class Assistant {
    let container: ModelContainer
    let preferences: Preferences
    let timer: WorkTimer
    let tools: AssistantTools
    let handler: MCPHandler
    var now = time(day(10, 23), 15)
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try inMemoryContainer()
        let defaults = UserDefaults(suiteName: "AssistantTests-\(UUID().uuidString)")!
        preferences = Preferences(defaults: defaults)
        preferences.trackingStartDate = day(10, 1)
        timer = WorkTimer(defaults: defaults)
        var clock: (() -> Date)!
        tools = AssistantTools(context: container.mainContext, preferences: preferences, timer: timer,
                               now: { clock() })
        handler = MCPHandler(tools: tools)
        clock = { [unowned self] in self.now }
    }

    @discardableResult
    func project(_ name: String, archived: Bool = false) -> Project {
        let project = Project(name: name)
        project.isArchived = archived
        context.insert(project)
        return project
    }

    @discardableResult
    func entry(_ date: Date, _ start: Int, _ end: Int, _ project: Project, note: String = "") -> WorkSegment {
        let segment = WorkSegment(date: date, startTime: time(date, start), endTime: time(date, end), project: project, note: note)
        context.insert(segment)
        return segment
    }

    /// A tool's result as the assistant reads it (through JSON).
    func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let value = try tools.call(name, ToolArguments(arguments))
        let data = try JSONSerialization.data(withJSONObject: value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The error message a tool call fails with, or nil when it succeeds.
    func failure(_ name: String, _ arguments: [String: Any] = [:]) -> String? {
        do {
            _ = try tools.call(name, ToolArguments(arguments))
            return nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    var entries: [WorkSegment] {
        (try? context.fetch(FetchDescriptor<WorkSegment>(sortBy: [SortDescriptor(\.startTime)]))) ?? []
    }

    var absences: [VacationDay] {
        (try? context.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)]))) ?? []
    }
}

private func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

@MainActor
final class AssistantToolTests: XCTestCase {
    func testOverview() throws {
        let app = try Assistant()
        let alpha = app.project("Alpha")
        app.entry(day(10, 23), 8, 12, alpha)
        app.timer.start(project: alpha, at: time(day(10, 23), 13, 30))
        let overview = try app.call("get_overview")

        XCTAssertEqual(overview["now"] as? String, "2026-10-23 15:00")
        XCTAssertEqual(overview["weekday"] as? String, "Friday")
        let today = try XCTUnwrap(overview["today"] as? [String: Any])
        XCTAssertEqual(double(today["worked"]), 4)
        XCTAssertEqual(double(today["expected"]), 8)
        XCTAssertEqual(double(today["balance"]), -4)
        let timer = try XCTUnwrap(overview["timer"] as? [String: Any])
        XCTAssertEqual(timer["running"] as? Bool, true)
        XCTAssertEqual(timer["project"] as? String, "Alpha")
        XCTAssertEqual(double(timer["elapsed_hours"]), 1.5)
        let missing = try XCTUnwrap(overview["days_without_entries"] as? [String: Any])
        XCTAssertEqual(missing["count"] as? Int, 16, "1–22 October: 16 working days, none logged")
    }

    func testSummaryWithHolidayAbsenceAndBreakdown() throws {
        let app = try Assistant()
        let alpha = app.project("Alpha"), beta = app.project("Beta")
        app.entry(day(12, 21), 8, 12, alpha)
        app.entry(day(12, 21), 13, 17, beta)
        app.context.insert(VacationDay(date: day(12, 22), type: .vacation))
        let summary = try app.call("get_summary", ["from": "2026-12-21", "to": "2026-12-25", "breakdown": "day"])

        // Mon 8 + Tue vacation (0) + Wed 8 + Thu/Fri holidays (0).
        XCTAssertEqual(double(summary["expected"]), 16)
        XCTAssertEqual(double(summary["worked"]), 8)
        XCTAssertEqual(summary["public_holidays"] as? Int, 2)
        let projects = try XCTUnwrap(summary["projects"] as? [[String: Any]])
        XCTAssertEqual(Set(projects.compactMap { $0["project"] as? String }), ["Alpha", "Beta"])
        let days = try XCTUnwrap(summary["days"] as? [[String: Any]])
        XCTAssertEqual(days.map { $0["date"] as? String }, ["2026-12-21", "2026-12-22", "2026-12-23", "2026-12-24", "2026-12-25"])
        XCTAssertEqual((days[1]["absence"] as? [String: Any])?["category"] as? String, "vacation")
        XCTAssertEqual(days[3]["holiday"] as? String, "Heiligabend")
        XCTAssertNil(days[2]["missing_entries"], "December is still in the future")
    }

    func testSummaryStartsAtTrackingStartAndBreaksDownByMonth() throws {
        let app = try Assistant()
        let summary = try app.call("get_summary", ["from": "2026-09-01", "to": "2026-11-30", "breakdown": "month"])
        XCTAssertEqual(summary["from"] as? String, "2026-10-01")
        XCTAssertNotNil(summary["note"])
        let months = try XCTUnwrap(summary["months"] as? [[String: Any]])
        XCTAssertEqual(months.map { $0["month"] as? String }, ["2026-10", "2026-11"])
        XCTAssertEqual(double(months[0]["expected"]), 22 * 8)

        let weeks = try XCTUnwrap(app.call("get_summary", ["from": "2026-10-01", "to": "2026-10-11", "breakdown": "week"])["weeks"] as? [[String: Any]])
        XCTAssertEqual(weeks.map { $0["from"] as? String }, ["2026-10-01", "2026-10-05"])
        XCTAssertEqual(weeks.map { $0["week_of"] as? String }, ["2026-09-28", "2026-10-05"])
    }

    func testAddEntries() throws {
        let app = try Assistant()
        let alpha = app.project("Alpha")
        app.project("Beta")
        let result = try app.call("add_entries", ["entries": [
            ["date": "yesterday", "start": "8:30", "end": "12:00", "project": "alpha", "note": " Review "],
            ["date": "2026-10-22", "start": "1300", "end": "24:00", "project": "Beta"],
        ]])
        XCTAssertEqual(double(result["total_hours"]), 14.5)
        XCTAssertEqual(app.entries.map(\.note), ["Review", ""])
        XCTAssertEqual(app.entries.first?.project?.name, alpha.name)
        XCTAssertEqual(app.entries.last?.endTime, day(10, 23), "24:00 is midnight at the end of the day")
        let added = try XCTUnwrap(result["added"] as? [[String: Any]])
        XCTAssertEqual(added.last?["end"] as? String, "24:00")
        XCTAssertEqual(added.first?["id"] as? String, app.entries.first?.syncID?.uuidString)
    }

    func testAddEntriesSavesNothingWhenOneIsInvalid() throws {
        let app = try Assistant()
        let alpha = app.project("Alpha")
        app.project("Old", archived: true)
        app.entry(day(10, 22), 9, 10, alpha)

        let overlapsExisting = app.failure("add_entries", ["entries": [
            ["date": "2026-10-21", "start": "08:00", "end": "09:00", "project": "Alpha"],
            ["date": "2026-10-22", "start": "09:30", "end": "11:00", "project": "Alpha"],
        ]])
        XCTAssertTrue(overlapsExisting?.hasPrefix("Entry 2:") == true, overlapsExisting ?? "")
        let overlapsEachOther = app.failure("add_entries", ["entries": [
            ["date": "2026-10-21", "start": "08:00", "end": "09:00", "project": "Alpha"],
            ["date": "2026-10-21", "start": "08:30", "end": "10:00", "project": "Alpha"],
        ]])
        XCTAssertTrue(overlapsEachOther?.contains("overlaps entry 1") == true, overlapsEachOther ?? "")
        XCTAssertEqual(app.entries.count, 1, "nothing saved")

        XCTAssertTrue(app.failure("add_entries", ["entries": [["date": "2026-10-21", "start": "8", "end": "9", "project": "Old"]]])?
            .contains("archived") == true)
        XCTAssertTrue(app.failure("add_entries", ["entries": [["date": "2026-10-21", "start": "8", "end": "9", "project": "Gamma"]]])?
            .contains("Projects: Alpha") == true)
        XCTAssertNotNil(app.failure("add_entries", ["entries": [["date": "2026-02-30", "start": "8", "end": "9", "project": "Alpha"]]]))
        XCTAssertNotNil(app.failure("add_entries", ["entries": [["date": "2026-10-21", "start": "10", "end": "9", "project": "Alpha"]]]))
        XCTAssertEqual(app.entries.count, 1)
    }

    func testUpdateAndDeleteEntries() throws {
        let app = try Assistant()
        let alpha = app.project("Alpha"), beta = app.project("Beta")
        let moved = app.entry(day(10, 21), 9, 11, alpha, note: "Draft")
        let other = app.entry(day(10, 22), 10, 12, beta)
        let id = try XCTUnwrap(moved.syncID?.uuidString)

        XCTAssertNotNil(app.failure("update_entry", ["id": id, "date": "2026-10-22"]), "overlaps 10–12 there")
        let result = try app.call("update_entry", ["id": id, "date": "2026-10-22", "end": "10:00", "project": "Beta", "note": ""])
        XCTAssertEqual((result["after"] as? [String: Any])?["start"] as? String, "09:00", "keeps its start time")
        XCTAssertEqual(moved.date, day(10, 22))
        XCTAssertEqual(moved.durationHours, 1)
        XCTAssertEqual(moved.project?.name, "Beta")
        XCTAssertEqual(moved.note, "")

        let missing = app.failure("delete_entries", ["ids": [id, UUID().uuidString]])
        XCTAssertTrue(missing?.contains("Nothing was deleted") == true)
        XCTAssertEqual(app.entries.count, 2)
        let deleted = try app.call("delete_entries", ["ids": [id, try XCTUnwrap(other.syncID?.uuidString)]])
        XCTAssertEqual((deleted["deleted"] as? [Any])?.count, 2)
        XCTAssertEqual(app.entries.count, 0)
    }

    func testListEntriesAndCopy() throws {
        let app = try Assistant()
        let alpha = app.project("Alpha"), beta = app.project("Beta")
        app.entry(day(10, 19), 8, 12, alpha)
        app.entry(day(10, 19), 13, 17, beta)
        app.entry(day(10, 20), 14, 15, alpha)

        let list = try app.call("list_entries", ["from": "2026-10-19", "to": "2026-10-20", "project": "Alpha"])
        XCTAssertEqual(list["count"] as? Int, 2)
        XCTAssertEqual(double(list["total_hours"]), 5)
        XCTAssertEqual((try app.call("list_entries", ["from": "2026-10-19", "limit": 1])["entries"] as? [Any])?.count, 1)
        XCTAssertNotNil(app.failure("list_entries", ["from": "2026-10-19", "limit": 1e300]), "no integer overflow")

        let copy = try app.call("copy_entries", ["from_date": "2026-10-19", "to_date": "2026-10-20"])
        XCTAssertEqual(copy["copied"] as? Int, 1, "8–12 copied")
        XCTAssertEqual(copy["skipped_because_of_overlaps"] as? Int, 1, "13–17 overlaps 14–15")
    }

    func testAbsences() throws {
        let app = try Assistant()
        let result = try app.call("set_absences", ["from": "2026-12-21", "to": "2027-01-03", "category": "Ferien"])
        // 21–23, 28–31 December; 24/25 December and 1 January are holidays, the rest weekends.
        XCTAssertEqual(result["days"] as? [String], ["2026-12-21", "2026-12-22", "2026-12-23",
                                                      "2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31"])
        let skipped = try XCTUnwrap(result["skipped"] as? [[String: Any]])
        XCTAssertTrue(skipped.contains { $0["reason"] as? String == "public holiday (Weihnachten)" })
        let budget = try XCTUnwrap((result["vacation"] as? [[String: Any]])?.first)
        XCTAssertEqual(double(budget["used_days"]), 6.5, "Silvester is a half-day holiday")
        XCTAssertEqual(app.absences.count, 7)

        _ = try app.call("set_absences", ["from": "2026-12-28", "category": "sick", "half_day": true])
        let list = try XCTUnwrap(app.call("list_absences", ["from": "2026-12-28", "to": "2026-12-28"])["absences"] as? [[String: Any]])
        XCTAssertEqual(list.first?["category"] as? String, "sick")
        XCTAssertEqual(double(list.first?["counted_days"]), 0.5)

        XCTAssertNotNil(app.failure("set_absences", ["from": "2026-12-26", "to": "2026-12-27", "category": "vacation"]),
                        "a weekend has no working day")
        XCTAssertTrue(app.failure("set_absences", ["from": "2026-12-28", "category": "Sabbatical"])?.contains("no absence category") == true)

        let removed = try app.call("remove_absences", ["from": "2026-12-28", "to": "2026-12-31"])
        XCTAssertEqual((removed["removed"] as? [Any])?.count, 4)
        XCTAssertEqual(app.absences.count, 3)
        XCTAssertEqual(double(try app.call("get_vacation", ["year": 2026])["used_days"]), 3)
    }

    func testCustomCategories() throws {
        let app = try Assistant()
        let created = try app.call("create_absence_category", ["name": "Training", "rule": "reduce_hours", "color": "green", "icon": "Study"])
        XCTAssertEqual(created["icon"] as? String, "book.fill")
        XCTAssertNotNil(app.failure("create_absence_category", ["name": "training", "rule": "unchanged"]), "names are unique")
        XCTAssertNotNil(app.failure("create_absence_category", ["name": "Krank", "rule": "unchanged"]), "built-in names in any language")

        _ = try app.call("set_absences", ["from": "2026-11-02", "category": "Training"])
        XCTAssertEqual(app.absences.first?.category?.name, "Training")
        let updated = try app.call("update_absence_category", ["category": "training", "rule": "unchanged", "archived": true])
        XCTAssertNotNil(updated["note"])
        XCTAssertEqual(app.absences.first?.entry.category.rule, .reduceHours, "existing absences keep their rule")
        XCTAssertTrue(app.failure("set_absences", ["from": "2026-11-03", "category": "Training"])?.contains("archived") == true)
        XCTAssertTrue(app.failure("update_absence_category", ["category": "vacation", "name": "Holidays"])?.contains("built in") == true)
        let categories = try XCTUnwrap(app.call("list_absence_categories")["categories"] as? [[String: Any]])
        XCTAssertEqual(categories.count, 5)
    }

    func testProjects() throws {
        let app = try Assistant()
        _ = try app.call("create_project", ["name": "Alpha", "color": "teal"])
        XCTAssertNotNil(app.failure("create_project", ["name": "ALPHA"]))
        XCTAssertNotNil(app.failure("create_project", ["name": "Beta", "color": "brown"]))
        _ = try app.call("add_entries", ["entries": [["date": "2026-10-22", "start": "9", "end": "10", "project": "Alpha"]]])
        XCTAssertTrue(app.failure("delete_project", ["project": "Alpha"])?.contains("archive") == true)

        let renamed = try app.call("update_project", ["project": "alpha", "name": "Alpha 2", "archived": true])
        XCTAssertEqual(renamed["name"] as? String, "Alpha 2")
        XCTAssertEqual(renamed["archived"] as? Bool, true)
        XCTAssertEqual(double(renamed["total_hours"]), 1)
        XCTAssertEqual((try app.call("list_projects")["projects"] as? [Any])?.count, 0)
        XCTAssertEqual((try app.call("list_projects", ["include_archived": true])["projects"] as? [Any])?.count, 1)

        _ = try app.call("create_project", ["name": "Empty"])
        XCTAssertEqual(try app.call("delete_project", ["project": "Empty"])["deleted"] as? String, "Empty")
    }

    func testTimer() throws {
        let app = try Assistant()
        app.project("Alpha")
        app.project("Beta")
        XCTAssertNotNil(app.failure("start_timer", ["project": "Alpha", "at": "16:00"]), "can't start in the future")
        _ = try app.call("start_timer", ["project": "Alpha", "at": "13:00"])
        XCTAssertNotNil(app.failure("start_timer", ["project": "Beta", "at": "12:00"]), "before the running timer")
        _ = try app.call("start_timer", ["project": "Beta", "at": "14:00"])
        let stopped = try app.call("stop_timer", ["at": "2026-10-23 14:45"])
        XCTAssertEqual((stopped["saved"] as? [[String: Any]])?.first?["project"] as? String, "Beta")
        XCTAssertEqual(app.entries.map(\.durationHours), [1, 0.75])
        XCTAssertNotNil(app.failure("stop_timer"))

        _ = try app.call("start_timer")
        XCTAssertEqual(app.timer.project(in: app.context)?.name, "Beta", "the last-used project")
        _ = try app.call("discard_timer")
        XCTAssertFalse(app.timer.isRunning)
        XCTAssertEqual(app.entries.count, 2)
    }

    func testSettingsAndSchedule() throws {
        let app = try Assistant()
        XCTAssertNotNil(app.failure("update_settings"))
        XCTAssertNotNil(app.failure("update_settings", ["vacation_entitlement_days": 25.3]))
        XCTAssertNotNil(app.failure("update_settings", ["opening_balance_hours": 1e300]))
        _ = try app.call("update_settings", ["opening_balance_hours": "+12:30", "vacation_entitlement_days": 27.5,
                                             "carry_over_vacation": true])
        XCTAssertEqual(app.preferences.openingBalanceHours, 12.5)
        XCTAssertEqual(app.preferences.vacationEntitlement, 27.5)
        XCTAssertTrue(app.preferences.carryOverVacation)

        let settings = try app.call("set_schedule", ["effective_from": "2027-01-01", "hours": [8, 8, 8, 8, 0, 0, 0]])
        XCTAssertEqual((settings["schedule"] as? [Any])?.count, 2)
        XCTAssertEqual(app.preferences.schedule.hours(on: day(2027, 1, 8)), 0, "Fridays off from January")
        XCTAssertEqual(app.preferences.schedule.hours(on: day(2026, 12, 18)), 8)
        _ = try app.call("set_schedule", ["effective_from": "2027-01-01", "hours": [8, 8, 8, 8, 4, 0, 0]])
        XCTAssertEqual(app.preferences.schedule.periods.count, 2, "same day replaces the change")
        XCTAssertNotNil(app.failure("set_schedule", ["effective_from": "initial", "hours": [8, 8, 8]]))
        _ = try app.call("remove_schedule_change", ["effective_from": "2027-01-01"])
        XCTAssertEqual(app.preferences.schedule.periods.count, 1)
        XCTAssertNotNil(app.failure("remove_schedule_change", ["effective_from": "2027-01-01"]))
    }

    func testDaysWithoutEntriesAndHolidays() throws {
        let app = try Assistant()
        let alpha = app.project("Alpha")
        app.entry(day(10, 22), 9, 17, alpha)
        app.context.insert(VacationDay(date: day(10, 21), type: .sick))
        let missing = try app.call("list_days_without_entries", ["from": "2026-10-19"])
        XCTAssertEqual((missing["days"] as? [[String: Any]])?.compactMap { $0["date"] as? String }, ["2026-10-20", "2026-10-19"],
                       "not today, the sick day or the logged day")
        let holidays = try XCTUnwrap(app.call("list_holidays", ["year": 2026])["holidays"] as? [[String: Any]])
        XCTAssertEqual(holidays.count, 14)
        XCTAssertEqual(holidays.first(where: { $0["name"] as? String == "Knabenschiessen" })?["date"] as? String, "2026-09-14")
    }

    func testEveryToolIsListedAndHandled() throws {
        let app = try Assistant()
        for definition in AssistantTools.definitions {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(definition.json), definition.name)
            let message = app.failure(definition.name, ["unexpected": true])
            XCTAssertFalse(message?.hasPrefix("There's no tool") == true, definition.name)
        }
        XCTAssertEqual(Set(AssistantTools.definitions.map(\.name)).count, AssistantTools.definitions.count)
    }
}

@MainActor
final class MCPHandlerTests: XCTestCase {
    private func send(_ handler: MCPHandler, _ message: Any) throws -> Any? {
        try handler.handle(JSONSerialization.data(withJSONObject: message)).map { try JSONSerialization.jsonObject(with: $0) }
    }

    func testInitializeListAndCall() throws {
        let app = try Assistant()
        app.project("Alpha")
        let initialize = try XCTUnwrap(send(app.handler, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                          "params": ["protocolVersion": "2025-06-18"]]) as? [String: Any])
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil(result["instructions"])
        let unknownVersion = try XCTUnwrap(send(app.handler, ["jsonrpc": "2.0", "id": 2, "method": "initialize",
                                                              "params": ["protocolVersion": "1999-01-01"]]) as? [String: Any])
        XCTAssertEqual((unknownVersion["result"] as? [String: Any])?["protocolVersion"] as? String, MCPHandler.protocolVersions[0])

        XCTAssertNil(try send(app.handler, ["jsonrpc": "2.0", "method": "notifications/initialized"]))

        let list = try XCTUnwrap(send(app.handler, ["jsonrpc": "2.0", "id": "a", "method": "tools/list"]) as? [String: Any])
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AssistantTools.definitions.count)
        XCTAssertEqual(list["id"] as? String, "a")

        let call = try XCTUnwrap(send(app.handler, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                    "params": ["name": "list_projects", "arguments": [:]]]) as? [String: Any])
        let callResult = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        let text = try XCTUnwrap((callResult["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"name\":\"Alpha\""), text)
    }

    func testErrors() throws {
        let app = try Assistant()
        let toolError = try XCTUnwrap(send(app.handler, ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                         "params": ["name": "list_entries", "arguments": ["from": "soon"]]]) as? [String: Any])
        XCTAssertEqual((toolError["result"] as? [String: Any])?["isError"] as? Bool, true, "tool errors are results the model reads")

        let unknown = try XCTUnwrap(send(app.handler, ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                       "params": ["name": "format_disk"]]) as? [String: Any])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
        let method = try XCTUnwrap(send(app.handler, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"]) as? [String: Any])
        XCTAssertEqual((method["error"] as? [String: Any])?["code"] as? Int, -32601)

        let parse = try XCTUnwrap(app.handler.handle(Data("{".utf8)).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual((parse["error"] as? [String: Any])?["code"] as? Int, -32700)

        let batch = try XCTUnwrap(send(app.handler, [["jsonrpc": "2.0", "id": 1, "method": "ping"],
                                                     ["jsonrpc": "2.0", "method": "notifications/initialized"]]) as? [[String: Any]])
        XCTAssertEqual(batch.count, 1)
    }
}

final class HTTPParserTests: XCTestCase {
    func testSplitAndPipelinedRequests() throws {
        var parser = HTTPRequestParser()
        let first = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\n\r\nabcd"
        let second = "GET /mcp HTTP/1.1\r\nhost: localhost\r\n\r\n"
        let bytes = Data((first + second).utf8)
        parser.append(bytes.prefix(30))
        XCTAssertNil(try parser.next())
        parser.append(bytes.dropFirst(30).prefix(first.utf8.count - 32))
        XCTAssertNil(try parser.next(), "body incomplete")
        parser.append(bytes.dropFirst(first.utf8.count - 2))
        let request = try XCTUnwrap(parser.next())
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["host"], "127.0.0.1")
        XCTAssertEqual(request.body, Data("abcd".utf8))
        XCTAssertEqual(try parser.next()?.method, "GET")
        XCTAssertNil(try parser.next())
    }

    func testChunkedBody() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n".utf8))
        XCTAssertNil(try parser.next())
        parser.append(Data("0\r\n\r\n".utf8))
        XCTAssertEqual(try parser.next()?.body, Data("Wikipedia".utf8))
    }

    func testLimits() {
        var parser = HTTPRequestParser()
        parser.append(Data(repeating: 65, count: HTTPRequestParser.maxHeaderBytes + 1))
        XCTAssertThrowsError(try parser.next())
        var big = HTTPRequestParser()
        big.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: \(HTTPRequestParser.maxBodyBytes + 1)\r\n\r\n".utf8))
        XCTAssertThrowsError(try big.next())
        var garbage = HTTPRequestParser()
        garbage.append(Data("hello\r\n\r\n".utf8))
        XCTAssertThrowsError(try garbage.next())
    }
}

@MainActor
final class AssistantServerTests: XCTestCase {
    private func server(port: Int? = nil) throws -> (AssistantServer, Assistant) {
        let defaults = UserDefaults(suiteName: "AssistantServerTests-\(UUID().uuidString)")!
        if let port { defaults.set(port, forKey: "assistantServerPort") }
        let server = AssistantServer(defaults: defaults)
        let app = try Assistant()
        server.start(handler: app.handler)
        return (server, app)
    }

    private func request(_ server: AssistantServer, method: String = "POST", host: String = "127.0.0.1:47615",
                         origin: String? = nil, token: String? = nil, contentType: String = "application/json",
                         body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) -> HTTPResponse {
        var headers = ["host": host, "content-type": contentType, "authorization": "Bearer \(token ?? server.token)"]
        if let origin { headers["origin"] = origin }
        return server.respond(to: HTTPRequest(method: method, path: "/mcp", headers: headers, body: Data(body.utf8)))
    }

    func testRequestChecks() throws {
        let (server, _) = try server()
        XCTAssertEqual(server.token, "", "no token until turned on")
        server.renewToken()
        XCTAssertEqual(server.token.count, 48)

        XCTAssertEqual(request(server).status, 200)
        XCTAssertEqual(request(server, host: "localhost:47615").status, 200)
        XCTAssertEqual(request(server, host: "[::1]:47615").status, 200)
        XCTAssertEqual(request(server, host: "evil.example:47615").status, 403, "DNS rebinding")
        XCTAssertEqual(request(server, origin: "https://evil.example").status, 403)
        XCTAssertEqual(request(server, origin: "http://localhost:6274").status, 200)
        XCTAssertEqual(request(server, token: "wrong").status, 401)
        XCTAssertEqual(request(server, method: "GET").status, 405)
        XCTAssertEqual(request(server, contentType: "text/plain").status, 415)
        XCTAssertEqual(request(server, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).status, 202)
        let previous = server.token
        server.renewToken()
        XCTAssertEqual(request(server, token: previous).status, 401, "the old token stops working")
    }

    func testOverTheNetwork() async throws {
        let port = Int.random(in: 49_152...60_000)
        let (server, app) = try server(port: port)
        app.project("Alpha")
        server.setEnabled(true)
        defer { server.setEnabled(false) }
        for _ in 0..<50 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(server.isListening, server.errorMessage ?? "")

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_projects"}}"#.utf8)
        for _ in 0..<2 { // twice, over the same kept-alive connection
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#"\"name\":\"Alpha\""#))
        }

        request.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        let (_, refused) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 401)
    }
}
