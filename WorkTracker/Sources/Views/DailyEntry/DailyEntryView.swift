import SwiftUI
import SwiftData

/// Which entry sheet is open.
enum EntrySheet: Identifiable {
    case new(start: Date)
    case edit(WorkSegment)
    case duplicate(WorkSegment, start: Date)
    case draft(EntryDraft)

    var id: String {
        switch self {
        case .new(let start): return "new-\(start.timeIntervalSinceReferenceDate)"
        case .edit(let segment): return "edit-\(segment.persistentModelID.hashValue)"
        case .duplicate(let segment, _): return "dup-\(segment.persistentModelID.hashValue)"
        case .draft(let draft): return "draft-\(draft.id)"
        }
    }
}

struct DailyEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Preferences.self) private var preferences
    @Environment(WorkTimer.self) private var timer
    @Query(sort: \VacationDay.date) private var absences: [VacationDay]

    @State private var selectedDate = Date().startOfDayZurich
    @State private var sheet: EntrySheet?
    @State private var statusMessage: String?
    @State private var showVoicePanel = false
    /// Entries from a voice command still to be confirmed, one sheet after another.
    @State private var pendingDrafts: [EntryDraft] = []

    var body: some View {
        let calculator = preferences.calculator(absences: VacationDay.lookup(absences))
        DailyEntryWeek(selectedDate: $selectedDate, calculator: calculator, statusMessage: statusMessage,
                       onEdit: { sheet = .edit($0) },
                       onDuplicate: { sheet = .duplicate($0, start: nextStart(on: $0.date)) },
                       onDelete: { modelContext.delete($0) })
            .navigationTitle(tr("Daily Entry"))
            .toolbar { toolbar }
            .sheet(item: $sheet, onDismiss: showNextDraft) { sheet in
                switch sheet {
                case .new(let start):
                    SegmentEditSheet(date: selectedDate, segment: nil, suggestedStart: start)
                case .edit(let segment):
                    SegmentEditSheet(date: selectedDate, segment: segment)
                case .duplicate(let segment, let start):
                    SegmentEditSheet(date: segment.date, segment: nil, suggestedStart: start, template: segment)
                case .draft(let draft):
                    SegmentEditSheet(draft: draft, project: draft.project.flatMap { EntryActions.project(named: $0, in: modelContext) })
                }
            }
            .task(id: statusMessage) {
                guard statusMessage != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                statusMessage = nil
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { selectedDate = selectedDate.addingDays(-1) } label: {
                Label(tr("Previous Day"), systemImage: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .help(tr("Previous day (⌘[)"))

            Button { selectedDate = selectedDate.addingDays(1) } label: {
                Label(tr("Next Day"), systemImage: "chevron.right")
            }
            .keyboardShortcut("]", modifiers: .command)
            .help(tr("Next day (⌘])"))
        }

        ToolbarItem {
            Button(tr("Today")) { selectedDate = Date().startOfDayZurich }
                .disabled(selectedDate.isSameDay(as: Date()))
                .help(tr("Jump to today (⌘T)"))
                .keyboardShortcut("t", modifiers: .command)
        }

        ToolbarItem {
            TimerControl()
        }

        ToolbarItem {
            Button { showVoicePanel = true } label: {
                Label(tr("Voice Entry"), systemImage: "mic")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help(tr("Log time or start and stop the timer by voice (⇧⌘D)"))
            .popover(isPresented: $showVoicePanel, arrowEdge: .bottom) {
                VoiceCommandPanel(onCommand: perform)
            }
        }

        ToolbarItem {
            Menu {
                if let previous = EntryActions.previousDayWithEntries(before: selectedDate, in: modelContext) {
                    Button(tr("Copy Entries from %@", previous.formatted(.app.weekday(.abbreviated).day().month(.abbreviated)))) {
                        copyEntries(from: previous)
                    }
                } else {
                    Text(tr("No earlier entries to copy"))
                }
            } label: {
                Label(tr("More"), systemImage: "ellipsis")
            }
            .help(tr("More actions"))
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .primaryAction) {
            Button {
                sheet = .new(start: nextStart(on: selectedDate))
            } label: {
                Label(tr("Add Entry"), systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut("n", modifiers: .command)
            .help(tr("Add a time entry (⌘N)"))
        }
    }

    private func nextStart(on day: Date) -> Date {
        EntryActions.nextStart(on: day, in: modelContext)
    }

    private func perform(_ command: VoiceCommand) {
        switch command {
        case .log(let drafts):
            pendingDrafts = drafts
            showNextDraft()
        case .startTimer(let name, let date):
            guard let project = name.flatMap({ EntryActions.project(named: $0, in: modelContext) })
                    ?? EntryActions.lastUsedProject(in: modelContext) else { return }
            statusMessage = TimerActions.start(project, at: date ?? Date(), timer: timer, context: modelContext)
        case .stopTimer(let date):
            statusMessage = TimerActions.stop(at: date ?? Date(), timer: timer, context: modelContext)
        case .notUnderstood:
            break
        }
    }

    /// Open the next voice draft once the previous sheet has closed.
    private func showNextDraft() {
        guard sheet == nil, !pendingDrafts.isEmpty else { return }
        let draft = pendingDrafts.removeFirst()
        selectedDate = draft.date
        sheet = .draft(draft)
    }

    private func copyEntries(from source: Date) {
        let result = EntryActions.copyEntries(from: source, to: selectedDate, in: modelContext)
        let day = source.formatted(.app.weekday(.abbreviated).day().month(.abbreviated))
        if result.skipped > 0 {
            statusMessage = tr("Copied %lld entries from %@; %lld skipped because they overlap.", result.copied, day, result.skipped)
        } else {
            statusMessage = tr("Copied %lld entries from %@.", result.copied, day)
        }
    }
}

// MARK: - Week content (only the selected week's entries are fetched)

private struct DailyEntryWeek: View {
    @Binding var selectedDate: Date
    let calculator: WorkHoursCalculator
    let statusMessage: String?
    let onEdit: (WorkSegment) -> Void
    let onDuplicate: (WorkSegment) -> Void
    let onDelete: (WorkSegment) -> Void

    @Environment(Preferences.self) private var preferences
    @Query private var weekSegments: [WorkSegment]

    init(selectedDate: Binding<Date>, calculator: WorkHoursCalculator, statusMessage: String?,
         onEdit: @escaping (WorkSegment) -> Void, onDuplicate: @escaping (WorkSegment) -> Void,
         onDelete: @escaping (WorkSegment) -> Void) {
        _selectedDate = selectedDate
        self.calculator = calculator
        self.statusMessage = statusMessage
        self.onEdit = onEdit
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        let start = selectedDate.wrappedValue.startOfWeekZurich
        let end = start.addingDays(7)
        _weekSegments = Query(filter: #Predicate<WorkSegment> { $0.date >= start && $0.date < end },
                              sort: \WorkSegment.startTime)
    }

    var body: some View {
        let hours = WorkSegment.hoursByDay(weekSegments)
        let day = selectedDate.startOfDayZurich
        let summary = calculator.classify(date: day)
        let segments = weekSegments.filter { $0.date.isSameDay(as: day) }
        let isMissing = isMissing(day, hours: hours[day] ?? 0)

        HStack(spacing: 0) {
            sidePanel(hours: hours, summary: summary)
                .frame(width: 272)
            Divider()
            entriesPanel(segments: segments, total: hours[day] ?? 0, summary: summary, isMissing: isMissing)
        }
    }

    /// A past working day since tracking started with nothing logged.
    private func isMissing(_ day: Date, hours: Double) -> Bool {
        day >= preferences.trackingStartDate && day < Date().startOfDayZurich
            && calculator.isMissingEntries(calculator.classify(date: day), hours: hours)
    }

    // MARK: Left panel: calendar, week, day badges

    /// Mon–Fri always, plus Sat/Sun when scheduled or when work is logged on them.
    private func weekDays(hours: [Date: Double]) -> [Date] {
        let monday = selectedDate.startOfWeekZurich
        return (0..<7).map { monday.addingDays($0) }.filter { day in
            !day.isWeekend || (hours[day] ?? 0) > 0 || calculator.schedule.hours(on: day) > 0
        }
    }

    private struct DayBadge: Identifiable {
        let icon: String
        let color: Color
        let text: String
        var id: String { icon + text }
    }

    private func badges(for summary: DaySummary) -> [DayBadge] {
        var badges: [DayBadge] = []
        if let holiday = summary.holiday {
            badges.append(DayBadge(icon: "flag.fill", color: .orange,
                                   text: holiday.type == .halfDay ? tr("%@ (half day)", holiday.name) : holiday.name))
        }
        if let category = summary.category {
            badges.append(DayBadge(icon: category.icon, color: category.color.color,
                                   text: summary.isHalfDayAbsence ? tr("%@ (half day)", category.name) : category.name))
            if summary.isOverAllowance {
                badges.append(DayBadge(icon: "exclamationmark.triangle.fill", color: .red, text: tr("Over vacation allowance")))
            }
        }
        if summary.isWeekend {
            badges.append(DayBadge(icon: "moon.fill", color: .purple, text: tr("Weekend")))
        } else if summary.scheduledHours == 0 {
            badges.append(DayBadge(icon: "moon.fill", color: .purple, text: tr("No scheduled work")))
        }
        return badges
    }

    private func sidePanel(hours: [Date: Double], summary: DaySummary) -> some View {
        let badges = badges(for: summary)
        return VStack(alignment: .leading, spacing: 0) {
            DatePicker("", selection: Binding(get: { selectedDate }, set: { selectedDate = $0.startOfDayZurich }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("This Week"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                VStack(spacing: 2) {
                    ForEach(weekDays(hours: hours), id: \.self) { day in
                        weekDayRow(day, hours: hours[day] ?? 0)
                    }
                }
                .padding(.horizontal, 12)

                MissingEntriesReader(trackingStart: preferences.trackingStartDate) { missing in
                    if !missing.isEmpty {
                        MissingEntriesMenu(days: missing) { selectedDate = $0 }
                            .padding(.horizontal, 12)
                            .padding(.top, 2)
                    }
                }
            }

            if !badges.isEmpty {
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                FlowLayout(spacing: 6) {
                    ForEach(badges) { badge in
                        TintedPill(text: badge.text, icon: badge.icon, color: badge.color)
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer()
        }
    }

    private func weekDayRow(_ day: Date, hours dayHours: Double) -> some View {
        let isSelected = day.isSameDay(as: selectedDate)
        let isToday = day.isSameDay(as: Date())
        let expected = calculator.classify(date: day).expectedHours
        let isMissing = isMissing(day, hours: dayHours)

        return Button {
            selectedDate = day
        } label: {
            HStack(spacing: 8) {
                Text(day, format: .app.weekday(.abbreviated))
                    .font(.caption)
                    .frame(width: 28, alignment: .leading)
                    .foregroundStyle(isToday ? Color.accentColor : Color.secondary)

                Text(day, format: .app.day())
                    .font(.caption.monospacedDigit())
                    .frame(width: 20, alignment: .trailing)

                MeterBar(progress: expected > 0 ? dayHours / expected : 0,
                         color: dayHours >= expected ? .green : .accentColor,
                         height: 3)
                    .opacity(dayHours > 0 ? 1 : 0.6)

                Group {
                    if isMissing {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .help(tr("No entries"))
                            .accessibilityLabel(tr("No entries"))
                    } else {
                        Text(dayHours > 0 ? TimeFormatting.hoursCompact(dayHours) : "–")
                            .foregroundStyle(dayHours > 0 ? .primary : .quaternary)
                    }
                }
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .rowHighlight(isSelected, tint: .accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: Right panel: day header + entries

    private func entriesPanel(segments: [WorkSegment], total: Double, summary: DaySummary, isMissing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedDate, format: .app.weekday(.wide).day().month(.wide).year())
                    .font(.title2.bold())

                HStack(spacing: 12) {
                    Label(TimeFormatting.hours(total), systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    if summary.expectedHours > 0 {
                        Text(tr("of %@ expected", TimeFormatting.hours(summary.expectedHours)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if total > summary.expectedHours {
                            Text(tr("· +%@ over", TimeFormatting.hours(total - summary.expectedHours)))
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }
                }

                if summary.expectedHours > 0 {
                    MeterBar(progress: total / summary.expectedHours,
                             color: total >= summary.expectedHours ? .green : .accentColor)
                        .padding(.top, 6)
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 24)

            if segments.isEmpty && isMissing {
                ContentUnavailableView {
                    Label(tr("No entries for this day"), systemImage: "exclamationmark.circle")
                } description: {
                    Text(tr("This was a working day. Press ⌘N to log your time, or record an absence in Absences."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                ContentUnavailableView {
                    Label(tr("No time entries yet"), systemImage: "clock")
                } description: {
                    Text(tr("Click \"Add Entry\" or press ⌘N to log your work"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(segments) { segment in
                            SegmentRowView(segment: segment,
                                           onEdit: { onEdit(segment) },
                                           onDuplicate: { onDuplicate(segment) },
                                           onDelete: { onDelete(segment) })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
