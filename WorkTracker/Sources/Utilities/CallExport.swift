import Foundation

/// Calls as Markdown for an AI chat: what the fields mean, totals the model would
/// otherwise have to count (and often miscounts), then one table row per call.
enum CallExport {
    /// "Me" or "Caller".
    static func solver(_ call: PhoneCall) -> String {
        call.solvedByMe ? tr("Me") : tr("Caller")
    }

    /// `scope`: what the calls are, e.g. "October 2026" or "Calls from Meier, October 2026".
    static func markdown(_ calls: [PhoneCall], scope: String) -> String {
        let calls = calls.sorted { $0.date < $1.date }
        let total = CallReport.total(calls)
        var lines = [
            "# " + tr("Calls: %@", scope),
            "",
            tr("Each call was logged by the person who was called. Length is one of three blocks: under 15 minutes, 15 minutes to 1 hour, or over 1 hour; calls weren’t timed more exactly. “Solved by” says whether the person called (“Me”) or the caller (“Caller”) solved the issue."),
            "",
            "## " + tr("Totals"),
            "",
            "- " + tr("Calls: %@", "\(total.count)") + " (" + CallLength.allCases.map { "\($0.detail): \(total.count($0))" }.joined(separator: ", ") + ")",
            "- " + tr("Solved by me: %@ of %@", "\(total.solvedByMe)", "\(total.count)"),
        ]
        guard !calls.isEmpty else { return lines.joined(separator: "\n") + "\n" }

        lines += breakdown(tr("By Caller"), column: tr("Caller"), CallReport.byCaller(calls), empty: tr("Unknown"))
        lines += breakdown(tr("By Topic"), column: tr("Topic"), CallReport.byTopic(calls), empty: tr("No topic"))
        if calls.contains(where: { !$0.department.isEmpty }) {
            lines += breakdown(tr("By Department"), column: tr("Department"), CallReport.byDepartment(calls),
                               empty: tr("No department"))
        }

        lines += ["", "## " + tr("Calls"), ""]
        lines.append(row([tr("Date"), tr("Weekday"), tr("Time"), tr("Caller"), tr("Topic"), tr("Department"),
                          tr("Length"), tr("Solved by"), tr("Note")]))
        lines.append(row(Array(repeating: "---", count: 9)))
        for call in calls {
            lines.append(row([ToolFormat.day(call.date), call.date.formatted(.app.weekday(.abbreviated)),
                              TimeField.format(call.date), call.caller, call.topic, call.department,
                              call.length.detail, solver(call), call.note]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func breakdown(_ title: String, column: String, _ groups: [CallGroup], empty: String) -> [String] {
        var lines = ["", "## " + title, "",
                     row([column, tr("Calls")] + CallLength.allCases.map(\.detail) + [tr("Solved by me")]),
                     row(Array(repeating: "---", count: 3 + CallLength.allCases.count))]
        for group in groups {
            lines.append(row([group.name.isEmpty ? empty : group.name, "\(group.count)"]
                             + CallLength.allCases.map { "\(group.count($0))" } + ["\(group.solvedByMe)"]))
        }
        return lines
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
