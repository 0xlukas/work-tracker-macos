import Foundation
import SwiftData

/// An absence as the calculator sees it: which category (with its counting rule) and
/// whether only half the day was taken.
struct AbsenceEntry: Equatable {
    let category: CategoryDetails
    let isHalfDay: Bool

    init(category: CategoryDetails, isHalfDay: Bool) {
        self.category = category
        self.isHalfDay = isHalfDay
    }

    init(type: AbsenceType, isHalfDay: Bool) {
        self.init(category: type.details, isHalfDay: isHalfDay)
    }
}

struct DaySummary {
    let date: Date
    /// Contract hours for this weekday before holidays and absences.
    let scheduledHours: Double
    let expectedHours: Double
    /// Public holiday on this (week)day, if any.
    let holiday: Holiday?
    /// The absence that counts on this day. Nil on days without scheduled work and on
    /// full-day holidays, where an absence changes nothing.
    let absence: AbsenceEntry?
    /// 0, 0.5 or 1 — half on half-day holidays or for half-day absences.
    let absenceDays: Double
    /// Vacation days beyond the year's allowance; these get no time credit.
    let uncreditedDays: Double

    var isWeekend: Bool { date.isWeekend }
    var isHalfDayHoliday: Bool { holiday?.type == .halfDay }
    var isFullDayHoliday: Bool { holiday?.type == .fullDay }
    var category: CategoryDetails? { absence?.category }
    var isHalfDayAbsence: Bool { absence != nil && absenceDays == 0.5 }
    var isOverAllowance: Bool { uncreditedDays > 0 }
}

struct CategoryTotal: Identifiable {
    let category: CategoryDetails
    var days: Double
    var id: String { category.id }
}

struct PeriodSummary {
    var expectedHours: Double = 0
    var actualHours: Double = 0
    var balance: Double { actualHours - expectedHours }
    /// Days with any expected work.
    var workingDays = 0
    /// Full-day holidays on scheduled working days.
    var holidayDays = 0
    var halfDayHolidays = 0
    /// Days of every category that occurred, built-ins first, then custom by name.
    var categoryTotals: [CategoryTotal] = []
    /// All days counted against the vacation allowance (built-in and custom).
    var vacationDays: Double = 0

    static let empty = PeriodSummary()

    func days(for type: AbsenceType) -> Double {
        categoryTotals.first { $0.category.builtIn == type }?.days ?? 0
    }

    var sickDays: Double { days(for: .sick) }
    var serviceDays: Double { days(for: .service) }
    var customCategoryTotals: [CategoryTotal] { categoryTotals.filter { $0.category.builtIn == nil } }
}

/// Vacation allowance for one calendar year.
struct VacationBudget: Equatable {
    let entitlement: Double
    let carriedIn: Double
    let used: Double
    var available: Double { entitlement + carriedIn }
    var remaining: Double { available - used }
}

struct MonthSummary: Identifiable {
    let year: Int
    let month: Int
    let expectedHours: Double
    let actualHours: Double
    var balance: Double { actualHours - expectedHours }

    var id: String { "\(year)-\(month)" }

    var monthName: String {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        return formatter.standaloneMonthSymbols[month - 1].capitalized(with: Localization.locale)
    }
}

struct ProjectHours: Identifiable {
    let project: Project
    let hours: Double
    var id: PersistentIdentifier { project.persistentModelID }
}

/// Expected hours per day from the work schedule, Zurich public holidays and absences.
/// Build one per screen update — it precomputes the vacation allowance for every year.
struct WorkHoursCalculator {
    let absences: [Date: AbsenceEntry]
    let schedule: WorkSchedule
    let allowance: VacationAllowance

    private let holidays = HolidayCalendar.shared
    /// Vacation days (0.5/1) beyond the allowance, by day.
    private var uncredited: [Date: Double] = [:]
    private var budgets: [Int: VacationBudget] = [:]

    init(absences: [Date: AbsenceEntry], schedule: WorkSchedule = .standard,
         allowance: VacationAllowance = VacationAllowance()) {
        self.absences = absences
        self.schedule = schedule
        self.allowance = allowance
        computeAllowance()
    }

    // MARK: - Vacation allowance

    /// Walk each year's vacation days in date order; once the allowance (entitlement plus
    /// any carry-over) is used up, later days stop earning time credit. Every period —
    /// a day, a month or all-time — then sees the same per-day result.
    private mutating func computeAllowance() {
        var byYear: [Int: [(date: Date, days: Double)]] = [:]
        for (date, entry) in absences where entry.category.rule == .vacation {
            let days = countedDays(on: date, entry: entry)
            if days > 0 { byYear[date.zurichYear, default: []].append((date, days)) }
        }

        let first = min(allowance.startYear, byYear.keys.min() ?? allowance.startYear)
        let last = max(allowance.startYear, byYear.keys.max() ?? allowance.startYear, Date().zurichYear + 1)
        var carry = 0.0
        for year in first...last {
            let carriedIn: Double
            if year == allowance.startYear { carriedIn = allowance.openingCarryOver }
            else if year > allowance.startYear && allowance.carryOver { carriedIn = carry }
            else { carriedIn = 0 }

            let available = allowance.entitlement + carriedIn
            var remaining = available
            var used = 0.0
            for item in (byYear[year] ?? []).sorted(by: { $0.date < $1.date }) {
                let credited = min(item.days, max(0, remaining))
                if item.days > credited { uncredited[item.date] = item.days - credited }
                remaining -= item.days
                used += item.days
            }
            budgets[year] = VacationBudget(entitlement: allowance.entitlement, carriedIn: carriedIn, used: used)
            carry = max(0, available - used)
        }
    }

    func vacationBudget(year: Int) -> VacationBudget {
        budgets[year] ?? VacationBudget(entitlement: allowance.entitlement, carriedIn: 0, used: 0)
    }

    // MARK: - Days

    /// How many days an absence counts on `date`: 0 without scheduled work or on a
    /// full-day holiday, 0.5 on a half-day holiday or for a half day, else 1.
    private func countedDays(on date: Date, entry: AbsenceEntry) -> Double {
        let day = date.startOfDayZurich
        guard schedule.hours(on: day) > 0 else { return 0 }
        switch holidays.holiday(on: day)?.type {
        case .fullDay: return 0
        case .halfDay: return 0.5
        case nil: return entry.isHalfDay ? 0.5 : 1
        }
    }

    /// Whether an absence can be recorded on `date` (a scheduled day that isn't a full holiday).
    func isAbsenceEligible(_ date: Date) -> Bool {
        schedule.hours(on: date) > 0 && holidays.holiday(on: date)?.type != .fullDay
    }

    func classify(date: Date) -> DaySummary {
        let day = date.startOfDayZurich
        let scheduled = schedule.hours(on: day)
        let holiday = holidays.holiday(on: day)

        guard scheduled > 0, holiday?.type != .fullDay else {
            return DaySummary(date: day, scheduledHours: scheduled, expectedHours: 0, holiday: holiday,
                              absence: nil, absenceDays: 0, uncreditedDays: 0)
        }

        let base = holiday?.type == .halfDay ? scheduled / 2 : scheduled
        guard let entry = absences[day] else {
            return DaySummary(date: day, scheduledHours: scheduled, expectedHours: base, holiday: holiday,
                              absence: nil, absenceDays: 0, uncreditedDays: 0)
        }

        let days = countedDays(on: day, entry: entry)
        let over = entry.category.rule == .vacation ? (uncredited[day] ?? 0) : 0
        let creditedDays: Double
        switch entry.category.rule {
        case .reduceHours: creditedDays = days
        case .vacation: creditedDays = days - over
        case .unchanged: creditedDays = 0
        }
        return DaySummary(date: day, scheduledHours: scheduled,
                          expectedHours: max(0, base - creditedDays * scheduled), holiday: holiday,
                          absence: entry, absenceDays: days, uncreditedDays: over)
    }

    /// A working day with nothing logged: work was expected, no time was entered and no
    /// full-day absence covers it. Full-day absences count as logged even when they grant
    /// no time credit (over the allowance, or "leave expected hours unchanged").
    func isMissingEntries(_ summary: DaySummary, hours: Double) -> Bool {
        summary.expectedHours > 0 && hours <= 0 && !(summary.absence != nil && summary.absenceDays >= 1)
    }

    /// Days in `from…to` (inclusive) with missing entries, most recent first.
    func missingEntryDays(from: Date, to: Date, hours: [Date: Double]) -> [Date] {
        guard from <= to else { return [] }
        return from.startOfDayZurich.daysThrough(to.startOfDayZurich)
            .filter { isMissingEntries(classify(date: $0), hours: hours[$0] ?? 0) }
            .reversed()
    }

    // MARK: - Periods

    /// Totals for `from…to` (inclusive). `hours` is worked hours per Zurich day.
    func periodSummary(from: Date, to: Date, hours: [Date: Double]) -> PeriodSummary {
        var summary = PeriodSummary()
        var totals: [String: CategoryTotal] = [:]

        for day in from.startOfDayZurich.daysThrough(to.startOfDayZurich) {
            let result = classify(date: day)
            summary.expectedHours += result.expectedHours
            summary.actualHours += hours[day] ?? 0
            if result.expectedHours > 0 { summary.workingDays += 1 }
            if result.scheduledHours > 0 {
                if result.isFullDayHoliday { summary.holidayDays += 1 }
                if result.isHalfDayHoliday { summary.halfDayHolidays += 1 }
            }
            if let absence = result.absence {
                totals[absence.category.id, default: CategoryTotal(category: absence.category, days: 0)].days += result.absenceDays
                if absence.category.rule == .vacation { summary.vacationDays += result.absenceDays }
            }
        }

        summary.categoryTotals = totals.values.sorted { lhs, rhs in
            switch (lhs.category.builtIn, rhs.category.builtIn) {
            case let (l?, r?):
                return AbsenceType.builtIns.firstIndex(of: l)! < AbsenceType.builtIns.firstIndex(of: r)!
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.category.name.localizedStandardCompare(rhs.category.name) == .orderedAscending
            }
        }
        return summary
    }

    /// Monthly breakdown clamped to [startDate, endDate].
    /// Months entirely outside the range get 0/0. Partial months are clipped.
    func monthlyBreakdown(year: Int, hours: [Date: Double],
                          startDate: Date? = nil, endDate: Date? = nil) -> [MonthSummary] {
        let cal = Calendar.zurich
        return (1...12).map { month in
            var monthStart = cal.zurichDate(year: year, month: month, day: 1)
            let lastDay = cal.range(of: .day, in: .month, for: monthStart)!.upperBound - 1
            var monthEnd = cal.zurichDate(year: year, month: month, day: lastDay)

            if let s = startDate?.startOfDayZurich { monthStart = max(monthStart, s) }
            if let e = endDate?.startOfDayZurich { monthEnd = min(monthEnd, e) }

            guard monthStart <= monthEnd else {
                return MonthSummary(year: year, month: month, expectedHours: 0, actualHours: 0)
            }
            let summary = periodSummary(from: monthStart, to: monthEnd, hours: hours)
            return MonthSummary(year: year, month: month,
                                expectedHours: summary.expectedHours, actualHours: summary.actualHours)
        }
    }

    /// Hours per project in `from…to`, largest first. Grouped by project identity, so two
    /// projects with the same name stay separate.
    static func projectBreakdown(from: Date, to: Date, segments: [WorkSegment]) -> [ProjectHours] {
        let start = from.startOfDayZurich, end = to.startOfDayZurich
        var totals: [PersistentIdentifier: (project: Project, hours: Double)] = [:]
        for segment in segments {
            guard let project = segment.project else { continue }
            let day = segment.date.startOfDayZurich
            guard day >= start && day <= end else { continue }
            totals[project.persistentModelID, default: (project, 0)].hours += segment.durationHours
        }
        return totals.values
            .map { ProjectHours(project: $0.project, hours: $0.hours) }
            .sorted { $0.hours > $1.hours }
    }
}
