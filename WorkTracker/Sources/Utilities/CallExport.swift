import Foundation

/// Calls for an AI to analyse, as Markdown to paste into a chat or upload: what the data
/// is and how to read it, exact summary tables the model would otherwise have to count (and
/// often miscounts), then every call as CSV, which its analysis tools can load.
enum CallExport {
    /// "Me" or "Caller".
    static func solver(_ call: PhoneCall) -> String {
        call.solvedByMe ? tr("Me") : tr("Caller")
    }

    /// `scope`: what the calls are, e.g. "October 2026" or "October 2026, Meier". `days`: the
    /// days they could be on, when they're one period's (so far), so rates per day or month
    /// count the quiet days too.
    static func markdown(_ calls: [PhoneCall], scope: String, days: ClosedRange<Date>? = nil) -> String {
        let calls = calls.sorted { $0.date < $1.date }
        let total = CallReport.total(calls)
        var lines = [
            "# " + tr("Call log: %@", scope),
            "",
            "## " + tr("About This Data"),
            "",
            "- " + tr("Each call was logged right after it by the person who was called (“me”): who called, what about, which department it concerned, how long it took and who solved the issue."),
            "- " + tr("Length is one of three blocks: under 15 minutes, 15 minutes to 1 hour, or over 1 hour. Calls weren’t timed more exactly."),
            "- " + tr("Estimated times count the blocks as 7.5, 37.5 and 75 minutes."),
            "- " + tr("“Solved by” is “Me” when the person called solved the issue and “Caller” when the caller did."),
            "- " + tr("Date and time are when the call was logged, usually right after it ended, so a long call started earlier. Calls logged later were given their time by hand."),
            "- " + tr("The summary tables are counted by the app and exact: use them for totals and rankings rather than recounting the call list. The call list at the end has every call, as CSV."),
            "",
            "## " + tr("Overview"),
            "",
        ]
        // The period's days, stretched to calls dated outside them (a month still to come
        // with a call already in it).
        let days = days.map { days in
            min(days.lowerBound, calls.first?.date.startOfDayZurich ?? days.lowerBound)
                ... max(days.upperBound, calls.last?.date.startOfDayZurich ?? days.upperBound)
        }
        if let days {
            lines.append("- " + tr("Period: %@ to %@", ToolFormat.day(days.lowerBound), ToolFormat.day(days.upperBound))
                         + " (" + tr("%lld days", dayCount(days.lowerBound, days.upperBound)) + ")")
        }
        if let first = calls.first?.date, let last = calls.last?.date {
            var line = "- " + tr("Calls from %@ to %@", ToolFormat.day(first), ToolFormat.day(last))
            if days == nil { line += " (" + tr("%lld days", dayCount(first, last)) + ")" }
            lines.append(line)
        }
        lines += [
            "- " + tr("Calls: %@", "\(total.count)") + " ("
                + CallLength.allCases.map { "\($0.detail): \(total.count($0))" }.joined(separator: ", ") + ")",
            "- " + tr("Estimated time on calls: %@", CallStats.formatEstimate(minutes: total.estimatedMinutes)),
            "- " + tr("Solved by me: %@ of %@", "\(total.solvedByMe)", "\(total.count)")
                + (total.solvedShare.map { " (\(percent($0)))" } ?? ""),
        ]
        guard !calls.isEmpty else { return lines.joined(separator: "\n") + "\n" }

        // Each caller's most common topic, grouped once (thousands of calls stay quick).
        let topTopics = Dictionary(grouping: calls) { CallNames.key($0.caller) }
            .mapValues { CallReport.byTopic($0).first { !$0.name.isEmpty }?.name ?? "" }
        lines += breakdown(tr("By Caller"), column: tr("Caller"), CallReport.byCaller(calls), empty: tr("Unknown"),
                           topTopic: { topTopics[CallNames.key($0)] ?? "" })
        lines += breakdown(tr("By Topic"), column: tr("Topic"), CallReport.byTopic(calls), empty: tr("No topic"))
        if calls.contains(where: { !$0.department.isEmpty }) {
            lines += breakdown(tr("By Department"), column: tr("Department"), CallReport.byDepartment(calls),
                               empty: tr("No department"))
        }

        let recurring = CallStats.recurring(calls, limit: .max)
        if !recurring.isEmpty {
            lines += ["", "## " + tr("Recurring Questions"), "",
                      tr("The same caller about the same topic more than once."), "",
                      row([tr("Caller"), tr("Topic"), tr("Calls"), tr("Estimated time"), tr("Last call")]),
                      row(Array(repeating: "---", count: 5))]
            lines += recurring.map {
                row([$0.caller, $0.topic, "\($0.calls)", CallStats.formatEstimate(minutes: $0.estimatedMinutes),
                     ToolFormat.day($0.last)])
            }
        }

        lines += ["", "## " + tr("By Month"), "",
                  row([tr("Month"), tr("Calls"), tr("Estimated time")]), row(Array(repeating: "---", count: 3))]
        // Every month of the period (or from the first call to the last), quiet ones too;
        // only those with calls if a mistyped year would make that centuries of them.
        let months = Dictionary(grouping: calls) { CallStats.Bucket.month.start(of: $0.date) }
        let firstMonth = CallStats.Bucket.month.start(of: days?.lowerBound ?? calls[0].date)
        let lastMonth = CallStats.Bucket.month.start(of: days?.upperBound ?? calls[calls.count - 1].date)
        var listed: [Date] = []
        if (Calendar.zurich.dateComponents([.month], from: firstMonth, to: lastMonth).month ?? 0) <= 600 {
            var month = firstMonth
            while month <= lastMonth {
                listed.append(month)
                // Back to the first of the month, as the calls are grouped (before 1894 Zurich's
                // clock wasn't on the hour, so adding a month alone drifts).
                month = CallStats.Bucket.month.start(of: Calendar.zurich.date(byAdding: .month, value: 1, to: month)!)
            }
        } else {
            listed = months.keys.sorted()
        }
        for month in listed {
            let group = CallReport.total(months[month] ?? [])
            lines.append(row([String(ToolFormat.day(month).prefix(7)), "\(group.count)",
                              CallStats.formatEstimate(minutes: group.estimatedMinutes)]))
        }

        var calendar = Calendar.zurich
        calendar.locale = Localization.locale
        let weekdayNames = Array(calendar.standaloneWeekdaySymbols[1...]) + [calendar.standaloneWeekdaySymbols[0]]
        lines += ["", "## " + tr("By Weekday"), "", row([tr("Weekday"), tr("Calls")]), row(["---", "---"])]
        lines += zip(weekdayNames, CallStats.byWeekday(calls)).map { row([$0, "\($1)"]) }

        let hours = CallStats.byHour(calls)
        lines += ["", "## " + tr("By Time of Day"), "", row([tr("Time"), tr("Calls")]), row(["---", "---"])]
        // From the first busy hour to the last, quiet hours in between too.
        if let first = hours.firstIndex(where: { $0 > 0 }), let last = hours.lastIndex(where: { $0 > 0 }) {
            lines += (first...last).map {
                row([String(format: "%02d:00–%02d:00", $0, ($0 + 1) % 24), "\(hours[$0])"])
            }
        }

        // Comma-separated whatever the CSV setting, and without anything that would end
        // the code block early.
        let csv = CSVExporter(format: .standard).calls(calls).replacingOccurrences(of: "```", with: "'''")
        lines += ["", "## " + tr("Calls"), "", "```csv", csv.trimmingCharacters(in: .newlines), "```"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func breakdown(_ title: String, column: String, _ groups: [CallGroup], empty: String,
                                  topTopic: ((String) -> String)? = nil) -> [String] {
        var header = [column, tr("Calls")] + CallLength.allCases.map(\.detail) + [tr("Estimated time"), tr("Solved by me")]
        if topTopic != nil { header.append(tr("Most common topic")) }
        var lines = ["", "## " + title, "", row(header), row(Array(repeating: "---", count: header.count))]
        for group in groups {
            var cells = [group.name.isEmpty ? empty : group.name, "\(group.count)"]
                + CallLength.allCases.map { "\(group.count($0))" }
                + [CallStats.formatEstimate(minutes: group.estimatedMinutes), "\(group.solvedByMe)"]
            if let topTopic { cells.append(group.name.isEmpty ? "" : topTopic(group.name)) }
            lines.append(row(cells))
        }
        return lines
    }

    /// Days from one to the other, both included.
    private static func dayCount(_ first: Date, _ last: Date) -> Int {
        (Calendar.zurich.dateComponents([.day], from: first.startOfDayZurich, to: last.startOfDayZurich).day ?? 0) + 1
    }

    private static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)).locale(Localization.locale))
    }

    /// A table row; pipes and line breaks in the text would break the table.
    private static func row(_ cells: [String]) -> String {
        let cleaned = cells.map {
            $0.replacingOccurrences(of: "|", with: "\\|")
                .components(separatedBy: .newlines).joined(separator: " ")
        }
        return "| " + cleaned.joined(separator: " | ") + " |"
    }
}
