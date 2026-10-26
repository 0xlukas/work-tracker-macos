import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Every number the Overview shows, computed once per update.
struct OverviewNumbers {
    let today: PeriodSummary
    let week: PeriodSummary
    let month: PeriodSummary
    let toDate: PeriodSummary
    let fullYear: PeriodSummary
    let calendarYear: PeriodSummary
    let allTime: PeriodSummary
    let months: [MonthSummary]
    let budget: VacationBudget
    /// Past working days in the selected year with nothing logged.
    let missingEntryDays: Int
    let yearStart: Date
    let yearEnd: Date
    /// First and last day of the selected year inside the tracking window (up to today).
    let window: (start: Date, end: Date)?

    init(calculator: WorkHoursCalculator, hours: [Date: Double], year: Int, trackingStart: Date, now: Date = Date()) {
        let today = now.startOfDayZurich
        let cal = Calendar.zurich
        yearStart = cal.zurichDate(year: year, month: 1, day: 1)
        yearEnd = cal.zurichDate(year: year, month: 12, day: 31)
        let effectiveStart = max(trackingStart, yearStart)
        let effectiveEnd = min(today, yearEnd)
        window = effectiveStart <= effectiveEnd ? (effectiveStart, effectiveEnd) : nil

        func summary(_ from: Date, _ to: Date) -> PeriodSummary {
            from <= to ? calculator.periodSummary(from: from, to: to, hours: hours) : .empty
        }
        // Nothing is expected before tracking started, so a new user's first week or
        // month doesn't open with a large deficit.
        self.today = summary(max(today, trackingStart), today)
        week = summary(max(today.startOfWeekZurich, trackingStart), today)
        month = summary(max(cal.date(from: cal.dateComponents([.year, .month], from: today))!, trackingStart), today)
        toDate = summary(effectiveStart, effectiveEnd)
        fullYear = summary(effectiveStart, yearEnd)
        calendarYear = summary(yearStart, yearEnd)
        allTime = summary(trackingStart, today)
        months = calculator.monthlyBreakdown(year: year, hours: hours, startDate: trackingStart, endDate: today)
        budget = calculator.vacationBudget(year: year)
        missingEntryDays = calculator.missingEntryDays(from: effectiveStart, to: min(today.addingDays(-1), yearEnd),
                                                       hours: hours).count
    }
}

struct OverviewView: View {
    @Environment(Preferences.self) private var preferences
    @Query(sort: \WorkSegment.startTime) private var allSegments: [WorkSegment]
    @Query(sort: \VacationDay.date) private var allAbsences: [VacationDay]

    @State private var selectedYear = Date().zurichYear
    @State private var showStartDatePicker = false
    @State private var exportError: String?

    var body: some View {
        @Bindable var preferences = preferences
        let calculator = preferences.calculator(absences: VacationDay.lookup(allAbsences))
        let hours = WorkSegment.hoursByDay(allSegments)
        let numbers = OverviewNumbers(calculator: calculator, hours: hours, year: selectedYear,
                                      trackingStart: preferences.trackingStartDate)
        let allTimeBalance = numbers.allTime.balance + preferences.openingBalanceHours
        let showsAllTime = preferences.trackingStartDate.zurichYear < selectedYear || preferences.openingBalanceHours != 0

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // "Right now" snapshot — answers "am I on track?" at a glance
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Right Now"))
                        .font(.headline)
                    HStack(spacing: 12) {
                        snapshotCard(tr("Today"), numbers.today)
                        snapshotCard(tr("This Week"), numbers.week)
                        snapshotCard(tr("This Month"), numbers.month)
                    }
                }

                // Tracking start date
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    Text(tr("Tracking since"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showStartDatePicker {
                        DatePicker("", selection: $preferences.trackingStartDate, displayedComponents: .date)
                            .labelsHidden()
                        Button(tr("Done")) {
                            showStartDatePicker = false
                        }
                        .controlSize(.small)
                    } else {
                        Button {
                            showStartDatePicker = true
                        } label: {
                            Text(preferences.trackingStartDate, format: .app.day().month(.wide).year())
                                .font(.caption.bold())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .cardSurface(tint: .accentColor, radius: Surface.rowRadius)

                // Primary: Balance to date
                HStack(spacing: 12) {
                    statCard(
                        icon: "target",
                        iconColor: .accentColor,
                        title: tr("Expected (to date)"),
                        value: TimeFormatting.hours(numbers.toDate.expectedHours),
                        detail: tr("%lld working days", numbers.toDate.workingDays)
                    )
                    statCard(
                        icon: "checkmark.circle",
                        iconColor: .green,
                        title: tr("Worked (to date)"),
                        value: TimeFormatting.hours(numbers.toDate.actualHours),
                        detail: nil
                    )
                    balanceCard(title: tr("Current Balance"), balance: numbers.toDate.balance, detail: nil)
                    if showsAllTime {
                        balanceCard(title: tr("All-time Balance"), balance: allTimeBalance,
                                    detail: preferences.openingBalanceHours != 0
                                        ? tr("incl. %@ opening balance", TimeFormatting.signedHours(preferences.openingBalanceHours))
                                        : nil)
                    }
                }

                // Full year info (secondary)
                if selectedYear == Date().zurichYear {
                    HStack(spacing: 16) {
                        Label(tr("Full year target: %@", TimeFormatting.hours(numbers.fullYear.expectedHours)),
                              systemImage: "calendar")
                        Label(tr("Remaining: %@", TimeFormatting.hours(max(0, numbers.fullYear.expectedHours - numbers.toDate.actualHours))),
                              systemImage: "hourglass")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Info pills — always show full calendar year counts
                FlowLayout(spacing: 8) {
                    if numbers.missingEntryDays > 0 {
                        TintedPill(text: tr("%lld days without entries", numbers.missingEntryDays),
                                   icon: "exclamationmark.circle.fill", color: .orange)
                            .help(tr("Working days with no time entries or full-day absence. Daily Entry lists them."))
                    }

                    TintedPill(text: tr("%lld public holidays", numbers.calendarYear.holidayDays),
                               icon: "flag.fill", color: .orange)
                        .help(tr("Full days off on your working days — e.g. Karfreitag, Weihnachten, Bundesfeier"))

                    TintedPill(text: tr("%lld half-day holidays", numbers.calendarYear.halfDayHolidays),
                               icon: "flag", color: .orange)
                        .help(tr("Half days off — Sechseläuten, Knabenschiessen, Silvester"))

                    TintedPill(text: tr("%@/%@ vacation days", TimeFormatting.days(numbers.budget.used), TimeFormatting.days(numbers.budget.available)),
                               icon: "airplane", color: numbers.budget.remaining < 0 ? .red : .blue)
                        .help(numbers.budget.carriedIn > 0
                              ? tr("Vacation days used this year, of %@ entitlement plus %@ carried over. Half-day holidays count as 0.5 days.",
                                   TimeFormatting.days(numbers.budget.entitlement), TimeFormatting.days(numbers.budget.carriedIn))
                              : tr("Vacation days used this year (Jan–Dec). Half-day holidays count as 0.5 days."))

                    ForEach(numbers.calendarYear.categoryTotals.filter { $0.category.builtIn != .vacation }) { total in
                        TintedPill(text: tr("%@: %@", total.category.name, TimeFormatting.dayCount(total.days)),
                                   icon: total.category.icon, color: total.category.color.color)
                    }
                }

                // Monthly breakdown
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Monthly Breakdown"))
                        .font(.headline)

                    MonthlyBreakdownView(months: numbers.months)
                }
            }
            .padding(24)
        }
        .navigationTitle(tr("Overview"))
        .toolbar {
            ToolbarItem {
                YearPicker(selection: $selectedYear,
                           dataYears: allSegments.map(\.date.zurichYear) + allAbsences.map(\.date.zurichYear))
            }
            .visibilityPriority(.high)

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(tr("Daily Summary…")) { exportDaily(calculator: calculator, hours: hours, numbers: numbers) }
                        .disabled(numbers.window == nil)
                    Button(tr("Time Entries…")) { exportEntries() }
                    Divider()
                    Picker(tr("Format"), selection: $preferences.csvFormat) {
                        ForEach(CSVFormat.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(tr("Export CSV"), systemImage: "square.and.arrow.up")
                }
                .help(tr("Export %@ as a CSV file", String(selectedYear)))
            }
        }
        .alert(tr("Export failed"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(tr("OK")) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func statCard(icon: String, iconColor: Color, title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(detail != nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func balanceCard(title: String, balance: Double, detail: String?) -> some View {
        let color: Color = balance >= 0 ? .green : .red
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: balance >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(TimeFormatting.signedHours(balance))
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(detail ?? (balance >= 0 ? tr("overtime") : tr("undertime")))
                .font(.caption2)
                .foregroundStyle(color.opacity(0.7))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(tint: color)
    }

    private func snapshotCard(_ title: String, _ summary: PeriodSummary) -> some View {
        let balanceColor: Color = summary.balance >= 0 ? .green : .red
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(TimeFormatting.hours(summary.actualHours))
                .font(.title3.bold().monospacedDigit())
            HStack(spacing: 4) {
                Image(systemName: summary.balance >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2)
                Text(tr("%@ vs %@", TimeFormatting.signedHours(summary.balance), TimeFormatting.hours(summary.expectedHours)))
                    .font(.caption2)
                    .monospacedDigit()
            }
            .foregroundStyle(balanceColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: - CSV export

    /// Day-by-day report for the selected year, clamped to the tracking window and today.
    private func exportDaily(calculator: WorkHoursCalculator, hours: [Date: Double], numbers: OverviewNumbers) {
        guard let window = numbers.window else { return }
        let days = window.start.daysThrough(window.end).map(calculator.classify(date:))
        let csv = CSVExporter(format: preferences.csvFormat).dailyReport(days: days, hours: hours)
        save(csv, name: "WorkTracker-\(selectedYear)-\(tr("daily")).csv")
    }

    /// Every time entry in the selected year.
    private func exportEntries() {
        let segments = allSegments.filter { $0.date.zurichYear == selectedYear }
        let csv = CSVExporter(format: preferences.csvFormat).entries(segments)
        save(csv, name: "WorkTracker-\(selectedYear)-\(tr("entries")).csv")
    }

    private func save(_ csv: String, name: String) {
        let panel = NSSavePanel()
        panel.title = tr("Export Time Report")
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }
}
