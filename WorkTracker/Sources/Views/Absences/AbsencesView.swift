import SwiftUI
import SwiftData

struct AbsencesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Preferences.self) private var preferences
    @Query(sort: \VacationDay.date) private var allAbsences: [VacationDay]
    @Query(sort: \AbsenceCategory.name) private var categories: [AbsenceCategory]

    @State private var selectedYear = Date().zurichYear
    @State private var lastClickedDate: Date?
    @State private var mode = AbsenceType.vacation.rawValue
    @State private var showCategories = false

    private var activeCategories: [AbsenceCategory] { categories.filter { !$0.isArchived } }

    private var selection: AbsenceSelection {
        if let category = activeCategories.first(where: { $0.id.uuidString == mode }) { return .custom(category) }
        return .builtIn(AbsenceType(rawValue: mode) ?? .vacation)
    }

    private var absencesForYear: [VacationDay] {
        allAbsences.filter { $0.date.zurichYear == selectedYear }
    }

    var body: some View {
        let calculator = preferences.calculator(absences: VacationDay.lookup(allAbsences))
        let yearStart = Calendar.zurich.zurichDate(year: selectedYear, month: 1, day: 1)
        let yearEnd = Calendar.zurich.zurichDate(year: selectedYear, month: 12, day: 31)
        let summary = calculator.periodSummary(from: yearStart, to: yearEnd, hours: [:])
        let budget = calculator.vacationBudget(year: selectedYear)
        let absences = Dictionary(absencesForYear.map { ($0.date.startOfDayZurich, $0) }, uniquingKeysWith: { first, _ in first })
        let eligible = yearStart.daysThrough(yearEnd).filter { calculator.isAbsenceEligible($0) }

        VStack(alignment: .leading, spacing: 0) {
            // Header: budget/counter for the selected type + how the grid works
            HStack(alignment: .top, spacing: 16) {
                counterCard(summary: summary, budget: budget)

                Spacer(minLength: 0)

                Label {
                    Text(LocalizedStringKey(tr("Click: full day → half day → remove. **Shift+click** to select a range. Click another absence to convert it to the selected type.")))
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .cardSurface(tint: .accentColor, radius: Surface.rowRadius)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(monthGroups(eligible), id: \.month) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.name)
                                .font(.subheadline.bold())

                            FlowLayout(spacing: 3) {
                                ForEach(group.days, id: \.self) { date in
                                    let day = calculator.classify(date: date)
                                    DayCell(
                                        date: date,
                                        absence: absences[date],
                                        isHalfDayHoliday: day.isHalfDayHoliday,
                                        isOverAllowance: day.isOverAllowance,
                                        isLastClicked: lastClickedDate == date
                                    ) { isShift in
                                        handleClick(date, shift: isShift, absences: absencesForYear, eligible: Set(eligible))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(tr("Absences"))
        .toolbar {
            ToolbarItem {
                YearPicker(selection: $selectedYear, dataYears: allAbsences.map(\.date.zurichYear))
            }
            .visibilityPriority(.high)

            ToolbarSpacer(.fixed)

            ToolbarItem {
                Picker(tr("Category"), selection: $mode) {
                    ForEach(AbsenceType.builtIns, id: \.rawValue) { type in
                        Label(type.details.name, systemImage: type.details.icon).tag(type.rawValue)
                    }
                    ForEach(activeCategories) { category in
                        Label(category.name, systemImage: category.icon).tag(category.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .help(tr("Category"))
            }
            .visibilityPriority(.high)

            ToolbarItem {
                Button {
                    showCategories = true
                } label: {
                    Label(tr("Manage Categories…"), systemImage: "slider.horizontal.3")
                }
                .help(tr("Manage Categories…"))
            }
        }
        .sheet(isPresented: $showCategories) { CategoryManagerView() }
        .onChange(of: activeCategories.map(\.id)) { _, ids in
            if AbsenceType(rawValue: mode) == nil && !ids.contains(where: { $0.uuidString == mode }) {
                mode = AbsenceType.vacation.rawValue
            }
        }
    }

    private func monthGroups(_ days: [Date]) -> [(month: Int, name: String, days: [Date])] {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        let grouped = Dictionary(grouping: days) { Calendar.zurich.component(.month, from: $0) }
        return grouped.sorted { $0.key < $1.key }.map { month, days in
            (month, formatter.standaloneMonthSymbols[month - 1].capitalized(with: Localization.locale), days.sorted())
        }
    }

    /// Vacation shows the budget (used / available); other types show the year's count.
    private func counterCard(summary: PeriodSummary, budget: VacationBudget) -> some View {
        let details = selection.details
        let isVacationMode = details.rule == .vacation
        let overBudget = isVacationMode && budget.remaining < 0
        let count = summary.categoryTotals.first { $0.id == details.id }?.days ?? 0

        return HStack(spacing: 12) {
            Image(systemName: details.icon)
                .font(.title3)
                .foregroundStyle(overBudget ? .red : details.color.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                if isVacationMode {
                    Text(tr("%@ / %@ days", TimeFormatting.days(budget.used), TimeFormatting.days(budget.available)))
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(overBudget ? .red : .primary)
                    Group {
                        if budget.remaining >= 0 {
                            Text(tr("%@ remaining", TimeFormatting.days(budget.remaining)))
                        } else {
                            Text(tr("%@ over budget — those days count as working days", TimeFormatting.days(-budget.remaining)))
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if budget.carriedIn > 0 {
                        Text(tr("incl. %@ carried over", TimeFormatting.dayCount(budget.carriedIn)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if details.builtIn == nil {
                        Text(tr("%@: %@ this year", details.name, TimeFormatting.dayCount(count)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(tr("%@: %@", details.name, TimeFormatting.dayCount(count)))
                        .font(.title3.bold().monospacedDigit())
                    Text(tr("this year"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cardSurface(tint: overBudget ? .red : nil)
    }

    // MARK: - Actions

    private func handleClick(_ date: Date, shift: Bool, absences: [VacationDay], eligible: Set<Date>) {
        let editor = AbsenceEditor(context: modelContext, absences: absences)
        let day = date.startOfDayZurich
        if shift, let anchor = lastClickedDate {
            let range = min(anchor, day).daysThrough(max(anchor, day)).filter(eligible.contains)
            editor.fill(range, selection: selection)
        } else {
            editor.click(day, selection: selection)
        }
        lastClickedDate = day
    }
}

// MARK: - Year picker

/// Year menu covering every year with data, the tracking start, and next year.
struct YearPicker: View {
    @Environment(Preferences.self) private var preferences
    @Binding var selection: Int
    let dataYears: [Int]

    var body: some View {
        let current = Date().zurichYear
        let low = min(dataYears.min() ?? current, preferences.trackingStartDate.zurichYear, current, selection)
        let high = max(dataYears.max() ?? current, current + 1, selection)
        Picker(tr("Year"), selection: $selection) {
            ForEach(Array(low...high).reversed(), id: \.self) { year in
                Text(String(year)).tag(year)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(tr("Year"))
    }
}
