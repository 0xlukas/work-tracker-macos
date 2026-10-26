import SwiftUI
import SwiftData
import AppKit
import Charts
import UniformTypeIdentifiers

extension CallLength {
    var color: Color {
        switch self {
        case .short: return .teal
        case .medium: return .orange
        case .long: return .red
        }
    }
}

/// The calls of a week, month or year, of every call so far, or of chosen days.
struct CallPeriod: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case week, month, year, all, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return tr("Week")
            case .month: return tr("Month")
            case .year: return tr("Year")
            case .all: return tr("All")
            case .custom: return tr("Custom")
            }
        }
    }

    let scope: Scope
    let from: Date
    /// Last day, inclusive.
    let to: Date

    /// The week, month or year containing `date`; every call, whatever its date, for `.all`;
    /// just that day for `.custom`.
    init(scope: Scope, containing date: Date) {
        let cal = Calendar.zurich
        let day = date.startOfDayZurich
        self.scope = scope
        switch scope {
        case .week:
            from = day.startOfWeekZurich
            to = from.addingDays(6)
        case .month:
            from = cal.date(from: cal.dateComponents([.year, .month], from: day))!
            to = cal.date(byAdding: .month, value: 1, to: from)!.addingDays(-1)
        case .year:
            from = cal.zurichDate(year: day.zurichYear, month: 1, day: 1)
            to = cal.zurichDate(year: day.zurichYear, month: 12, day: 31)
        case .all:
            // Open at both ends, so calls logged later or dated oddly are never left out.
            from = .distantPast
            to = .distantFuture
        case .custom:
            from = day
            to = day
        }
    }

    /// Chosen days, in either order.
    init(from: Date, to: Date) {
        scope = .custom
        self.from = min(from, to).startOfDayZurich
        self.to = max(from, to).startOfDayZurich
    }

    /// Number of days, both ends included.
    var days: Int {
        (Calendar.zurich.dateComponents([.day], from: from, to: to).day ?? 0) + 1
    }

    /// The period `steps` periods later (earlier when negative). Chosen days move by their
    /// own length; all calls stay all calls.
    func shifted(by steps: Int) -> CallPeriod {
        switch scope {
        case .all:
            return self
        case .custom:
            return CallPeriod(from: from.addingDays(steps * days), to: to.addingDays(steps * days))
        case .week, .month, .year:
            let component: Calendar.Component = scope == .week ? .weekOfYear : scope == .month ? .month : .year
            return CallPeriod(scope: scope, containing: Calendar.zurich.date(byAdding: component, value: steps, to: from)!)
        }
    }

    /// The same kind of period around `now`; chosen days keep their length and end on `now`.
    func current(now: Date = Date()) -> CallPeriod {
        switch scope {
        case .custom: return CallPeriod(from: now.addingDays(1 - days), to: now)
        default: return CallPeriod(scope: scope, containing: now)
        }
    }

    /// The period just before, to compare with; none for all calls.
    var previous: CallPeriod? { scope == .all ? nil : shifted(by: -1) }

    /// While the period is under way, where to stop counting the previous one: the same
    /// moment a week, month or year earlier (on a Wednesday at 10:00, last week up to
    /// Wednesday 10:00), so a week that has just begun isn't set against a whole one. Same
    /// clock time across clock changes; the 31st compares with the end of a shorter month.
    /// Nil when the whole previous period counts.
    func comparisonCutoff(now: Date = Date()) -> Date? {
        guard previous != nil, contains(now) else { return nil }
        let cal = Calendar.zurich
        switch scope {
        case .week: return cal.date(byAdding: .weekOfYear, value: -1, to: now)
        case .month: return cal.date(byAdding: .month, value: -1, to: now)
        case .year: return cal.date(byAdding: .year, value: -1, to: now)
        case .custom: return cal.date(byAdding: .day, value: -days, to: now)
        case .all: return nil
        }
    }

    /// The days the period has had so far (all of them once it's over), for exports; nil for
    /// all calls.
    func daysSoFar(now: Date = Date()) -> ClosedRange<Date>? {
        guard scope != .all else { return nil }
        return from...max(from, min(to, now.startOfDayZurich))
    }

    /// Its calls, oldest first.
    var descriptor: FetchDescriptor<PhoneCall> {
        scope == .all ? FetchDescriptor(sortBy: [SortDescriptor(\.date)]) : PhoneCall.descriptor(from: from, through: to)
    }

    func contains(_ date: Date) -> Bool { date.startOfDayZurich >= from && date.startOfDayZurich <= to }

    var title: String {
        switch scope {
        case .week, .custom:
            if from == to { return from.formatted(.app.day().month(.abbreviated).year()) }
            let start = from.zurichYear == to.zurichYear
                ? from.formatted(.app.day().month(.abbreviated))
                : from.formatted(.app.day().month(.abbreviated).year())
            return "\(start) – \(to.formatted(.app.day().month(.abbreviated).year()))"
        case .month:
            return from.formatted(.app.month(.wide).year())
        case .year:
            return String(from.zurichYear)
        case .all:
            return tr("All Calls")
        }
    }
}

/// What the call list is narrowed to: one caller, topic and/or department.
struct CallFilter: Equatable {
    var caller: String?
    var topic: String?
    var department: String?

    var isEmpty: Bool { caller == nil && topic == nil && department == nil }

    func matches(_ call: PhoneCall, ignoring field: KeyPath<PhoneCall, String>? = nil) -> Bool {
        func check(_ value: String?, _ key: KeyPath<PhoneCall, String>) -> Bool {
            guard let value, key != field else { return true }
            return CallNames.same(call[keyPath: key], value)
        }
        return check(caller, \.caller) && check(topic, \.topic) && check(department, \.department)
    }

    /// e.g. "Meier · Mortgage".
    var summary: String {
        [caller.map { $0.isEmpty ? tr("Unknown") : $0 },
         topic.map { $0.isEmpty ? tr("No topic") : $0 },
         department.map { $0.isEmpty ? tr("No department") : $0 }].compactMap { $0 }.joined(separator: " · ")
    }
}

struct CallsView: View {
    @Environment(CallControl.self) private var callControl
    @State private var period = CallPeriod(scope: .month, containing: Date())
    @State private var filter = CallFilter()
    @State private var loggingEarlier = false

    var body: some View {
        VStack(spacing: 0) {
            if period.scope == .custom {
                customRange
                Divider()
            }
            CallsReport(period: period, filter: $filter)
        }
        .navigationTitle(tr("Calls"))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { period = period.shifted(by: -1) } label: {
                    Label(tr("Previous"), systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help(tr("Previous period (⌘[)"))
                .disabled(period.scope == .all)

                Button { period = period.shifted(by: 1) } label: {
                    Label(tr("Next"), systemImage: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .help(tr("Next period (⌘])"))
                .disabled(period.scope == .all)
            }

            ToolbarItem {
                Picker(tr("Period"), selection: Binding(get: { period.scope }, set: choose)) {
                    ForEach(CallPeriod.Scope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            ToolbarItem {
                Button(tr("Today")) { period = period.current() }
                    .disabled(period == period.current())
                    .keyboardShortcut("t", modifiers: .command)
                    .help(tr("Jump to the current period (⌘T)"))
            }

            ToolbarItem {
                Menu {
                    Button(tr("Log Earlier Call…")) { loggingEarlier = true }
                } label: {
                    Label(tr("More"), systemImage: "ellipsis")
                }
                .help(tr("More actions"))
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    callControl.open()
                } label: {
                    Label(tr("Log Call"), systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("n", modifiers: .command)
                .help(tr("Log a call (⌘N)"))
            }
        }
        .sheet(isPresented: $loggingEarlier) {
            CallEditSheet(call: nil)
        }
    }

    private func choose(_ scope: CallPeriod.Scope) {
        switch scope {
        case .custom:
            // Start from what was shown; from all calls, the last 30 days.
            period = period.scope == .all
                ? CallPeriod(from: Date().addingDays(-29), to: Date())
                : CallPeriod(from: period.from, to: period.to)
        case .all:
            period = CallPeriod(scope: .all, containing: Date())
        case .week, .month, .year:
            period = CallPeriod(scope: scope, containing: period.contains(Date()) ? Date() : period.from)
        }
    }

    /// The chosen days.
    private var customRange: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Text(tr("From"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                DatePicker(tr("From"), selection: Binding(get: { period.from }, set: { period = CallPeriod(from: $0, to: max($0, period.to)) }),
                           displayedComponents: .date)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text(tr("To"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                DatePicker(tr("To"), selection: Binding(get: { period.to }, set: { period = CallPeriod(from: min($0, period.from), to: $0) }),
                           displayedComponents: .date)
                    .labelsHidden()
            }
            Text(tr("%lld days", period.days))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

/// One period's calls: totals, how they spread over time, who called about what, and the
/// calls themselves.
private struct CallsReport: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Preferences.self) private var preferences
    @Query private var calls: [PhoneCall]
    /// The period before, for the comparison (none for all calls).
    @Query private var previousCalls: [PhoneCall]
    @Binding var filter: CallFilter
    let period: CallPeriod

    @State private var editing: PhoneCall?
    @State private var renaming: Renaming?
    @State private var renameText = ""
    @State private var statusMessage: String?
    @State private var exportError: String?

    struct Renaming: Identifiable {
        let name: String
        let field: ReferenceWritableKeyPath<PhoneCall, String>
        var id: String { name }
    }

    init(period: CallPeriod, filter: Binding<CallFilter>) {
        self.period = period
        _filter = filter
        _calls = Query(period.descriptor)
        let previous = period.previous
        _previousCalls = Query(PhoneCall.descriptor(from: previous?.from ?? .distantPast, through: previous?.to ?? .distantPast))
    }

    private var shown: [PhoneCall] { calls.filter { filter.matches($0) } }

    private var scopeTitle: String {
        filter.isEmpty ? period.title : "\(period.title), \(filter.summary)"
    }

    private var estimateHelp: String {
        tr("Estimated from the lengths, since calls aren’t timed: under 15 minutes counts as 7.5 minutes, 15 minutes to 1 hour as 37.5, over 1 hour as 75.")
    }

    var body: some View {
        let shown = shown
        let total = CallReport.total(shown)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if calls.isEmpty {
                    ContentUnavailableView {
                        Label(tr("No calls in this period"), systemImage: "phone")
                    } description: {
                        Text(preferences.callShortcut == .none
                             ? tr("Log a call with Log Call or from the menu bar.")
                             : tr("Press %@ in any app to log a call, or use Log Call.", preferences.callShortcut.title))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    // Redrawn each minute, so the comparison follows the clock.
                    TimelineView(.everyMinute) { context in
                        summaryCards(total, now: context.date)
                    }

                    if !shown.isEmpty {
                        timeline(shown)
                        HStack(alignment: .top, spacing: 16) {
                            weekdays(shown)
                            hours(shown)
                        }
                        recurring(shown)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        breakdown(tr("By Caller"), field: \.caller, selection: $filter.caller,
                                  groups: CallReport.byCaller(calls.filter { filter.matches($0, ignoring: \.caller) }),
                                  empty: tr("Unknown"))
                        breakdown(tr("By Topic"), field: \.topic, selection: $filter.topic,
                                  groups: CallReport.byTopic(calls.filter { filter.matches($0, ignoring: \.topic) }),
                                  empty: tr("No topic"))
                        if calls.contains(where: { !$0.department.isEmpty }) || !preferences.callDepartments.isEmpty {
                            breakdown(tr("By Department"), field: \.department, selection: $filter.department,
                                      groups: CallReport.byDepartment(calls.filter { filter.matches($0, ignoring: \.department) }),
                                      empty: tr("No department"), renames: false)
                        }
                    }

                    callList(shown)
                }
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem {
                exportMenu(shown)
            }
        }
        .sheet(item: $editing) { call in
            CallEditSheet(call: call)
        }
        .alert(tr("Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { renaming in
            TextField(tr("Name"), text: $renameText)
            Button(tr("Rename")) { rename(renaming) }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { renaming in
            Text(tr("Renames “%@” in every call. A name that’s already used combines the two.", renaming.name))
        }
        .alert(tr("Export failed"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(tr("OK")) {}
        } message: {
            Text(exportError ?? "")
        }
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            statusMessage = nil
        }
    }

    // MARK: - Header and totals

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(period.title)
                .font(.title2.bold())
            if !filter.isEmpty {
                Button {
                    filter = CallFilter()
                } label: {
                    Label(filter.summary, systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tr("Show all calls"))
            }
            Spacer()
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            // The whole call history in one click, ready to paste into an AI chat.
            Button {
                copyForAI(allCalls(), scope: tr("All time"))
            } label: {
                Label(tr("Copy All Calls for AI"), systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .help(tr("Copies every call with exact totals and how to read them, ready to paste into an AI chat"))
        }
    }

    private func summaryCards(_ total: CallGroup, now: Date) -> some View {
        let cutoff = period.comparisonCutoff(now: now)
        let before = period.previous == nil ? nil : CallReport.total(previousCalls.filter { call in
            filter.matches(call) && cutoff.map { call.date < $0 } != false
        })
        return HStack(alignment: .top, spacing: 12) {
            statCard(tr("Calls"), value: "\(total.count)", icon: "phone.fill", color: .accentColor,
                     detail: before.map { versus(Self.signed(total.count - $0.count), partial: cutoff != nil) })
            statCard(tr("Time on Calls"), value: CallStats.formatEstimate(minutes: total.estimatedMinutes),
                     icon: "hourglass", color: .purple,
                     detail: before.map {
                         versus(Self.signedTime(total.estimatedMinutes - $0.estimatedMinutes), partial: cutoff != nil)
                     })
                .help(estimateHelp)
            statCard(tr("Solved by me"), value: total.solvedShare.map(Self.percent) ?? "–",
                     icon: "checkmark.circle.fill", color: .green,
                     detail: tr("%@ of %@", "\(total.solvedByMe)", "\(total.count)"))
            lengthsCard(total)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// e.g. "+3 vs. previous period"; while the period is under way, against the same point
    /// of the one before.
    private func versus(_ change: String, partial: Bool) -> String {
        guard partial else { return tr("%@ vs. previous period", change) }
        switch period.scope {
        case .week: return tr("%@ vs. this time last week", change)
        case .month: return tr("%@ vs. this time last month", change)
        case .year: return tr("%@ vs. this time last year", change)
        case .all, .custom: return tr("%@ vs. same point last period", change)
        }
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : value < 0 ? "−\(-value)" : "±0"
    }

    /// e.g. "+1h 30m" or "−0h 08m", with the same minus sign as the call count.
    private static func signedTime(_ minutes: Double) -> String {
        let text = TimeFormatting.signedHours(minutes / 60)
        return text.hasPrefix("-") ? "−" + text.dropFirst() : text
    }

    private static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)).locale(Localization.locale))
    }

    private func statCard(_ title: String, value: String, icon: String, color: Color, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                // The comparisons wrap in narrow windows (and in German).
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func lengthsCard(_ total: CallGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(tr("Lengths"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(CallLength.allCases) { length in
                HStack(spacing: 6) {
                    Circle()
                        .fill(length.color)
                        .frame(width: 7, height: 7)
                    Text(length.title)
                    Spacer()
                    Text("\(total.count(length))")
                        .monospacedDigit()
                }
                .font(.caption)
                .help(length.detail)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(length.detail): \(total.count(length))")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    // MARK: - Charts

    /// Calls per day, week or month (whichever suits the period), split by length.
    private func timeline(_ calls: [PhoneCall]) -> some View {
        // All calls: from the first call to today, or to the last call if that's later.
        let dates = calls.map(\.date)
        let start = period.scope == .all ? (dates.min() ?? Date()).startOfDayZurich : period.from
        let end = period.scope == .all ? max(dates.max() ?? Date(), Date()).startOfDayZurich : period.to
        let bucket = CallStats.Bucket.forSpan(from: start, to: end)
        let bars = CallStats.timeline(calls, bucket: bucket)
        let domainStart = bucket.start(of: start)
        let domainEnd = Calendar.zurich.date(byAdding: bucket.component, value: 1, to: bucket.start(of: end))!
        let highest = Dictionary(grouping: bars, by: \.start).values.map { $0.reduce(0) { $0 + $1.count } }.max() ?? 1
        let title = switch bucket {
        case .day: tr("Calls per Day")
        case .week: tr("Calls per Week")
        case .month: tr("Calls per Month")
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Chart(bars) { bar in
                BarMark(x: .value(tr("Date"), bar.start, unit: bucket.component),
                        y: .value(tr("Calls"), bar.count))
                    .foregroundStyle(by: .value(tr("Length"), bar.length.title))
            }
            .chartForegroundStyleScale(domain: CallLength.allCases.map(\.title), range: CallLength.allCases.map(\.color))
            .chartXScale(domain: domainStart...domainEnd)
            .chartYAxis { AxisMarks(values: .stride(by: Double(max(1, (highest + 3) / 4)))) }
            .frame(height: 170)
            .accessibilityLabel(title)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func weekdays(_ calls: [PhoneCall]) -> some View {
        var calendar = Calendar.zurich
        calendar.locale = Localization.locale
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let names = Array(symbols[1...]) + [symbols[0]]
        let counts = CallStats.byWeekday(calls)
        let busiest = counts.indices.max { counts[$0] < counts[$1] }.map { calendar.standaloneWeekdaySymbols[($0 + 1) % 7] }
        return distribution(tr("By Weekday"), labels: names, counts: counts,
                            note: busiest.map { tr("Most calls on %@", $0) } ?? "")
    }

    private func hours(_ calls: [PhoneCall]) -> some View {
        let counts = CallStats.byHour(calls)
        let used = counts.indices.filter { counts[$0] > 0 }
        let range = min(used.first ?? 7, 7)...max(used.last ?? 18, 18)
        let busiest = counts.indices.max { counts[$0] < counts[$1] }
        return distribution(tr("By Time of Day"), labels: range.map { String(format: "%02d", $0) },
                            counts: range.map { counts[$0] },
                            note: busiest.map { tr("Most calls between %@ and %@", String(format: "%02d:00", $0),
                                                   String(format: "%02d:00", ($0 + 1) % 24)) } ?? "")
    }

    private func distribution(_ title: String, labels: [String], counts: [Int], note: String) -> some View {
        let highest = counts.max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Chart(Array(zip(labels, counts)), id: \.0) { label, count in
                BarMark(x: .value(title, label), y: .value(tr("Calls"), count))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartXScale(domain: labels)
            .chartYAxis { AxisMarks(values: .stride(by: Double(max(1, (highest + 2) / 3)))) }
            .frame(height: 110)
            .accessibilityLabel(title)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// The same caller about the same topic more than once. Clicking one shows its calls.
    @ViewBuilder
    private func recurring(_ calls: [PhoneCall]) -> some View {
        let items = CallStats.recurring(calls)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Recurring Questions"))
                    .font(.headline)
                Text(tr("The same caller about the same topic more than once: worth a short guide or a word with them."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    Button {
                        filter.caller = item.caller
                        filter.topic = item.topic
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.caller)
                                .font(.subheadline.weight(.medium))
                            Text(item.topic)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(CallStats.formatEstimate(minutes: item.estimatedMinutes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(tr("%lld calls", item.calls))
                                .font(.subheadline.bold().monospacedDigit())
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Show these calls"))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    // MARK: - Breakdowns

    /// Calls per caller, topic or department. Clicking a row shows only its calls.
    private func breakdown(_ title: String, field: ReferenceWritableKeyPath<PhoneCall, String>, selection: Binding<String?>,
                           groups: [CallGroup], empty: String, renames: Bool = true) -> some View {
        let most = groups.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            if groups.isEmpty {
                Text(tr("No calls"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups.prefix(12)) { group in
                let isSelected = selection.wrappedValue.map { CallNames.same($0, group.name) } ?? false
                Button {
                    selection.wrappedValue = isSelected ? nil : group.name
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(group.name.isEmpty ? empty : group.name)
                                .font(.subheadline)
                                .foregroundStyle(group.name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            if group.solvedByMe > 0 {
                                Label("\(group.solvedByMe)", systemImage: "checkmark.circle")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.green)
                                    .help(tr("Solved by me"))
                            }
                            Text(CallStats.formatEstimate(minutes: group.estimatedMinutes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help(estimateHelp)
                            Text("\(group.count)")
                                .font(.subheadline.bold().monospacedDigit())
                        }
                        LengthBar(group: group, scale: Double(group.count) / Double(most))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .rowHighlight(isSelected, tint: .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.name.isEmpty ? empty : group.name)
                .accessibilityValue(lengthSummary(group))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .contextMenu {
                    Button(isSelected ? tr("Show All Calls") : tr("Show Only These Calls")) {
                        selection.wrappedValue = isSelected ? nil : group.name
                    }
                    if renames && !group.name.isEmpty {
                        Button(tr("Rename…")) {
                            renameText = group.name
                            renaming = Renaming(name: group.name, field: field)
                        }
                    }
                }
            }
            if groups.count > 12 {
                Text(tr("%lld more", groups.count - 12))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    private func lengthSummary(_ group: CallGroup) -> String {
        ([tr("%lld calls", group.count), CallStats.formatEstimate(minutes: group.estimatedMinutes)]
            + CallLength.allCases.map { "\($0.detail): \(group.count($0))" }
            + [tr("Solved by me: %@ of %@", "\(group.solvedByMe)", "\(group.count)")]).joined(separator: ", ")
    }

    // MARK: - Calls

    private func callList(_ calls: [PhoneCall]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Calls"))
                .font(.headline)
            LazyVStack(spacing: 2) {
                ForEach(calls.reversed()) { call in
                    CallRow(call: call)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = call }
                        .accessibilityAction(named: tr("Edit")) { editing = call }
                        .accessibilityAction(named: tr("Delete")) { modelContext.delete(call) }
                        .contextMenu {
                            Button { editing = call } label: { Label(tr("Edit…"), systemImage: "pencil") }
                            Divider()
                            Button(role: .destructive) { modelContext.delete(call) } label: {
                                Label(tr("Delete"), systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    // MARK: - Export

    /// The calls shown, or every call there is.
    private func exportMenu(_ shown: [PhoneCall]) -> some View {
        let everything = (try? modelContext.fetchCount(FetchDescriptor<PhoneCall>())) ?? 0
        return Menu {
            Section(tr("Shown: %@", scopeTitle)) {
                Button(tr("Copy for AI Chat")) { copyForAI(shown, scope: scopeTitle, days: period.daysSoFar()) }
                Button(tr("Save as Markdown…")) { save(markdown: shown, scope: scopeTitle, days: period.daysSoFar()) }
                Button(tr("Save as CSV…")) { save(csv: shown, scope: scopeTitle) }
            }
            .disabled(shown.isEmpty)
            Section(tr("All Calls")) {
                Button(tr("Copy All for AI Chat")) { copyForAI(allCalls(), scope: tr("All time")) }
                Button(tr("Save All as Markdown…")) { save(markdown: allCalls(), scope: tr("All time")) }
                Button(tr("Save All as CSV…")) { save(csv: allCalls(), scope: tr("All time")) }
            }
            .disabled(everything == 0)
            Divider()
            Picker(tr("CSV format"), selection: Binding(get: { preferences.csvFormat }, set: { preferences.csvFormat = $0 })) {
                ForEach(CSVFormat.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label(tr("Export"), systemImage: "square.and.arrow.up")
        }
        .help(tr("Copy or save the calls shown or all calls, e.g. to ask an AI about them"))
    }

    private func allCalls() -> [PhoneCall] {
        (try? modelContext.fetch(FetchDescriptor<PhoneCall>(sortBy: [SortDescriptor(\.date)]))) ?? []
    }

    // MARK: - Actions

    private func rename(_ renaming: Renaming) {
        let name = CallNames.trimmed(renameText)
        guard !name.isEmpty else { return }
        CallLog.rename(renaming.name, to: name, field: renaming.field, context: modelContext)
        // Keep showing the renamed caller or topic.
        if filter.caller.map({ CallNames.same($0, renaming.name) }) == true && renaming.field == \PhoneCall.caller {
            filter.caller = name
        }
        if filter.topic.map({ CallNames.same($0, renaming.name) }) == true && renaming.field == \PhoneCall.topic {
            filter.topic = name
        }
    }

    /// `days`: the days the calls could be on, when they're one period's.
    private func copyForAI(_ calls: [PhoneCall], scope: String, days: ClosedRange<Date>? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CallExport.markdown(calls, scope: scope, days: days), forType: .string)
        withAnimation { statusMessage = tr("Copied %lld calls. Paste them into an AI chat and ask away.", calls.count) }
    }

    private func save(markdown calls: [PhoneCall], scope: String, days: ClosedRange<Date>? = nil) {
        save(CallExport.markdown(calls, scope: scope, days: days), scope: scope, type: UTType(filenameExtension: "md") ?? .plainText, ext: "md")
    }

    private func save(csv calls: [PhoneCall], scope: String) {
        save(CSVExporter(format: preferences.csvFormat).calls(calls), scope: scope, type: .commaSeparatedText, ext: "csv")
    }

    private func save(_ text: String, scope: String, type: UTType, ext: String) {
        let panel = NSSavePanel()
        panel.title = tr("Export Calls")
        panel.nameFieldStringValue = "\(tr("Calls")) \(scope).\(ext)".replacingOccurrences(of: "/", with: "-")
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }
}

/// A group's calls as one bar, split by length.
private struct LengthBar: View {
    let group: CallGroup
    /// The bar's share of the full width (the group with the most calls fills it).
    let scale: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * min(max(scale, 0), 1)
            HStack(spacing: 1) {
                ForEach(CallLength.allCases) { length in
                    let count = group.count(length)
                    if count > 0 {
                        Rectangle()
                            .fill(length.color.gradient)
                            .frame(width: max(2, width * Double(count) / Double(max(group.count, 1)) - 1))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct CallRow: View {
    let call: PhoneCall
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(call.date.formatted(.app.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.subheadline)
                Text(TimeField.format(call.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(call.caller)
                        .font(.body.weight(.medium))
                    if !call.topic.isEmpty {
                        Text(call.topic)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                if !call.note.isEmpty {
                    Text(call.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if !call.department.isEmpty {
                Text(call.department)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: call.solvedByMe ? "checkmark.circle.fill" : "person.fill.checkmark")
                .foregroundStyle(call.solvedByMe ? .green : .secondary)
                .help(call.solvedByMe ? tr("Solved by me") : tr("Solved by the caller"))
                .accessibilityLabel(call.solvedByMe ? tr("Solved by me") : tr("Solved by the caller"))
            Text(call.length.title)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(call.length.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(call.length.color.opacity(0.12)))
                .frame(width: 76, alignment: .trailing)
                .help(call.length.detail)
                .accessibilityLabel(call.length.detail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .rowHighlight(isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}
