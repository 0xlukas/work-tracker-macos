import SwiftUI
import SwiftData
import AppKit
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

/// A week, month or year of calls.
struct CallPeriod: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case week, month, year

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return tr("Week")
            case .month: return tr("Month")
            case .year: return tr("Year")
            }
        }
    }

    let scope: Scope
    let from: Date
    /// Last day, inclusive.
    let to: Date

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
        }
    }

    /// The period `steps` periods later (earlier when negative).
    func shifted(by steps: Int) -> CallPeriod {
        let component: Calendar.Component = scope == .week ? .weekOfYear : scope == .month ? .month : .year
        return CallPeriod(scope: scope, containing: Calendar.zurich.date(byAdding: component, value: steps, to: from)!)
    }

    func contains(_ date: Date) -> Bool { date.startOfDayZurich >= from && date.startOfDayZurich <= to }

    var title: String {
        switch scope {
        case .week:
            return "\(from.formatted(.app.day().month(.abbreviated))) – \(to.formatted(.app.day().month(.abbreviated).year()))"
        case .month:
            return from.formatted(.app.month(.wide).year())
        case .year:
            return String(from.zurichYear)
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
        CallsReport(period: period, filter: $filter)
            .navigationTitle(tr("Calls"))
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { period = period.shifted(by: -1) } label: {
                        Label(tr("Previous"), systemImage: "chevron.left")
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .help(tr("Previous period (⌘[)"))

                    Button { period = period.shifted(by: 1) } label: {
                        Label(tr("Next"), systemImage: "chevron.right")
                    }
                    .keyboardShortcut("]", modifiers: .command)
                    .help(tr("Next period (⌘])"))
                }

                ToolbarItem {
                    Picker(tr("Period"), selection: Binding(
                        get: { period.scope },
                        set: { period = CallPeriod(scope: $0, containing: period.contains(Date()) ? Date() : period.from) })) {
                        ForEach(CallPeriod.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                ToolbarItem {
                    Button(tr("Today")) { period = CallPeriod(scope: period.scope, containing: Date()) }
                        .disabled(period.contains(Date()))
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
}

/// One period's calls: totals, who called about what, and the calls themselves.
private struct CallsReport: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Preferences.self) private var preferences
    @Query private var calls: [PhoneCall]
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
        _calls = Query(PhoneCall.descriptor(from: period.from, through: period.to))
    }

    private var shown: [PhoneCall] { calls.filter { filter.matches($0) } }

    private var scopeTitle: String {
        filter.isEmpty ? period.title : "\(period.title), \(filter.summary)"
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
                    HStack(spacing: 12) {
                        statCard(tr("Calls"), value: "\(total.count)", icon: "phone.fill", color: .accentColor)
                        ForEach(CallLength.allCases) { length in
                            statCard(length.title, value: "\(total.count(length))", icon: "clock", color: length.color)
                                .help(length.detail)
                        }
                        statCard(tr("Solved by me"), value: "\(total.solvedByMe)", icon: "checkmark.circle.fill", color: .green,
                                 detail: total.count > 0 ? tr("of %@", "\(total.count)") : nil)
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
                Menu {
                    Button(tr("Copy for AI Chat")) { copyForAI(shown) }
                    Divider()
                    Button(tr("Save as Markdown…")) { save(markdown: shown) }
                    Button(tr("Save as CSV…")) { save(csv: shown) }
                    Picker(tr("CSV format"), selection: Binding(get: { preferences.csvFormat }, set: { preferences.csvFormat = $0 })) {
                        ForEach(CSVFormat.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(tr("Export"), systemImage: "square.and.arrow.up")
                }
                .disabled(shown.isEmpty)
                .help(tr("Copy or save the calls shown, e.g. to ask an AI about them"))
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

    // MARK: - Header

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
        }
    }

    private func statCard(_ title: String, value: String, icon: String, color: Color, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
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
        ([tr("%lld calls", group.count)] + CallLength.allCases.map { "\($0.detail): \(group.count($0))" }
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

    private func copyForAI(_ calls: [PhoneCall]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CallExport.markdown(calls, scope: scopeTitle), forType: .string)
        withAnimation { statusMessage = tr("Copied %lld calls. Paste them into an AI chat and ask away.", calls.count) }
    }

    private func save(markdown calls: [PhoneCall]) {
        save(CallExport.markdown(calls, scope: scopeTitle), type: UTType(filenameExtension: "md") ?? .plainText, ext: "md")
    }

    private func save(csv calls: [PhoneCall]) {
        save(CSVExporter(format: preferences.csvFormat).calls(calls), type: .commaSeparatedText, ext: "csv")
    }

    private func save(_ text: String, type: UTType, ext: String) {
        let panel = NSSavePanel()
        panel.title = tr("Export Calls")
        panel.nameFieldStringValue = "\(tr("Calls")) \(scopeTitle).\(ext)".replacingOccurrences(of: "/", with: "-")
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
