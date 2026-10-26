import Foundation
import SwiftData

/// A tool call that can't be carried out. The message goes back to the assistant.
struct ToolError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The arguments of a tool call as the assistant sent them (decoded JSON), read with
/// checks that tell the assistant exactly what's wrong.
struct ToolArguments {
    let values: [String: Any]

    init(_ values: [String: Any] = [:]) { self.values = values }

    func has(_ key: String) -> Bool { values[key].map { !($0 is NSNull) } ?? false }

    func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw ToolError("Missing '\(key)'.") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        guard let value = values[key] as? String else { throw ToolError("'\(key)' must be a string.") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        if let value = values[key] as? Bool { return value }
        if let text = values[key] as? String, let value = Bool(text.lowercased()) { return value }
        throw ToolError("'\(key)' must be true or false.")
    }

    func number(_ key: String) throws -> Double? {
        guard has(key) else { return nil }
        if let value = values[key] as? NSNumber, value.doubleValue.isFinite { return value.doubleValue }
        if let text = values[key] as? String,
           let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
           value.isFinite {
            return value
        }
        throw ToolError("'\(key)' must be a number.")
    }

    func list(_ key: String) throws -> [Any]? {
        guard has(key) else { return nil }
        guard let value = values[key] as? [Any] else { throw ToolError("'\(key)' must be a list.") }
        return value
    }
}

/// How tools read and write dates, times and amounts: Zurich days as `YYYY-MM-DD`, times
/// as `HH:MM`, hours as decimals rounded to the minute's worth of precision people read.
enum ToolFormat {
    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    static func day(_ date: Date) -> String {
        let parts = Calendar.zurich.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func weekday(_ date: Date) -> String { weekdays[date.mondayBasedWeekday] }

    /// `2026-10-23 14:05`.
    static func moment(_ date: Date) -> String { "\(day(date)) \(TimeField.format(date))" }

    /// Hours with two decimals, as an exact JSON number (8.08, not 8.0800000000000001).
    static func hours(_ value: Double) -> Decimal {
        guard value.isFinite, abs(value) < 1e9 else { return Decimal(value) }
        return Decimal(Int((value * 100).rounded())) / 100
    }

    /// `YYYY-MM-DD`, an ISO date-time (its date part), or today/yesterday/tomorrow.
    static func parseDay(_ text: String, today: Date) throws -> Date {
        let input = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch input {
        case "today": return today
        case "yesterday": return today.addingDays(-1)
        case "tomorrow": return today.addingDays(1)
        default: break
        }
        let parts = input.prefix(10).split(separator: "-")
        guard input.count == 10 || input.dropFirst(10).first.map({ $0 == "t" || $0 == " " }) == true,
              parts.count == 3, parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else {
            throw ToolError("'\(text)' isn't a date. Use YYYY-MM-DD, today or yesterday.")
        }
        let date = Calendar.zurich.zurichDate(year: year, month: month, day: day)
        guard Calendar.zurich.component(.day, from: date) == day else {
            throw ToolError("\(text) doesn't exist.")
        }
        return date
    }

    /// `HH:MM` on `day`; `24:00` (the end of the day) only where an end time is meant.
    static func parseTime(_ text: String, on day: Date, isEnd: Bool) throws -> Date {
        guard let time = TimeField.parse(text, on: day, allowsEndOfDay: isEnd) else {
            throw ToolError("'\(text)' isn't a time. Use HH:MM (24-hour)\(isEnd ? ", or 24:00 for the end of the day" : "").")
        }
        return time
    }

    /// `HH:MM` today, or `YYYY-MM-DD HH:MM`.
    static func parseMoment(_ text: String, now: Date) throws -> Date {
        let input = text.trimmingCharacters(in: .whitespaces)
        if input.count > 10 {
            let day = try parseDay(String(input.prefix(10)), today: now.startOfDayZurich)
            return try parseTime(String(input.dropFirst(11)), on: day, isEnd: false)
        }
        return try parseTime(input, on: now.startOfDayZurich, isEnd: false)
    }
}

/// One tool as MCP lists it.
struct ToolDefinition {
    enum Effect { case read, write, delete }

    let name: String
    let title: String
    let description: String
    var properties: [String: [String: Any]] = [:]
    var required: [String] = []
    let effect: Effect

    var json: [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": schema,
            "annotations": [
                "title": title,
                "readOnlyHint": effect == .read,
                "destructiveHint": effect == .delete,
                "openWorldHint": false,
            ] as [String: Any],
        ]
    }
}

/// JSON Schema snippets for tool parameters.
@MainActor
private enum Param {
    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    static func bool(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    static func choice(_ description: String, _ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }
    static func day(_ description: String) -> [String: Any] { string("\(description) YYYY-MM-DD, or today/yesterday.") }
    static func time(_ description: String) -> [String: Any] { string("\(description) HH:MM, 24-hour.") }

    static let project = string("Project name (case doesn't matter) or id.")
    static let category = string("vacation, sick, service (public service), unpaid (unpaid leave), or a custom category's name or id.")
    static let color = choice("Colour.", PaletteColor.allCases.map(\.rawValue))
    static let rule = choice("How the absence counts: reduce_hours (time off without using vacation), vacation_allowance (uses the annual vacation allowance), unchanged (recorded, no time credit).",
                             ["reduce_hours", "vacation_allowance", "unchanged"])
    static let icon = choice("SF Symbol.", AbsenceCategory.iconChoices.map(\.symbol))
    static let callLength = choice("How long the call took: short (under 15 minutes), medium (15 minutes to 1 hour) or long (over 1 hour).",
                                   CallLength.allCases.map(\.rawValue))
    static let department = string("Department, one of the list in get_call_summary's 'departments' (case doesn't matter); empty for none.")
    static let weekHours: [String: Any] = [
        "type": "array", "items": ["type": "number"], "minItems": 7, "maxItems": 7,
        "description": "Hours for Monday … Sunday, e.g. [8.4, 8.4, 8.4, 8.4, 8.4, 0, 0].",
    ]
}

/// Work Tracker's data and actions for AI assistants (see `MCPHandler`). Every tool
/// works on the app's own database and preferences, so answers match what the app
/// shows and changes sync to the other Macs like changes made in the app.
@MainActor
final class AssistantTools {
    let context: ModelContext
    let preferences: Preferences
    let timer: WorkTimer
    let deviceSync: DeviceSync?
    let now: () -> Date

    init(context: ModelContext, preferences: Preferences, timer: WorkTimer, deviceSync: DeviceSync? = nil,
         now: @escaping () -> Date = Date.init) {
        self.context = context
        self.preferences = preferences
        self.timer = timer
        self.deviceSync = deviceSync
        self.now = now
    }

    // MARK: - Catalog

    static let definitions: [ToolDefinition] = [
        // Reading
        ToolDefinition(name: "get_overview", title: "Overview",
                       description: "Today's date and time, hours worked and balance (worked − expected) for today, this week, this month and this year, the all-time overtime balance, this year's vacation allowance, days without entries and the running timer. Start here.",
                       effect: .read),
        ToolDefinition(name: "get_summary", title: "Summary for a period",
                       description: "Worked and expected hours, balance, working days, public holidays, absence days per category and hours per project for a date range, optionally broken down by day, week or month. Days before the tracking start expect nothing.",
                       properties: ["from": Param.day("First day."), "to": Param.day("Last day (inclusive); defaults to 'from'."),
                                    "breakdown": Param.choice("Rows per day, week or month; none by default.", ["none", "day", "week", "month"])],
                       required: ["from"], effect: .read),
        ToolDefinition(name: "list_entries", title: "List time entries",
                       description: "Time entries in a date range (id, date, start, end, hours, project, note), oldest first.",
                       properties: ["from": Param.day("First day."), "to": Param.day("Last day (inclusive); defaults to 'from'."),
                                    "project": Param.string("Only this project (name or id)."),
                                    "limit": Param.number("Most entries to return; 300 by default, at most 2000.")],
                       required: ["from"], effect: .read),
        ToolDefinition(name: "list_projects", title: "List projects",
                       description: "Projects with colour, entry count, total hours and the last day worked on them.",
                       properties: ["include_archived": Param.bool("Include archived projects; false by default.")],
                       effect: .read),
        ToolDefinition(name: "list_absences", title: "List absences",
                       description: "Absences (vacation, sick days, …) in a date range, with category, half/full day and how many days each counts.",
                       properties: ["from": Param.day("First day."), "to": Param.day("Last day (inclusive); defaults to 'from'.")],
                       required: ["from"], effect: .read),
        ToolDefinition(name: "list_absence_categories", title: "List absence categories",
                       description: "Built-in and custom absence categories with their counting rules.",
                       effect: .read),
        ToolDefinition(name: "get_vacation", title: "Vacation allowance",
                       description: "A year's vacation allowance (entitlement, carried over, used, remaining) and the days that used it. Days beyond the allowance get no time credit.",
                       properties: ["year": Param.number("Year; this year by default.")],
                       effect: .read),
        ToolDefinition(name: "list_days_without_entries", title: "Days without entries",
                       description: "Past working days with expected hours but no time entries and no full-day absence, most recent first. Today never counts.",
                       properties: ["from": Param.day("First day; the tracking start by default."),
                                    "to": Param.day("Last day; yesterday by default.")],
                       effect: .read),
        ToolDefinition(name: "list_holidays", title: "Public holidays",
                       description: "Zurich public holidays of a year, full and half days.",
                       properties: ["year": Param.number("Year; this year by default.")],
                       effect: .read),
        ToolDefinition(name: "get_settings", title: "Settings",
                       description: "Work schedule (hours per weekday, with changes over time), tracking start, opening balance and vacation settings.",
                       effect: .read),

        // Time entries
        ToolDefinition(name: "add_entries", title: "Add time entries",
                       description: "Add one or more time entries. Each stays within one day and can't overlap another entry. If any entry is invalid, nothing is saved.",
                       properties: ["entries": [
                           "type": "array", "minItems": 1,
                           "items": ["type": "object",
                                     "properties": ["date": Param.day("Day."), "start": Param.time("Start."),
                                                    "end": Param.time("End (24:00 for midnight)."),
                                                    "project": Param.project, "note": Param.string("Optional note.")],
                                     "required": ["date", "start", "end", "project"]] as [String: Any],
                       ]],
                       required: ["entries"], effect: .write),
        ToolDefinition(name: "update_entry", title: "Change a time entry",
                       description: "Change an entry's day, times, project or note. Moving it to another day keeps its times unless new ones are given.",
                       properties: ["id": Param.string("Entry id from list_entries."), "date": Param.day("New day."),
                                    "start": Param.time("New start."), "end": Param.time("New end (24:00 for midnight)."),
                                    "project": Param.project, "note": Param.string("New note; empty to remove it.")],
                       required: ["id"], effect: .write),
        ToolDefinition(name: "delete_entries", title: "Delete time entries",
                       description: "Delete time entries by id. All ids must exist, or nothing is deleted.",
                       properties: ["ids": ["type": "array", "items": ["type": "string"], "minItems": 1,
                                            "description": "Entry ids from list_entries."]],
                       required: ["ids"], effect: .delete),
        ToolDefinition(name: "copy_entries", title: "Copy a day's entries",
                       description: "Copy every entry of one day to another day at the same times. Entries that would overlap something already there are skipped.",
                       properties: ["from_date": Param.day("Day to copy from."), "to_date": Param.day("Day to copy to.")],
                       required: ["from_date", "to_date"], effect: .write),

        // Absences
        ToolDefinition(name: "set_absences", title: "Record absences",
                       description: "Mark every working day in a range as an absence of one category (replacing another category there). Weekends, days without scheduled hours and full-day public holidays are skipped.",
                       properties: ["from": Param.day("First day."), "to": Param.day("Last day (inclusive); defaults to 'from'."),
                                    "category": Param.category, "half_day": Param.bool("Half days; false by default.")],
                       required: ["from", "category"], effect: .write),
        ToolDefinition(name: "remove_absences", title: "Remove absences",
                       description: "Remove every absence in a date range.",
                       properties: ["from": Param.day("First day."), "to": Param.day("Last day (inclusive); defaults to 'from'.")],
                       required: ["from"], effect: .delete),
        ToolDefinition(name: "create_absence_category", title: "Create an absence category",
                       description: "Add a custom absence category.",
                       properties: ["name": Param.string("Name, at most 60 characters."), "rule": Param.rule,
                                    "color": Param.color, "icon": Param.icon],
                       required: ["name", "rule"], effect: .write),
        ToolDefinition(name: "update_absence_category", title: "Change an absence category",
                       description: "Rename, recolour, change the rule of, archive or restore a custom category. A new rule only applies to absences recorded afterwards.",
                       properties: ["category": Param.string("Custom category name or id."), "name": Param.string("New name."),
                                    "rule": Param.rule, "color": Param.color, "icon": Param.icon,
                                    "archived": Param.bool("Archive (hide from pickers, keep history) or restore.")],
                       required: ["category"], effect: .write),

        // Projects
        ToolDefinition(name: "create_project", title: "Create a project",
                       description: "Add a project. Names are unique, ignoring case.",
                       properties: ["name": Param.string("Name."), "color": Param.color],
                       required: ["name"], effect: .write),
        ToolDefinition(name: "update_project", title: "Change a project",
                       description: "Rename, recolour, archive or restore a project. Archived projects keep their entries but can't get new ones.",
                       properties: ["project": Param.project, "name": Param.string("New name."), "color": Param.color,
                                    "archived": Param.bool("Archive or restore.")],
                       required: ["project"], effect: .write),
        ToolDefinition(name: "delete_project", title: "Delete a project",
                       description: "Delete a project without time entries. Projects with entries can only be archived.",
                       properties: ["project": Param.project],
                       required: ["project"], effect: .delete),

        // Timer
        ToolDefinition(name: "start_timer", title: "Start the timer",
                       description: "Start the timer for a project; a running timer is stopped and saved first. The timer runs on this Mac; the entries it saves sync.",
                       properties: ["project": Param.string("Project name or id; the last-used project by default."),
                                    "at": Param.string("Start time if not now: HH:MM today or YYYY-MM-DD HH:MM.")],
                       effect: .write),
        ToolDefinition(name: "stop_timer", title: "Stop the timer",
                       description: "Stop the timer and save the time as entries (split at midnight and around existing entries).",
                       properties: ["at": Param.string("Stop time if not now: HH:MM today or YYYY-MM-DD HH:MM.")],
                       effect: .write),
        ToolDefinition(name: "discard_timer", title: "Discard the timer",
                       description: "Stop the timer without saving anything.",
                       effect: .delete),

        // Calls
        ToolDefinition(name: "list_calls", title: "List calls",
                       description: "Logged calls in a date range, oldest first: id, date, time, caller, topic, department, length (short < 15 min, medium < 1 h, long > 1 h; calls aren't timed more exactly), solved_by (me = the user, or caller) and note. Calls don't count as working time.",
                       properties: ["from": Param.day("First day."), "to": Param.day("Last day (inclusive); defaults to 'from'."),
                                    "caller": Param.string("Only this caller."), "topic": Param.string("Only this topic."),
                                    "department": Param.string("Only this department."),
                                    "limit": Param.number("Most calls to return; 300 by default, at most 2000.")],
                       required: ["from"], effect: .read),
        ToolDefinition(name: "get_call_summary", title: "Call summary",
                       description: "Calls in a date range counted per length, per caller, per topic and per department, with how many the user solved. Also lists the departments calls can be logged for.",
                       properties: ["from": Param.day("First day."), "to": Param.day("Last day (inclusive); defaults to 'from'.")],
                       required: ["from"], effect: .read),
        ToolDefinition(name: "log_call", title: "Log a call",
                       description: "Log a call the user had. Caller and topic names are matched to earlier calls ignoring case.",
                       properties: ["caller": Param.string("Who called."), "topic": Param.string("What about; optional."),
                                    "department": Param.department, "length": Param.callLength,
                                    "solved_by_me": Param.bool("True when the user solved the issue, false when the caller did; false by default."),
                                    "note": Param.string("Optional note."),
                                    "at": Param.string("When: HH:MM today or YYYY-MM-DD HH:MM; now by default.")],
                       required: ["caller", "length"], effect: .write),
        ToolDefinition(name: "update_call", title: "Change a call",
                       description: "Change a call's caller, topic, department, length, who solved it, note or time.",
                       properties: ["id": Param.string("Call id from list_calls."), "caller": Param.string("New caller."),
                                    "topic": Param.string("New topic; empty to remove it."), "department": Param.department,
                                    "length": Param.callLength, "solved_by_me": Param.bool("Whether the user solved the issue."),
                                    "note": Param.string("New note; empty to remove it."),
                                    "at": Param.string("New time: HH:MM on the call's day or YYYY-MM-DD HH:MM.")],
                       required: ["id"], effect: .write),
        ToolDefinition(name: "delete_calls", title: "Delete calls",
                       description: "Delete calls by id. All ids must exist, or nothing is deleted.",
                       properties: ["ids": ["type": "array", "items": ["type": "string"], "minItems": 1,
                                            "description": "Call ids from list_calls."]],
                       required: ["ids"], effect: .delete),

        // Settings
        ToolDefinition(name: "update_settings", title: "Change settings",
                       description: "Change the tracking start, opening balance or vacation settings. They sync to the other Macs and change balances.",
                       properties: ["tracking_start": Param.day("First tracked day; nothing is expected before it."),
                                    "opening_balance_hours": Param.number("Overtime (+) or undertime (−) from before the tracking start, in hours."),
                                    "vacation_entitlement_days": Param.number("Vacation days per year."),
                                    "carry_over_vacation": Param.bool("Carry unused vacation into the next year."),
                                    "opening_vacation_carry_over_days": Param.number("Vacation days carried into the first tracked year."),
                                    "full_time_weekly_hours": Param.number("Hours of a full-time week (for the workload percentage).")],
                       effect: .write),
        ToolDefinition(name: "set_schedule", title: "Set the work schedule",
                       description: "Set the contract hours per weekday from a day on (a schedule change, e.g. 80% from January), or for the initial schedule. Earlier days keep their schedule.",
                       properties: ["effective_from": Param.string("First day the hours apply (YYYY-MM-DD), or 'initial' for the first schedule."),
                                    "hours": Param.weekHours],
                       required: ["effective_from", "hours"], effect: .write),
        ToolDefinition(name: "remove_schedule_change", title: "Remove a schedule change",
                       description: "Remove a schedule change, so the schedule before it applies again.",
                       properties: ["effective_from": Param.day("The change's first day.")],
                       required: ["effective_from"], effect: .delete),
    ]

    static func definition(named name: String) -> ToolDefinition? {
        definitions.first { $0.name == name }
    }

    /// Run a tool. Returns a JSON-encodable value (dictionaries, arrays, strings, numbers).
    func call(_ name: String, _ arguments: ToolArguments) throws -> Any {
        switch name {
        case "get_overview": return try overview()
        case "get_summary": return try summary(arguments)
        case "list_entries": return try listEntries(arguments)
        case "list_projects": return try listProjects(arguments)
        case "list_absences": return try listAbsences(arguments)
        case "list_absence_categories": return try listCategories()
        case "get_vacation": return try vacation(arguments)
        case "list_days_without_entries": return try daysWithoutEntries(arguments)
        case "list_holidays": return try holidays(arguments)
        case "get_settings": return settings()
        case "add_entries": return try addEntries(arguments)
        case "update_entry": return try updateEntry(arguments)
        case "delete_entries": return try deleteEntries(arguments)
        case "copy_entries": return try copyEntries(arguments)
        case "set_absences": return try setAbsences(arguments)
        case "remove_absences": return try removeAbsences(arguments)
        case "create_absence_category": return try createCategory(arguments)
        case "update_absence_category": return try updateCategory(arguments)
        case "create_project": return try createProject(arguments)
        case "update_project": return try updateProject(arguments)
        case "delete_project": return try deleteProject(arguments)
        case "start_timer": return try startTimer(arguments)
        case "stop_timer": return try stopTimer(arguments)
        case "discard_timer": return try discardTimer()
        case "list_calls": return try listCalls(arguments)
        case "get_call_summary": return try callSummary(arguments)
        case "log_call": return try logCall(arguments)
        case "update_call": return try updateCall(arguments)
        case "delete_calls": return try deleteCalls(arguments)
        case "update_settings": return try updateSettings(arguments)
        case "set_schedule": return try setSchedule(arguments)
        case "remove_schedule_change": return try removeScheduleChange(arguments)
        default: throw ToolError("There's no tool called \(name).")
        }
    }

    // MARK: - Reading

    private func overview() throws -> [String: Any] {
        let now = self.now(), today = now.startOfDayZurich
        let calculator = makeCalculator(try allAbsences())
        let hours = WorkSegment.hoursByDay(try context.fetch(FetchDescriptor<WorkSegment>()))
        let start = preferences.trackingStartDate
        let numbers = OverviewNumbers(calculator: calculator, hours: hours, year: today.zurichYear,
                                      trackingStart: start, now: now)
        let missing = calculator.missingEntryDays(from: start, to: today.addingDays(-1), hours: hours)
        var result: [String: Any] = [
            "now": ToolFormat.moment(now),
            "weekday": ToolFormat.weekday(today),
            "time_zone": "Europe/Zurich",
            "tracking_start": ToolFormat.day(start),
            "today": totals(numbers.today),
            "this_week": totals(numbers.week),
            "this_month": totals(numbers.month),
            "this_year_to_date": totals(numbers.toDate),
            "this_year_expected_in_total": ToolFormat.hours(numbers.fullYear.expectedHours),
            "all_time_balance": ToolFormat.hours(numbers.allTime.balance + preferences.openingBalanceHours),
            "opening_balance": ToolFormat.hours(preferences.openingBalanceHours),
            "vacation": budget(numbers.budget, year: today.zurichYear),
            "days_without_entries": ["count": missing.count, "most_recent": missing.prefix(10).map(ToolFormat.day)] as [String: Any],
            "timer": timerState(),
        ]
        if let deviceSync {
            var sync: [String: Any] = ["enabled": deviceSync.isEnabled]
            if let date = deviceSync.lastSync { sync["last_sync"] = ToolFormat.moment(date) }
            if let question = deviceSync.question { sync["paused_until_answered_in_app"] = question.title }
            if let error = deviceSync.errorMessage { sync["error"] = error }
            result["sync"] = sync
        }
        return result
    }

    private func summary(_ arguments: ToolArguments) throws -> [String: Any] {
        let (from, to) = try range(arguments, maxDays: 3700)
        let breakdown = try arguments.optionalString("breakdown")?.lowercased() ?? "none"
        guard ["none", "day", "week", "month"].contains(breakdown) else {
            throw ToolError("'breakdown' must be none, day, week or month.")
        }
        let trackingStart = preferences.trackingStartDate
        let start = max(from, trackingStart)
        guard start <= to else {
            return ["from": ToolFormat.day(from), "to": ToolFormat.day(to),
                    "note": "Tracking starts on \(ToolFormat.day(trackingStart)); nothing is counted before it."]
        }
        let segments = try fetchSegments(from: start, through: to)
        let calculator = makeCalculator(try allAbsences())
        let hours = WorkSegment.hoursByDay(segments)
        let summary = calculator.periodSummary(from: start, to: to, hours: hours)

        var result = totals(summary)
        result["from"] = ToolFormat.day(start)
        result["to"] = ToolFormat.day(to)
        if start > from { result["note"] = "Starts at the tracking start; nothing is counted before it." }
        result["working_days"] = summary.workingDays
        result["public_holidays"] = summary.holidayDays
        result["half_day_holidays"] = summary.halfDayHolidays
        result["absence_days"] = summary.categoryTotals.map { total -> [String: Any] in
            var row = categoryReference(total.category)
            row["days"] = ToolFormat.hours(total.days)
            return row
        }
        result["projects"] = WorkHoursCalculator.projectBreakdown(from: start, to: to, segments: segments).map {
            ["project": $0.project.name, "hours": ToolFormat.hours($0.hours)] as [String: Any]
        }

        switch breakdown {
        case "day":
            let today = now().startOfDayZurich
            result["days"] = start.daysThrough(to).compactMap { day -> [String: Any]? in
                let info = calculator.classify(date: day)
                let worked = hours[day] ?? 0
                guard info.expectedHours > 0 || worked > 0 || info.holiday != nil || info.absence != nil else { return nil }
                var row = totals(expected: info.expectedHours, worked: worked)
                row["date"] = ToolFormat.day(day)
                row["weekday"] = ToolFormat.weekday(day)
                if let holiday = info.holiday, info.scheduledHours > 0 {
                    row["holiday"] = holiday.type == .halfDay ? "\(holiday.name) (half day)" : holiday.name
                }
                if let absence = info.absence {
                    var details = categoryReference(absence.category)
                    details["days"] = ToolFormat.hours(info.absenceDays)
                    if info.isOverAllowance { details["over_vacation_allowance"] = true }
                    row["absence"] = details
                }
                if day < today && calculator.isMissingEntries(info, hours: worked) { row["missing_entries"] = true }
                return row
            }
        case "week":
            result["weeks"] = chunks(from: start, to: to, startOf: \.startOfWeekZurich).map { chunk in
                var row = totals(calculator.periodSummary(from: chunk.from, to: chunk.to, hours: hours))
                row["week_of"] = ToolFormat.day(chunk.from.startOfWeekZurich)
                row["from"] = ToolFormat.day(chunk.from)
                row["to"] = ToolFormat.day(chunk.to)
                return row
            }
        case "month":
            result["months"] = chunks(from: start, to: to, startOf: \.startOfMonthZurich).map { chunk in
                var row = totals(calculator.periodSummary(from: chunk.from, to: chunk.to, hours: hours))
                row["month"] = String(ToolFormat.day(chunk.from).prefix(7))
                row["from"] = ToolFormat.day(chunk.from)
                row["to"] = ToolFormat.day(chunk.to)
                return row
            }
        default:
            break
        }
        return result
    }

    private func listEntries(_ arguments: ToolArguments) throws -> [String: Any] {
        let (from, to) = try range(arguments, maxDays: 3700)
        let limitValue = try arguments.number("limit") ?? 300
        guard (1...2000).contains(limitValue) else { throw ToolError("'limit' must be between 1 and 2000.") }
        let limit = Int(limitValue)
        var entries = try fetchSegments(from: from, through: to)
        if let reference = try arguments.optionalString("project") {
            let project = try findProject(reference)
            entries = entries.filter { $0.project?.persistentModelID == project.persistentModelID }
        }
        var result: [String: Any] = [
            "from": ToolFormat.day(from), "to": ToolFormat.day(to),
            "count": entries.count,
            "total_hours": ToolFormat.hours(entries.reduce(0) { $0 + $1.durationHours }),
            "entries": entries.prefix(limit).map(entryInfo),
        ]
        if entries.count > limit {
            result["note"] = "Only the first \(limit) of \(entries.count) entries are listed; narrow the range or raise 'limit'."
        }
        return result
    }

    private func listProjects(_ arguments: ToolArguments) throws -> [String: Any] {
        let includeArchived = try arguments.bool("include_archived") ?? false
        let projects = try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)]))
        return ["projects": projects.filter { includeArchived || !$0.isArchived }.map(projectInfo)]
    }

    private func listAbsences(_ arguments: ToolArguments) throws -> [String: Any] {
        let (from, to) = try range(arguments, maxDays: 3700)
        let calculator = makeCalculator(try allAbsences())
        let absences = try fetchAbsences(from: from, through: to)
        return ["absences": absences.map { absence -> [String: Any] in
            let info = calculator.classify(date: absence.date)
            var row = categoryReference(absence.entry.category)
            row["date"] = ToolFormat.day(absence.date)
            row["weekday"] = ToolFormat.weekday(absence.date)
            row["half_day"] = absence.isHalfDay
            row["counted_days"] = ToolFormat.hours(info.absenceDays)
            if info.isOverAllowance { row["over_vacation_allowance"] = true }
            return row
        }]
    }

    private func listCategories() throws -> [String: Any] {
        let builtIn = AbsenceType.builtIns.map { type -> [String: Any] in
            var row = categoryReference(type.details)
            row["rule"] = ruleName(type.details.rule)
            row["built_in"] = true
            return row
        }
        let custom = try context.fetch(FetchDescriptor<AbsenceCategory>(sortBy: [SortDescriptor(\.name)])).map(categoryInfo)
        return ["categories": builtIn + custom]
    }

    private func vacation(_ arguments: ToolArguments) throws -> [String: Any] {
        let year = try parseYear(arguments)
        let all = try allAbsences()
        let calculator = makeCalculator(all)
        var result = budget(calculator.vacationBudget(year: year), year: year)
        result["days"] = all.filter { $0.date.zurichYear == year && $0.entry.category.rule == .vacation }.compactMap { absence -> [String: Any]? in
            let info = calculator.classify(date: absence.date)
            guard info.absenceDays > 0 else { return nil }
            var row = categoryReference(absence.entry.category)
            row["date"] = ToolFormat.day(absence.date)
            row["days"] = ToolFormat.hours(info.absenceDays)
            if info.isOverAllowance { row["over_allowance"] = true }
            return row
        }
        return result
    }

    private func daysWithoutEntries(_ arguments: ToolArguments) throws -> [String: Any] {
        let today = now().startOfDayZurich
        let from = max(try arguments.optionalString("from").map(parseDay) ?? .distantPast, preferences.trackingStartDate)
        let to = min(try arguments.optionalString("to").map(parseDay) ?? today, today.addingDays(-1))
        guard from <= to else { return ["count": 0, "days": []] }
        let calculator = makeCalculator(try allAbsences())
        let hours = WorkSegment.hoursByDay(try fetchSegments(from: from, through: to))
        let days = calculator.missingEntryDays(from: from, to: to, hours: hours)
        return ["count": days.count, "days": days.map { day -> [String: Any] in
            ["date": ToolFormat.day(day), "weekday": ToolFormat.weekday(day),
             "expected": ToolFormat.hours(calculator.classify(date: day).expectedHours)]
        }]
    }

    private func holidays(_ arguments: ToolArguments) throws -> [String: Any] {
        let year = try parseYear(arguments)
        let schedule = preferences.schedule
        return ["year": year, "holidays": ZurichHolidays.holidays(for: year).sorted { $0.date < $1.date }.map { holiday -> [String: Any] in
            ["date": ToolFormat.day(holiday.date), "weekday": ToolFormat.weekday(holiday.date), "name": holiday.name,
             "half_day": holiday.type == .halfDay, "on_a_working_day": schedule.hours(on: holiday.date) > 0]
        }]
    }

    private func settings() -> [String: Any] {
        let periods = preferences.schedule.periods
        return [
            "schedule": periods.enumerated().map { index, period -> [String: Any] in
                [
                    "effective_from": index == 0 ? "initial" : ToolFormat.day(period.effectiveFrom),
                    "hours": period.hours.map(ToolFormat.hours),
                    "weekly_hours": ToolFormat.hours(period.weeklyHours),
                    "workload_percent": ToolFormat.hours(period.workload(fullTimeWeeklyHours: preferences.fullTimeWeeklyHours) * 100),
                ]
            },
            "schedule_hours_are": "Monday … Sunday",
            "full_time_weekly_hours": ToolFormat.hours(preferences.fullTimeWeeklyHours),
            "tracking_start": ToolFormat.day(preferences.trackingStartDate),
            "opening_balance_hours": ToolFormat.hours(preferences.openingBalanceHours),
            "vacation_entitlement_days": ToolFormat.hours(preferences.vacationEntitlement),
            "carry_over_vacation": preferences.carryOverVacation,
            "opening_vacation_carry_over_days": ToolFormat.hours(preferences.openingVacationCarryOver),
            "public_holidays": "Zurich",
        ]
    }

    // MARK: - Time entries

    private struct PlannedEntry {
        let day: Date
        let start: Date
        let end: Date
        let project: Project
        let note: String
    }

    private func addEntries(_ arguments: ToolArguments) throws -> [String: Any] {
        guard let items = try arguments.list("entries"), !items.isEmpty else {
            throw ToolError("Pass at least one entry in 'entries'.")
        }
        guard items.count <= 200 else { throw ToolError("Add at most 200 entries at a time.") }
        var planned: [PlannedEntry] = []
        for (index, item) in items.enumerated() {
            do {
                guard let fields = item as? [String: Any] else { throw ToolError("Each entry must be an object.") }
                let entry = ToolArguments(fields)
                let day = try parseDay(entry.string("date"))
                let start = try ToolFormat.parseTime(entry.string("start"), on: day, isEnd: false)
                let end = try ToolFormat.parseTime(entry.string("end"), on: day, isEnd: true)
                let project = try activeProject(entry.string("project"))
                if let problem = EntryActions.problem(start: start, end: end, on: day,
                                                      others: EntryActions.segments(on: day, in: context)) {
                    throw ToolError(problem)
                }
                if let other = planned.firstIndex(where: { $0.day == day && start < $0.end && end > $0.start }) {
                    throw ToolError("It overlaps entry \(other + 1) of this call.")
                }
                planned.append(PlannedEntry(day: day, start: start, end: end, project: project,
                                            note: try entry.optionalString("note") ?? ""))
            } catch let error as ToolError {
                throw ToolError(items.count > 1 ? "Entry \(index + 1): \(error.message) Nothing was saved." : error.message)
            }
        }
        var added: [WorkSegment] = []
        try save {
            for entry in planned {
                let segment = WorkSegment(date: entry.day, startTime: entry.start, endTime: entry.end,
                                          project: entry.project, note: entry.note)
                context.insert(segment)
                added.append(segment)
            }
        }
        return ["added": added.map(entryInfo), "total_hours": ToolFormat.hours(added.reduce(0) { $0 + $1.durationHours })]
    }

    private func updateEntry(_ arguments: ToolArguments) throws -> [String: Any] {
        let segment = try findEntry(arguments.string("id"))
        let oldDay = segment.date.startOfDayZurich
        let day = try arguments.optionalString("date").map(parseDay) ?? oldDay
        var start = EntryActions.moved(segment.startTime, from: oldDay, to: day)
        var end = EntryActions.moved(segment.endTime, from: oldDay, to: day)
        if let text = try arguments.optionalString("start") { start = try ToolFormat.parseTime(text, on: day, isEnd: false) }
        if let text = try arguments.optionalString("end") { end = try ToolFormat.parseTime(text, on: day, isEnd: true) }
        var project = segment.project
        if let reference = try arguments.optionalString("project") {
            let match = try findProject(reference)
            guard !match.isArchived || match.persistentModelID == segment.project?.persistentModelID else {
                throw ToolError("'\(match.name)' is archived. Restore it with update_project first.")
            }
            project = match
        }
        guard let project else { throw ToolError("This entry has no project; pass 'project'.") }
        let note = try arguments.optionalString("note") ?? segment.note
        let others = EntryActions.segments(on: day, in: context).filter { $0.persistentModelID != segment.persistentModelID }
        if let problem = EntryActions.problem(start: start, end: end, on: day, others: others) { throw ToolError(problem) }

        let before = entryInfo(segment)
        try save {
            segment.date = day
            segment.startTime = start
            segment.endTime = end
            segment.project = project
            segment.note = note
            segment.recalculateDuration()
        }
        return ["before": before, "after": entryInfo(segment)]
    }

    private func deleteEntries(_ arguments: ToolArguments) throws -> [String: Any] {
        guard let ids = try arguments.list("ids"), !ids.isEmpty else { throw ToolError("Pass the entry ids in 'ids'.") }
        guard let ids = ids as? [String] else { throw ToolError("'ids' must list entry ids (strings).") }
        var found: [WorkSegment] = [], missing: [String] = []
        for id in ids {
            if let segment = try? findEntry(id) {
                if !found.contains(where: { $0.persistentModelID == segment.persistentModelID }) { found.append(segment) }
            } else {
                missing.append(id)
            }
        }
        guard missing.isEmpty else {
            throw ToolError("No entry with id \(missing.joined(separator: ", ")). Nothing was deleted.")
        }
        let deleted = found.map(entryInfo)
        try save { found.forEach(context.delete) }
        return ["deleted": deleted]
    }

    private func copyEntries(_ arguments: ToolArguments) throws -> [String: Any] {
        let source = try parseDay(arguments.string("from_date"))
        let target = try parseDay(arguments.string("to_date"))
        guard source != target else { throw ToolError("'from_date' and 'to_date' are the same day.") }
        guard !EntryActions.segments(on: source, in: context).isEmpty else {
            throw ToolError("\(ToolFormat.day(source)) has no entries.")
        }
        var result = (copied: 0, skipped: 0)
        try save { result = EntryActions.copyEntries(from: source, to: target, in: context) }
        return ["copied": result.copied, "skipped_because_of_overlaps": result.skipped,
                "entries_on_to_date": EntryActions.segments(on: target, in: context).map(entryInfo)]
    }

    // MARK: - Absences

    private func setAbsences(_ arguments: ToolArguments) throws -> [String: Any] {
        let (from, to) = try range(arguments, maxDays: 400)
        let selection = try absenceSelection(arguments.string("category"))
        let halfDay = try arguments.bool("half_day") ?? false
        let calculator = makeCalculator(try allAbsences())
        let existing = Dictionary(try fetchAbsences(from: from, through: to).map { ($0.date.startOfDayZurich, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var days: [Date] = [], skipped: [[String: Any]] = []
        for day in from.daysThrough(to) {
            if calculator.isAbsenceEligible(day) {
                days.append(day)
            } else if let holiday = HolidayCalendar.shared.holiday(on: day), preferences.schedule.hours(on: day) > 0 {
                skipped.append(["date": ToolFormat.day(day), "reason": "public holiday (\(holiday.name))"])
            } else if from != to || existing[day] != nil {
                skipped.append(["date": ToolFormat.day(day), "reason": "no scheduled hours"])
            }
        }
        guard !days.isEmpty else {
            throw ToolError("No working day between \(ToolFormat.day(from)) and \(ToolFormat.day(to)): absences only go on days with scheduled hours that aren't public holidays.")
        }
        try save {
            for day in days {
                if let absence = existing[day] {
                    if absence.selectionID != selection.id { absence.assign(selection) }
                    absence.isHalfDay = halfDay
                } else {
                    let absence = VacationDay(date: day, isHalfDay: halfDay)
                    absence.assign(selection)
                    context.insert(absence)
                }
            }
        }
        var result = categoryReference(selection.details)
        result["days"] = days.map(ToolFormat.day)
        result["half_day"] = halfDay
        if skipped.count > 0 { result["skipped"] = skipped }
        if selection.details.rule == .vacation {
            let after = makeCalculator(try allAbsences())
            result["vacation"] = Set(days.map(\.zurichYear)).sorted().map { budget(after.vacationBudget(year: $0), year: $0) }
        }
        return result
    }

    private func removeAbsences(_ arguments: ToolArguments) throws -> [String: Any] {
        let (from, to) = try range(arguments, maxDays: 400)
        let absences = try fetchAbsences(from: from, through: to)
        guard !absences.isEmpty else { throw ToolError("No absences between \(ToolFormat.day(from)) and \(ToolFormat.day(to)).") }
        let removed = absences.map { absence -> [String: Any] in
            var row = categoryReference(absence.entry.category)
            row["date"] = ToolFormat.day(absence.date)
            row["half_day"] = absence.isHalfDay
            return row
        }
        try save { absences.forEach(context.delete) }
        return ["removed": removed]
    }

    private func createCategory(_ arguments: ToolArguments) throws -> [String: Any] {
        let name = try arguments.string("name")
        try validateCategoryName(name, excluding: nil)
        let rule = try parseRule(arguments.string("rule"))
        let color = try arguments.optionalString("color").map(parseColor) ?? .purple
        let icon = try arguments.optionalString("icon").map(parseIcon) ?? "calendar.badge.clock"
        let category = AbsenceCategory(name: name, icon: icon, color: color, rule: rule)
        try save { context.insert(category) }
        return categoryInfo(category)
    }

    private func updateCategory(_ arguments: ToolArguments) throws -> [String: Any] {
        let selection = try absenceSelection(arguments.string("category"), allowArchived: true)
        guard case .custom(let category) = selection else {
            throw ToolError("\(selection.details.name) is built in and can't be changed.")
        }
        let name = try arguments.optionalString("name")
        if let name { try validateCategoryName(name, excluding: category) }
        let rule = try arguments.optionalString("rule").map(parseRule)
        let color = try arguments.optionalString("color").map(parseColor)
        let icon = try arguments.optionalString("icon").map(parseIcon)
        let archived = try arguments.bool("archived")
        try save {
            if let name { category.name = name }
            if let rule { category.ruleRaw = rule.rawValue }
            if let color { category.colorRaw = color.rawValue }
            if let icon { category.icon = icon }
            if let archived { category.isArchived = archived }
        }
        var result = categoryInfo(category)
        if rule != nil { result["note"] = "The rule applies to absences recorded from now on; existing ones keep theirs." }
        return result
    }

    // MARK: - Projects

    private func createProject(_ arguments: ToolArguments) throws -> [String: Any] {
        let name = try arguments.string("name")
        let projects = try context.fetch(FetchDescriptor<Project>())
        try validateProjectName(name, in: projects, excluding: nil)
        let color = try arguments.optionalString("color").map(parseColor) ?? Project.suggestedColor(existing: projects)
        let project = Project(name: name, color: color)
        try save { context.insert(project) }
        return projectInfo(project)
    }

    private func updateProject(_ arguments: ToolArguments) throws -> [String: Any] {
        let project = try findProject(arguments.string("project"))
        let name = try arguments.optionalString("name")
        if let name { try validateProjectName(name, in: try context.fetch(FetchDescriptor<Project>()), excluding: project) }
        let color = try arguments.optionalString("color").map(parseColor)
        let archived = try arguments.bool("archived")
        try save {
            if let name { project.name = name }
            if let color { project.color = color }
            if let archived { project.isArchived = archived }
        }
        return projectInfo(project)
    }

    private func deleteProject(_ arguments: ToolArguments) throws -> [String: Any] {
        let project = try findProject(arguments.string("project"))
        if timer.isRunning && timer.projectID == project.persistentModelID {
            throw ToolError("The timer is running for '\(project.name)'. Stop it first.")
        }
        guard project.segments.isEmpty else {
            throw ToolError("'\(project.name)' has \(project.segments.count) time entries. Delete or move them first, or archive the project.")
        }
        let name = project.name
        try save { context.delete(project) }
        return ["deleted": name]
    }

    // MARK: - Timer

    private func startTimer(_ arguments: ToolArguments) throws -> [String: Any] {
        let project: Project
        if let reference = try arguments.optionalString("project") {
            project = try activeProject(reference)
        } else if let last = EntryActions.lastUsedProject(in: context) {
            project = last
        } else {
            throw ToolError("Pass 'project'; there's no last-used project yet.")
        }
        let now = self.now()
        let at = try arguments.optionalString("at").map { try ToolFormat.parseMoment($0, now: now) } ?? now
        guard at <= now.addingTimeInterval(60) else { throw ToolError("The timer can't start in the future.") }
        if let running = timer.startedAt, at < running {
            throw ToolError("The running timer started at \(ToolFormat.moment(running)); start the new one after that.")
        }
        var message = ""
        try save {
            // The timer remembers the project by its ID, which changes when a new project is
            // first saved.
            try context.save()
            message = TimerActions.start(project, at: at, timer: timer, context: context)
        }
        return ["message": message, "timer": timerState()]
    }

    private func stopTimer(_ arguments: ToolArguments) throws -> [String: Any] {
        guard let started = timer.startedAt else { throw ToolError("No timer is running.") }
        let now = self.now()
        let at = try arguments.optionalString("at").map { try ToolFormat.parseMoment($0, now: now) } ?? now
        guard at <= now.addingTimeInterval(60) else { throw ToolError("The timer can't stop in the future.") }
        guard at >= started else { throw ToolError("The timer started at \(ToolFormat.moment(started)); stop it after that.") }
        var saved: [WorkSegment] = []
        try save { saved = timer.stop(context: context, at: at) }
        var result: [String: Any] = ["saved": saved.map(entryInfo)]
        if saved.isEmpty {
            result["note"] = "Nothing was saved: under a minute, or the time was already covered by entries."
        }
        return result
    }

    private func discardTimer() throws -> [String: Any] {
        guard let started = timer.startedAt else { throw ToolError("No timer is running.") }
        let name = timer.project(in: context)?.name
        timer.discard()
        return ["discarded": ["project": nullable(name), "started": ToolFormat.moment(started)] as [String: Any]]
    }

    // MARK: - Calls

    private func listCalls(_ arguments: ToolArguments) throws -> [String: Any] {
        let (from, to) = try range(arguments, maxDays: 3700)
        let limitValue = try arguments.number("limit") ?? 300
        guard (1...2000).contains(limitValue) else { throw ToolError("'limit' must be between 1 and 2000.") }
        let limit = Int(limitValue)
        var calls = try context.fetch(PhoneCall.descriptor(from: from, through: to))
        for (key, field) in [("caller", \PhoneCall.caller), ("topic", \PhoneCall.topic), ("department", \PhoneCall.department)] {
            if let value = try arguments.optionalString(key) {
                calls = calls.filter { CallNames.same($0[keyPath: field], value) }
            }
        }
        var result: [String: Any] = [
            "from": ToolFormat.day(from), "to": ToolFormat.day(to),
            "count": calls.count,
            "calls": calls.prefix(limit).map(callInfo),
        ]
        if calls.count > limit {
            result["note"] = "Only the first \(limit) of \(calls.count) calls are listed; narrow the range or raise 'limit'."
        }
        return result
    }

    private func callSummary(_ arguments: ToolArguments) throws -> [String: Any] {
        let (from, to) = try range(arguments, maxDays: 3700)
        let calls = try context.fetch(PhoneCall.descriptor(from: from, through: to))
        func rows(_ groups: [CallGroup], _ key: String) -> [[String: Any]] {
            groups.map { group in
                var row = groupInfo(group)
                row[key] = group.name.isEmpty ? NSNull() : group.name
                return row
            }
        }
        var result = groupInfo(CallReport.total(calls))
        result["from"] = ToolFormat.day(from)
        result["to"] = ToolFormat.day(to)
        result["lengths"] = "short: under 15 minutes, medium: 15 minutes to 1 hour, long: over 1 hour"
        result["callers"] = rows(CallReport.byCaller(calls), "caller")
        result["topics"] = rows(CallReport.byTopic(calls), "topic")
        result["by_department"] = rows(CallReport.byDepartment(calls), "department")
        result["departments"] = preferences.callDepartments
        return result
    }

    private func logCall(_ arguments: ToolArguments) throws -> [String: Any] {
        let caller = try arguments.string("caller")
        guard !caller.isEmpty else { throw ToolError("'caller' can't be empty.") }
        let length = try parseCallLength(arguments.string("length"))
        let now = self.now()
        let at = try arguments.optionalString("at").map { try ToolFormat.parseMoment($0, now: now) } ?? now
        guard at <= now.addingTimeInterval(60) else { throw ToolError("A call can't be logged in the future.") }
        let department = try arguments.optionalString("department").map(parseDepartment) ?? ""
        var call: PhoneCall?
        try save {
            call = CallLog.add(caller: caller, topic: try arguments.optionalString("topic") ?? "", department: department,
                               note: try arguments.optionalString("note") ?? "", length: length,
                               solvedByMe: try arguments.bool("solved_by_me") ?? false, at: at, context: context)
        }
        return call.map(callInfo) ?? [:]
    }

    private func updateCall(_ arguments: ToolArguments) throws -> [String: Any] {
        let call = try findCall(arguments.string("id"))
        let others = try context.fetch(CallSuggestions.source).filter { $0.persistentModelID != call.persistentModelID }
        let caller = try arguments.optionalString("caller")
        if caller?.isEmpty == true { throw ToolError("'caller' can't be empty.") }
        let topic = try arguments.optionalString("topic")
        let department = try arguments.optionalString("department").map(parseDepartment)
        let length = try arguments.optionalString("length").map(parseCallLength)
        let solvedByMe = try arguments.bool("solved_by_me")
        let note = try arguments.optionalString("note")
        var date: Date?
        if let text = try arguments.optionalString("at") {
            date = text.count > 5 ? try ToolFormat.parseMoment(text, now: now())
                                  : try ToolFormat.parseTime(text, on: call.date.startOfDayZurich, isEnd: false)
        }
        let before = callInfo(call)
        try save {
            if let caller { call.caller = CallNames.canonical(caller, in: others.map(\.caller)) }
            if let topic { call.topic = CallNames.canonical(topic, in: others.map(\.topic)) }
            if let department { call.department = department }
            if let length { call.length = length }
            if let solvedByMe { call.solvedByMe = solvedByMe }
            if let note { call.note = note }
            if let date { call.date = date }
        }
        return ["before": before, "after": callInfo(call)]
    }

    private func deleteCalls(_ arguments: ToolArguments) throws -> [String: Any] {
        guard let ids = try arguments.list("ids"), !ids.isEmpty else { throw ToolError("Pass the call ids in 'ids'.") }
        guard let ids = ids as? [String] else { throw ToolError("'ids' must list call ids (strings).") }
        var found: [PhoneCall] = [], missing: [String] = []
        for id in ids {
            if let call = try? findCall(id) {
                if !found.contains(where: { $0.persistentModelID == call.persistentModelID }) { found.append(call) }
            } else {
                missing.append(id)
            }
        }
        guard missing.isEmpty else {
            throw ToolError("No call with id \(missing.joined(separator: ", ")). Nothing was deleted.")
        }
        let deleted = found.map(callInfo)
        try save { found.forEach(context.delete) }
        return ["deleted": deleted]
    }

    // MARK: - Settings

    private func updateSettings(_ arguments: ToolArguments) throws -> [String: Any] {
        let trackingStart = try arguments.optionalString("tracking_start").map(parseDay)
        let openingBalance: Double?
        if let text = arguments.values["opening_balance_hours"] as? String {
            guard let value = TimeFormatting.parseSignedHours(text) else {
                throw ToolError("'opening_balance_hours' must be hours like 12.5, -4.25 or +12:30.")
            }
            openingBalance = value
        } else {
            openingBalance = try arguments.number("opening_balance_hours")
        }
        if let openingBalance, abs(openingBalance) > 10_000 {
            throw ToolError("'opening_balance_hours' must be between -10000 and 10000.")
        }
        let entitlement = try parseDays(arguments, "vacation_entitlement_days")
        let carryOver = try arguments.bool("carry_over_vacation")
        let openingCarryOver = try parseDays(arguments, "opening_vacation_carry_over_days")
        let fullTimeWeek = try arguments.number("full_time_weekly_hours")
        if let fullTimeWeek, !(1...168).contains(fullTimeWeek) {
            throw ToolError("'full_time_weekly_hours' must be between 1 and 168.")
        }
        guard trackingStart != nil || openingBalance != nil || entitlement != nil || carryOver != nil
                || openingCarryOver != nil || fullTimeWeek != nil else {
            throw ToolError("Pass at least one setting to change.")
        }
        if let trackingStart { preferences.trackingStartDate = trackingStart }
        if let openingBalance { preferences.openingBalanceHours = openingBalance }
        if let entitlement { preferences.vacationEntitlement = entitlement }
        if let carryOver { preferences.carryOverVacation = carryOver }
        if let openingCarryOver { preferences.openingVacationCarryOver = openingCarryOver }
        if let fullTimeWeek { preferences.fullTimeWeeklyHours = fullTimeWeek }
        return settings()
    }

    private func setSchedule(_ arguments: ToolArguments) throws -> [String: Any] {
        let reference = try arguments.string("effective_from")
        guard let list = try arguments.list("hours"), list.count == 7 else {
            throw ToolError("'hours' must list 7 numbers, Monday … Sunday.")
        }
        let hours = try list.map { value -> Double in
            guard let number = value as? NSNumber, (0...24).contains(number.doubleValue) else {
                throw ToolError("Each day's hours must be a number from 0 to 24.")
            }
            return number.doubleValue
        }
        var schedule = preferences.schedule
        var period: WorkSchedule.Period
        if reference.lowercased() == "initial" {
            period = schedule.periods[0]
        } else {
            let from = try parseDay(reference)
            period = schedule.periods.first { $0.effectiveFrom == from } ?? WorkSchedule.Period(effectiveFrom: from, hours: [])
        }
        period.hours = hours
        schedule.upsert(period)
        preferences.schedule = schedule
        return settings()
    }

    private func removeScheduleChange(_ arguments: ToolArguments) throws -> [String: Any] {
        let from = try parseDay(arguments.string("effective_from"))
        let periods = preferences.schedule.periods
        guard let period = periods.dropFirst().first(where: { $0.effectiveFrom == from }) else {
            throw ToolError("There's no schedule change on \(ToolFormat.day(from)); the initial schedule can't be removed.")
        }
        preferences.schedule.remove(id: period.id)
        return settings()
    }

    // MARK: - Saving

    /// Make changes and save them. Like changes from other Macs, they aren't undoable in
    /// the app: undoing them there would be surprising, and older undo steps could
    /// clash with them, so the undo history is cleared.
    private func save(_ changes: () throws -> Void) throws {
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        do {
            try changes()
            try context.save()
        } catch {
            context.rollback()
            undoManager?.enableUndoRegistration()
            throw error
        }
        undoManager?.enableUndoRegistration()
        // Clearing re-enables registration, so only clear once it's enabled again.
        undoManager?.removeAllActions()
    }

    // MARK: - Lookups

    private func parseDay(_ text: String) throws -> Date {
        try ToolFormat.parseDay(text, today: now().startOfDayZurich)
    }

    /// `from` and `to` (default: `from`), at most `maxDays` apart.
    private func range(_ arguments: ToolArguments, maxDays: Int) throws -> (from: Date, to: Date) {
        let from = try parseDay(arguments.string("from"))
        let to = try arguments.optionalString("to").map(parseDay) ?? from
        guard from <= to else { throw ToolError("'to' is before 'from'.") }
        guard (Calendar.zurich.dateComponents([.day], from: from, to: to).day ?? 0) < maxDays else {
            throw ToolError("The range can span at most \(maxDays) days.")
        }
        return (from, to)
    }

    private func parseYear(_ arguments: ToolArguments) throws -> Int {
        guard let value = try arguments.number("year") else { return now().zurichYear }
        guard value == value.rounded(), (1900...2200).contains(value) else { throw ToolError("'year' must be a year like 2026.") }
        return Int(value)
    }

    private func parseDays(_ arguments: ToolArguments, _ key: String) throws -> Double? {
        guard let value = try arguments.number(key) else { return nil }
        guard (0...366).contains(value), (value * 2).rounded() == value * 2 else {
            throw ToolError("'\(key)' must be whole or half days from 0 to 366.")
        }
        return value
    }

    private func fetchSegments(from: Date, through to: Date) throws -> [WorkSegment] {
        let start = from.startOfDayZurich, end = to.startOfDayZurich.addingDays(1)
        return try context.fetch(FetchDescriptor<WorkSegment>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.startTime)]))
    }

    private func fetchAbsences(from: Date, through to: Date) throws -> [VacationDay] {
        let start = from.startOfDayZurich, end = to.startOfDayZurich.addingDays(1)
        return try context.fetch(FetchDescriptor<VacationDay>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]))
    }

    private func allAbsences() throws -> [VacationDay] {
        try context.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)]))
    }

    private func makeCalculator(_ absences: [VacationDay]) -> WorkHoursCalculator {
        preferences.calculator(absences: VacationDay.lookup(absences))
    }

    private func findEntry(_ id: String) throws -> WorkSegment {
        guard let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespaces)) else {
            throw ToolError("'\(id)' isn't an entry id; ids come from list_entries.")
        }
        let target: UUID? = uuid
        var descriptor = FetchDescriptor<WorkSegment>(predicate: #Predicate { $0.syncID == target })
        descriptor.fetchLimit = 1
        guard let segment = try context.fetch(descriptor).first else { throw ToolError("No entry with id \(id).") }
        return segment
    }

    private func findCall(_ id: String) throws -> PhoneCall {
        guard let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespaces)) else {
            throw ToolError("'\(id)' isn't a call id; ids come from list_calls.")
        }
        let target: UUID? = uuid
        var descriptor = FetchDescriptor<PhoneCall>(predicate: #Predicate { $0.syncID == target })
        descriptor.fetchLimit = 1
        guard let call = try context.fetch(descriptor).first else { throw ToolError("No call with id \(id).") }
        return call
    }

    private func parseCallLength(_ text: String) throws -> CallLength {
        guard let length = CallLength(rawValue: text.lowercased()) else {
            throw ToolError("'length' must be short (under 15 minutes), medium (15 minutes to 1 hour) or long (over 1 hour).")
        }
        return length
    }

    /// One of the departments in the settings, or empty for none.
    private func parseDepartment(_ text: String) throws -> String {
        guard !text.isEmpty else { return "" }
        let departments = preferences.callDepartments
        guard let match = departments.first(where: { same($0, text) }) else {
            throw ToolError("There's no department '\(text)'. Departments: \(departments.isEmpty ? "none yet (the user adds them in Settings ▸ Calls)" : departments.joined(separator: ", ")).")
        }
        return match
    }

    /// A project by id or name (ignoring case and diacritics), archived ones included.
    private func findProject(_ reference: String) throws -> Project {
        let projects = try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)]))
        if let uuid = UUID(uuidString: reference), let match = projects.first(where: { $0.syncID == uuid }) { return match }
        let matches = projects.filter { $0.name.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if let match = matches.first(where: { !$0.isArchived }) ?? matches.first { return match }
        let names = projects.filter { !$0.isArchived }.map(\.name)
        throw ToolError("There's no project called '\(reference)'. Projects: \(names.isEmpty ? "none yet" : names.joined(separator: ", ")).")
    }

    private func activeProject(_ reference: String) throws -> Project {
        let project = try findProject(reference)
        guard !project.isArchived else {
            throw ToolError("'\(project.name)' is archived. Restore it with update_project (archived: false) first.")
        }
        return project
    }

    private func validateProjectName(_ name: String, in projects: [Project], excluding: Project?) throws {
        guard !name.isEmpty else { throw ToolError("The name can't be empty.") }
        guard name.count <= 100 else { throw ToolError("The name can have at most 100 characters.") }
        if Project.isDuplicate(name: name, in: projects, excluding: excluding) {
            let archived = projects.contains { $0 !== excluding && $0.isArchived
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            throw ToolError("A project called '\(name)' already exists\(archived ? " (archived; restore it with update_project)" : "").")
        }
    }

    /// A built-in type by key or name (in any UI language), or a custom category by id or name.
    private func absenceSelection(_ reference: String, allowArchived: Bool = false) throws -> AbsenceSelection {
        let key = reference.lowercased().replacingOccurrences(of: " ", with: "_")
        let aliases: [String: AbsenceType] = ["public_service": .service, "unpaid_leave": .unpaid, "sick_leave": .sick, "holiday": .vacation]
        if let type = AbsenceType(rawValue: key) ?? aliases[key], type != .custom { return .builtIn(type) }
        if let type = AbsenceType.builtIns.first(where: { $0.allNames.contains { same($0, reference) } }) { return .builtIn(type) }
        let categories = try context.fetch(FetchDescriptor<AbsenceCategory>(sortBy: [SortDescriptor(\.name)]))
        let match = categories.first { $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame }
            ?? categories.first { same($0.name, reference) }
        guard let match else {
            let custom = categories.filter { !$0.isArchived }.map(\.name)
            throw ToolError("There's no absence category '\(reference)'. Use vacation, sick, service or unpaid\(custom.isEmpty ? "" : ", or one of: \(custom.joined(separator: ", "))").")
        }
        guard allowArchived || !match.isArchived else {
            throw ToolError("'\(match.name)' is archived. Restore it with update_absence_category (archived: false) first.")
        }
        return .custom(match)
    }

    private func validateCategoryName(_ name: String, excluding: AbsenceCategory?) throws {
        guard !name.isEmpty else { throw ToolError("The name can't be empty.") }
        guard name.count <= 60 else { throw ToolError("The name can have at most 60 characters.") }
        let categories = try context.fetch(FetchDescriptor<AbsenceCategory>())
        guard !AbsenceCategory.isDuplicate(name: name, in: categories, excluding: excluding) else {
            throw ToolError("A category called '\(name)' already exists.")
        }
    }

    private func nullable(_ text: String?) -> Any {
        if let text { return text }
        return NSNull()
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func parseColor(_ name: String) throws -> PaletteColor {
        guard let color = PaletteColor(rawValue: name.lowercased()) else {
            throw ToolError("'\(name)' isn't a colour. Use one of: \(PaletteColor.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return color
    }

    private func parseIcon(_ name: String) throws -> String {
        guard let icon = AbsenceCategory.iconChoices.first(where: { $0.symbol == name || same($0.name, name) }) else {
            throw ToolError("'\(name)' isn't an available icon. Use one of: \(AbsenceCategory.iconChoices.map(\.symbol).joined(separator: ", ")).")
        }
        return icon.symbol
    }

    private func parseRule(_ name: String) throws -> AbsenceCountingRule {
        switch name.lowercased() {
        case "reduce_hours", "holiday": return .reduceHours
        case "vacation_allowance", "vacation": return .vacation
        case "unchanged": return .unchanged
        default: throw ToolError("'rule' must be reduce_hours, vacation_allowance or unchanged.")
        }
    }

    private func ruleName(_ rule: AbsenceCountingRule) -> String {
        switch rule {
        case .reduceHours: return "reduce_hours"
        case .vacation: return "vacation_allowance"
        case .unchanged: return "unchanged"
        }
    }

    // MARK: - Output

    private func totals(_ summary: PeriodSummary) -> [String: Any] {
        totals(expected: summary.expectedHours, worked: summary.actualHours)
    }

    private func totals(expected: Double, worked: Double) -> [String: Any] {
        ["worked": ToolFormat.hours(worked), "expected": ToolFormat.hours(expected),
         "balance": ToolFormat.hours(worked - expected)]
    }

    private func budget(_ budget: VacationBudget, year: Int) -> [String: Any] {
        ["year": year, "entitlement_days": ToolFormat.hours(budget.entitlement),
         "carried_over_days": ToolFormat.hours(budget.carriedIn), "used_days": ToolFormat.hours(budget.used),
         "remaining_days": ToolFormat.hours(budget.remaining)]
    }

    private func entryInfo(_ segment: WorkSegment) -> [String: Any] {
        var info: [String: Any] = [
            "id": segment.syncID?.uuidString ?? "",
            "date": ToolFormat.day(segment.date),
            "start": TimeField.format(segment.startTime, on: segment.date),
            "end": TimeField.format(segment.endTime, on: segment.date),
            "hours": ToolFormat.hours(segment.durationHours),
            "project": nullable(segment.project?.name),
        ]
        if !segment.note.isEmpty { info["note"] = segment.note }
        return info
    }

    private func callInfo(_ call: PhoneCall) -> [String: Any] {
        var info: [String: Any] = [
            "id": call.syncID?.uuidString ?? "",
            "date": ToolFormat.day(call.date),
            "weekday": ToolFormat.weekday(call.date),
            "time": TimeField.format(call.date),
            "caller": call.caller,
            "topic": nullable(call.topic.isEmpty ? nil : call.topic),
            "department": nullable(call.department.isEmpty ? nil : call.department),
            "length": call.length.rawValue,
            "solved_by": call.solvedByMe ? "me" : "caller",
        ]
        if !call.note.isEmpty { info["note"] = call.note }
        return info
    }

    private func groupInfo(_ group: CallGroup) -> [String: Any] {
        var info: [String: Any] = ["calls": group.count, "solved_by_me": group.solvedByMe]
        for length in CallLength.allCases { info[length.rawValue] = group.count(length) }
        return info
    }

    private func projectInfo(_ project: Project) -> [String: Any] {
        let segments = project.segments
        var info: [String: Any] = [
            "id": project.syncID?.uuidString ?? "",
            "name": project.name,
            "color": project.color.rawValue,
            "archived": project.isArchived,
            "entries": segments.count,
            "total_hours": ToolFormat.hours(segments.reduce(0) { $0 + $1.durationHours }),
        ]
        if let last = segments.map(\.date).max() { info["last_worked"] = ToolFormat.day(last) }
        if timer.isRunning && timer.projectID == project.persistentModelID { info["timer_running"] = true }
        return info
    }

    /// How tools name a category: built-ins by key, custom ones by name (and id).
    private func categoryReference(_ details: CategoryDetails) -> [String: Any] {
        if let type = details.builtIn { return ["category": type.rawValue, "category_name": details.name] }
        return ["category": details.name, "category_id": details.id]
    }

    private func categoryInfo(_ category: AbsenceCategory) -> [String: Any] {
        ["category": category.name, "category_id": category.id.uuidString, "rule": ruleName(category.rule),
         "color": category.color.rawValue, "icon": category.icon, "archived": category.isArchived, "built_in": false]
    }

    private func timerState() -> [String: Any] {
        guard let started = timer.startedAt else { return ["running": false] }
        return ["running": true, "project": nullable(timer.project(in: context)?.name),
                "started": ToolFormat.moment(started),
                "elapsed_hours": ToolFormat.hours(max(0, now().timeIntervalSince(started)) / 3600)]
    }

    /// `from…to` cut where `startOf` changes (weeks, months).
    private func chunks(from: Date, to: Date, startOf: KeyPath<Date, Date>) -> [(from: Date, to: Date)] {
        var result: [(from: Date, to: Date)] = []
        for day in from.daysThrough(to) {
            if let last = result.last, last.to[keyPath: startOf] == day[keyPath: startOf] {
                result[result.count - 1].to = day
            } else {
                result.append((day, day))
            }
        }
        return result
    }
}

private extension Date {
    var startOfMonthZurich: Date {
        Calendar.zurich.date(from: Calendar.zurich.dateComponents([.year, .month], from: self))!
    }
}
