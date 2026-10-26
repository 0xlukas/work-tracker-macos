import XCTest
@testable import WorkTracker

final class CalculatorTests: XCTestCase {
    // 2026: 22 Sep = Tuesday, 26 Sep = Saturday, 25 Dec = Friday (full holiday),
    // 31 Dec = Thursday (Silvester, half day).
    let regular = day(9, 22)
    let saturday = day(9, 26)
    let christmas = day(12, 25)
    let silvester = day(12, 31)

    private func summary(_ date: Date, _ absence: AbsenceEntry?) -> PeriodSummary {
        let calculator = WorkHoursCalculator(absences: absence.map { [date: $0] } ?? [:])
        return calculator.periodSummary(from: date, to: date, hours: [:])
    }

    func testPlainDays() {
        XCTAssertEqual(summary(regular, nil).expectedHours, 8)
        XCTAssertEqual(summary(saturday, nil).expectedHours, 0)
        XCTAssertEqual(summary(christmas, nil).expectedHours, 0)
        XCTAssertEqual(summary(christmas, nil).holidayDays, 1)
        XCTAssertEqual(summary(silvester, nil).expectedHours, 4)
        XCTAssertEqual(summary(silvester, nil).halfDayHolidays, 1)
    }

    /// Every built-in and custom rule on a regular day, a half-day holiday, a full holiday
    /// and a weekend — one code path for all categories.
    func testRulesAcrossDayKinds() {
        let makers: [(AbsenceCountingRule, (Bool) -> AbsenceEntry)] = [
            (.vacation, { entry(.vacation, half: $0) }),
            (.reduceHours, { entry(.sick, half: $0) }),
            (.reduceHours, { entry(.service, half: $0) }),
            (.reduceHours, { entry(.unpaid, half: $0) }),
            (.reduceHours, { custom(.reduceHours, half: $0) }),
            (.vacation, { custom(.vacation, half: $0) }),
            (.unchanged, { custom(.unchanged, half: $0) }),
        ]
        for (rule, make) in makers {
            for half in [false, true] {
                for (date, base) in [(regular, 8.0), (silvester, 4.0), (christmas, 0.0), (saturday, 0.0)] {
                    let absence = make(half)
                    let result = summary(date, absence)
                    let count = base == 0 ? 0 : (half || base == 4 ? 0.5 : 1)
                    let expected = rule == .unchanged ? base : max(0, base - count * 8)
                    XCTAssertEqual(result.expectedHours, expected, "\(absence.category.name) half=\(half) base=\(base)")
                    XCTAssertEqual(result.categoryTotals.first?.days ?? 0, count, "\(absence.category.name) half=\(half) base=\(base)")
                    XCTAssertEqual(result.vacationDays, rule == .vacation ? count : 0)
                }
            }
        }
    }

    /// Sick on a half-day holiday now counts half a day, like every other category.
    func testSickOnHalfDayHolidayCountsHalf() {
        XCTAssertEqual(summary(silvester, entry(.sick)).sickDays, 0.5)
        XCTAssertEqual(summary(silvester, entry(.sick, half: true)).sickDays, 0.5)
        XCTAssertEqual(summary(silvester, entry(.sick)).expectedHours, 0)
    }

    /// Working days with nothing logged; weekends, holidays and full-day absences (even
    /// uncredited ones) are covered, a half-day absence alone is not.
    func testMissingEntryDays() {
        // 21 Dec 2026 is a Monday; 24–26 are holidays, then Sunday and Monday 28.
        let calculator = WorkHoursCalculator(absences: [
            day(12, 21): custom(.unchanged),
            day(12, 22): entry(.vacation, half: true),
        ])
        let hours = [day(12, 23): 8.0]
        XCTAssertEqual(calculator.missingEntryDays(from: day(12, 21), to: day(12, 28), hours: hours),
                       [day(12, 28), day(12, 22)])
        XCTAssertEqual(calculator.missingEntryDays(from: day(12, 28), to: day(12, 21), hours: hours), [])
    }

    func testServiceLongRange() {
        let days = day(6, 1).daysThrough(day(7, 31))
        let lookup = Dictionary(uniqueKeysWithValues: days.map { ($0, entry(.service)) })
        let result = WorkHoursCalculator(absences: lookup).periodSummary(from: days.first!, to: days.last!, hours: [:])
        XCTAssertGreaterThan(result.serviceDays, 25)
        XCTAssertEqual(result.expectedHours, 0)
        XCTAssertEqual(result.vacationDays, 0)
    }

    func testActualHoursAndBalance() {
        let hours = [regular: 9.5, regular.addingDays(1): 7.0]
        let result = WorkHoursCalculator(absences: [:]).periodSummary(from: regular, to: regular.addingDays(1), hours: hours)
        XCTAssertEqual(result.actualHours, 16.5)
        XCTAssertEqual(result.balance, 0.5)
        XCTAssertEqual(result.workingDays, 2)
    }

    func testCategoryTotalsOrderBuiltInsFirst() {
        let calculator = WorkHoursCalculator(absences: [
            day(9, 21): custom(.reduceHours, name: "Alpha"),
            day(9, 22): entry(.service),
            day(9, 23): entry(.vacation),
            day(9, 24): entry(.sick),
            day(9, 25): entry(.unpaid),
        ])
        let totals = calculator.periodSummary(from: day(9, 21), to: day(9, 25), hours: [:]).categoryTotals
        XCTAssertEqual(totals.map(\.category.name), [tr("Vacation"), tr("Sick"), tr("Public Service"), tr("Unpaid Leave"), "Alpha"])
    }
}

final class AllowanceTests: XCTestCase {
    private func vacation(on days: [Date]) -> [Date: AbsenceEntry] {
        Dictionary(uniqueKeysWithValues: days.map { ($0, entry(.vacation)) })
    }

    /// 20 vacation days in 2026 and 20 in 2027 stay within each year's 25 days.
    /// The old code compared 40 against a single 25 and added 120 hours.
    func testAllowanceIsPerYear() {
        let days2026 = day(2026, 3, 2).daysThrough(day(2026, 3, 27)).filter { !$0.isWeekend }
        let days2027 = day(2027, 6, 7).daysThrough(day(2027, 7, 2)).filter { !$0.isWeekend }
        XCTAssertEqual(days2026.count, 20)
        XCTAssertEqual(days2027.count, 20)
        let calculator = WorkHoursCalculator(absences: vacation(on: days2026 + days2027),
                                             allowance: VacationAllowance(entitlement: 25, startYear: 2026))
        let allTime = calculator.periodSummary(from: day(2026, 1, 1), to: day(2027, 12, 31), hours: [:])
        let normal = WorkHoursCalculator(absences: [:]).periodSummary(from: day(2026, 1, 1), to: day(2027, 12, 31), hours: [:])
        XCTAssertEqual(allTime.expectedHours, normal.expectedHours - 40 * 8)
        XCTAssertEqual(calculator.vacationBudget(year: 2026).remaining, 5)
    }

    /// Days beyond the allowance lose their credit on those specific days, so months add
    /// up to the year.
    func testOverAllowanceDaysAndMonthsSumToYear() {
        let days = day(2026, 3, 2).daysThrough(day(2026, 3, 13)).filter { !$0.isWeekend } // 10 days
        let calculator = WorkHoursCalculator(absences: vacation(on: days),
                                             allowance: VacationAllowance(entitlement: 7.5, startYear: 2026))
        XCTAssertFalse(calculator.classify(date: days[6]).isOverAllowance)
        let boundary = calculator.classify(date: days[7])
        XCTAssertEqual(boundary.uncreditedDays, 0.5)
        XCTAssertEqual(boundary.expectedHours, 4)
        XCTAssertEqual(calculator.classify(date: days[9]).expectedHours, 8)

        let year = calculator.periodSummary(from: day(2026, 1, 1), to: day(2026, 12, 31), hours: [:])
        let months = calculator.monthlyBreakdown(year: 2026, hours: [:])
        XCTAssertEqual(months.reduce(0) { $0 + $1.expectedHours }, year.expectedHours, accuracy: 0.001)
        let normal = WorkHoursCalculator(absences: [:]).periodSummary(from: day(2026, 1, 1), to: day(2026, 12, 31), hours: [:])
        XCTAssertEqual(year.expectedHours, normal.expectedHours - 7.5 * 8)
    }

    func testCustomVacationSharesAllowance() {
        let calculator = WorkHoursCalculator(absences: [
            day(9, 22): entry(.vacation),
            day(9, 23): custom(.vacation, name: "Extra leave"),
        ], allowance: VacationAllowance(entitlement: 1, startYear: 2026))
        let summary = calculator.periodSummary(from: day(9, 22), to: day(9, 23), hours: [:])
        XCTAssertEqual(summary.vacationDays, 2)
        XCTAssertEqual(summary.expectedHours, 8)
    }

    func testCarryOverAndOpeningCarry() {
        let days2026 = day(2026, 3, 2).daysThrough(day(2026, 3, 13)).filter { !$0.isWeekend } // 10
        let allowance = VacationAllowance(entitlement: 20, carryOver: true, openingCarryOver: 3, startYear: 2026)
        let calculator = WorkHoursCalculator(absences: vacation(on: days2026), allowance: allowance)
        XCTAssertEqual(calculator.vacationBudget(year: 2026), VacationBudget(entitlement: 20, carriedIn: 3, used: 10))
        XCTAssertEqual(calculator.vacationBudget(year: 2027).carriedIn, 13)

        var noCarry = allowance
        noCarry.carryOver = false
        XCTAssertEqual(WorkHoursCalculator(absences: vacation(on: days2026), allowance: noCarry).vacationBudget(year: 2027).carriedIn, 0)
    }

    func testNoCarryIntoYearsBeforeTracking() {
        let allowance = VacationAllowance(entitlement: 20, carryOver: true, startYear: 2026)
        let calculator = WorkHoursCalculator(absences: vacation(on: [day(2025, 3, 3)]), allowance: allowance)
        XCTAssertEqual(calculator.vacationBudget(year: 2025).carriedIn, 0)
        XCTAssertEqual(calculator.vacationBudget(year: 2026).carriedIn, 0)
    }
}

final class HolidayTests: XCTestCase {
    func testEasterDates() {
        let known: [Int: (Int, Int)] = [2024: (3, 31), 2025: (4, 20), 2026: (4, 5), 2027: (3, 28), 2038: (4, 25), 2045: (4, 9)]
        for (year, (month, date)) in known {
            XCTAssertEqual(ZurichHolidays.easterSunday(year: year), day(year, month, date), "Easter \(year)")
        }
    }

    /// Sechseläuten moves to the 4th Monday when the 3rd is Easter Monday (e.g. 2025, 2028).
    func testSechselaeutenShift() {
        func sechselaeuten(_ year: Int) -> Date? {
            ZurichHolidays.holidays(for: year).first { $0.name == "Sechseläuten" }?.date
        }
        XCTAssertEqual(sechselaeuten(2025), day(2025, 4, 28)) // Easter Monday 21 Apr
        XCTAssertEqual(sechselaeuten(2026), day(2026, 4, 20))
        XCTAssertEqual(sechselaeuten(2028), day(2028, 4, 24)) // Easter Monday 17 Apr
    }

    func testKnabenschiessen() {
        XCTAssertEqual(ZurichHolidays.knabenschiessen(year: 2026), day(2026, 9, 14))
        XCTAssertEqual(ZurichHolidays.knabenschiessen(year: 2027), day(2027, 9, 13))
    }

    /// Holidays exist for any year, not just 2026–2036.
    func testHolidaysOutsideOldRange() {
        let calculator = WorkHoursCalculator(absences: [:])
        XCTAssertEqual(calculator.classify(date: day(2025, 12, 25)).expectedHours, 0)
        XCTAssertEqual(calculator.classify(date: day(2040, 12, 25)).expectedHours, 0)
        XCTAssertEqual(calculator.classify(date: day(2040, 12, 31)).expectedHours, 4)
        XCTAssertEqual(HolidayCalendar.shared.holiday(on: day(2050, 8, 1))?.name, "Bundesfeier")
    }

    func testWeekendHolidaysOnlyCountWhenScheduled() {
        // 1 Aug 2026 is a Saturday.
        let bundesfeier = day(2026, 8, 1)
        XCTAssertEqual(HolidayCalendar.shared.holiday(on: bundesfeier)?.name, "Bundesfeier")

        let standard = WorkHoursCalculator(absences: [:])
        XCTAssertEqual(standard.periodSummary(from: bundesfeier, to: bundesfeier, hours: [:]).holidayDays, 0)

        var period = WorkSchedule.Period.weekdays(effectiveFrom: .distantPast)
        period.hours[5] = 4 // works Saturday mornings
        let saturdays = WorkHoursCalculator(absences: [:], schedule: WorkSchedule(periods: [period]))
        XCTAssertEqual(saturdays.classify(date: bundesfeier).expectedHours, 0)
        XCTAssertEqual(saturdays.periodSummary(from: bundesfeier, to: bundesfeier, hours: [:]).holidayDays, 1)
        XCTAssertEqual(saturdays.classify(date: day(2026, 8, 8)).expectedHours, 4)
    }
}

final class OverviewTests: XCTestCase {
    /// Tracking started on Friday 25 Sep 2026: this week and month expect only that day.
    func testPeriodsStartAtTrackingStart() {
        let start = day(9, 25)
        let numbers = OverviewNumbers(calculator: WorkHoursCalculator(absences: [:]),
                                      hours: [start: 3.25], year: 2026, trackingStart: start, now: time(start, 17))
        XCTAssertEqual(numbers.today.expectedHours, 8)
        XCTAssertEqual(numbers.week.expectedHours, 8)
        XCTAssertEqual(numbers.month.expectedHours, 8)
        XCTAssertEqual(numbers.week.balance, -4.75, accuracy: 0.0001)
    }

    func testTodayBeforeTrackingStartExpectsNothing() {
        let numbers = OverviewNumbers(calculator: WorkHoursCalculator(absences: [:]),
                                      hours: [:], year: 2026, trackingStart: day(9, 28), now: time(day(9, 25), 12))
        XCTAssertEqual(numbers.today.expectedHours, 0)
        XCTAssertEqual(numbers.week.expectedHours, 0)
    }
}

final class ScheduleTests: XCTestCase {
    func testPartTimeScheduleHistory() {
        var schedule = WorkSchedule.standard
        var partTime = WorkSchedule.Period.weekdays(effectiveFrom: day(2027, 1, 1), percent: 80)
        partTime.hours[4] = 0 // Fridays off
        partTime.hours[0] = 8
        schedule.upsert(partTime)

        let calculator = WorkHoursCalculator(absences: [:], schedule: schedule)
        XCTAssertEqual(calculator.classify(date: day(2026, 12, 18)).expectedHours, 8)   // Fri, old schedule
        XCTAssertEqual(calculator.classify(date: day(2027, 1, 8)).expectedHours, 0)     // Fri, new schedule
        XCTAssertEqual(calculator.classify(date: day(2027, 1, 4)).expectedHours, 8)     // Mon
        XCTAssertEqual(calculator.classify(date: day(2027, 1, 5)).expectedHours, 6.4)   // Tue
    }

    func testHalfDaysUseScheduledHours() {
        let schedule = WorkSchedule(periods: [.weekdays(effectiveFrom: .distantPast, percent: 60)]) // 4.8 h/day
        let calculator = WorkHoursCalculator(absences: [day(9, 22): entry(.vacation, half: true)], schedule: schedule)
        XCTAssertEqual(calculator.classify(date: day(9, 22)).expectedHours, 2.4, accuracy: 0.0001)
        XCTAssertEqual(calculator.classify(date: day(12, 31)).expectedHours, 2.4, accuracy: 0.0001) // Silvester
    }

    func testAbsenceOnDayOffIsIgnored() {
        var period = WorkSchedule.Period.weekdays(effectiveFrom: .distantPast)
        period.hours[4] = 0
        let calculator = WorkHoursCalculator(absences: [day(9, 25): entry(.vacation)], schedule: WorkSchedule(periods: [period]))
        XCTAssertFalse(calculator.isAbsenceEligible(day(9, 25)))
        XCTAssertEqual(calculator.periodSummary(from: day(9, 25), to: day(9, 25), hours: [:]).vacationDays, 0)
    }

    func testFirstPeriodCoversEarlierDates() {
        let schedule = WorkSchedule(periods: [.weekdays(effectiveFrom: day(2026, 6, 1), percent: 50)])
        XCTAssertEqual(schedule.hours(on: day(2020, 1, 6)), 4)
    }
}
