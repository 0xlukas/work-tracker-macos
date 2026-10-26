import Foundation

/// CSV reports: a day-by-day summary and a per-entry list.
struct CSVExporter {
    let format: CSVFormat

    private var separator: String { format == .standard ? "," : ";" }

    /// Excel only reads UTF-8 (umlauts) correctly with a byte-order mark.
    private var prefix: String { format == .excelGerman ? "\u{FEFF}" : "" }

    func number(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return format == .excelGerman ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// Quote a field when it contains the separator, a quote or a line break.
    func field(_ value: String) -> String {
        guard value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func line(_ fields: [String]) -> String {
        fields.map(field).joined(separator: separator)
    }

    private func isoDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .zurich).year().month().day())
    }

    private func weekday(_ date: Date) -> String {
        date.formatted(.app.weekday(.abbreviated))
    }

    static func absenceLabel(for day: DaySummary) -> String {
        guard let category = day.category else { return day.isWeekend ? tr("Weekend") : "" }
        var label = day.isHalfDayAbsence ? tr("%@ (half day)", category.name) : category.name
        if day.isOverAllowance { label += " " + tr("(over allowance)") }
        return label
    }

    static func holidayLabel(for day: DaySummary) -> String {
        guard let holiday = day.holiday else { return "" }
        return holiday.type == .halfDay ? tr("%@ (half day)", holiday.name) : holiday.name
    }

    /// One row per day with expected/worked/balance hours, plus a total row.
    func dailyReport(days: [DaySummary], hours: [Date: Double]) -> String {
        var rows = [line([tr("Date"), tr("Weekday"), tr("Expected hours"), tr("Worked hours"),
                          tr("Balance hours"), tr("Absence"), tr("Holiday")])]
        var expected = 0.0, worked = 0.0
        for day in days {
            let dayWorked = hours[day.date] ?? 0
            expected += day.expectedHours
            worked += dayWorked
            rows.append(line([isoDate(day.date), weekday(day.date), number(day.expectedHours), number(dayWorked),
                              number(dayWorked - day.expectedHours), Self.absenceLabel(for: day), Self.holidayLabel(for: day)]))
        }
        rows.append(line([tr("Total"), "", number(expected), number(worked), number(worked - expected), "", ""]))
        return prefix + rows.joined(separator: "\n") + "\n"
    }

    /// One row per time entry, in chronological order.
    func entries(_ segments: [WorkSegment]) -> String {
        var rows = [line([tr("Date"), tr("Weekday"), tr("Start"), tr("End"), tr("Hours"), tr("Project"), tr("Note")])]
        var total = 0.0
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            total += segment.durationHours
            rows.append(line([isoDate(segment.date), weekday(segment.date),
                              TimeField.format(segment.startTime, on: segment.date),
                              TimeField.format(segment.endTime, on: segment.date),
                              number(segment.durationHours), segment.project?.name ?? "", segment.note]))
        }
        rows.append(line([tr("Total"), "", "", "", number(total), "", ""]))
        return prefix + rows.joined(separator: "\n") + "\n"
    }
}
