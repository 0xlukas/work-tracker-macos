import Foundation

enum HolidayType {
    case fullDay  // no work expected
    case halfDay  // half the scheduled hours expected
}

struct Holiday: Equatable {
    let name: String
    let date: Date
    let type: HolidayType
}

/// Zurich public holidays, computed from their definitions for any year.
enum ZurichHolidays {
    /// Compute Easter Sunday for a given year using the Anonymous Gregorian algorithm.
    static func easterSunday(year: Int) -> Date {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return Calendar.zurich.zurichDate(year: year, month: month, day: day)
    }

    /// All Zurich public holidays for a given year (including ones on weekends).
    static func holidays(for year: Int) -> [Holiday] {
        let easter = easterSunday(year: year)
        let date = { (month: Int, day: Int) in Calendar.zurich.zurichDate(year: year, month: month, day: day) }
        let easterMonday = easter.addingDays(1)

        return [
            // Fixed full-day holidays
            Holiday(name: "Neujahr", date: date(1, 1), type: .fullDay),
            Holiday(name: "Berchtoldstag", date: date(1, 2), type: .fullDay),
            Holiday(name: "Tag der Arbeit", date: date(5, 1), type: .fullDay),
            Holiday(name: "Bundesfeier", date: date(8, 1), type: .fullDay),
            Holiday(name: "Heiligabend", date: date(12, 24), type: .fullDay),
            Holiday(name: "Weihnachten", date: date(12, 25), type: .fullDay),
            Holiday(name: "Stephanstag", date: date(12, 26), type: .fullDay),
            // Easter-based full-day holidays
            Holiday(name: "Karfreitag", date: easter.addingDays(-2), type: .fullDay),
            Holiday(name: "Ostermontag", date: easterMonday, type: .fullDay),
            Holiday(name: "Auffahrt", date: easter.addingDays(39), type: .fullDay),
            Holiday(name: "Pfingstmontag", date: easter.addingDays(50), type: .fullDay),
            // Half-day holidays
            Holiday(name: "Sechseläuten", date: sechselaeuten(year: year, easterMonday: easterMonday), type: .halfDay),
            Holiday(name: "Knabenschiessen", date: knabenschiessen(year: year), type: .halfDay),
            Holiday(name: "Silvester", date: date(12, 31), type: .halfDay),
        ]
    }

    /// 3rd Monday of April. If it coincides with Easter Monday, moves to 4th Monday.
    static func sechselaeuten(year: Int, easterMonday: Date) -> Date {
        let thirdMonday = nthWeekday(nth: 3, weekday: 2, month: 4, year: year) // weekday 2 = Monday
        if thirdMonday.isSameDay(as: easterMonday) {
            return nthWeekday(nth: 4, weekday: 2, month: 4, year: year)
        }
        return thirdMonday
    }

    /// Monday after the 2nd Sunday of September.
    static func knabenschiessen(year: Int) -> Date {
        nthWeekday(nth: 2, weekday: 1, month: 9, year: year).addingDays(1) // weekday 1 = Sunday
    }

    /// Returns the nth occurrence of a weekday in a given month/year.
    /// weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
    private static func nthWeekday(nth: Int, weekday: Int, month: Int, year: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.weekday = weekday
        components.weekdayOrdinal = nth
        components.timeZone = .zurich
        return Calendar.zurich.date(from: components)!
    }
}

/// Holiday lookups for any year, computed on first use and cached. Holidays on weekends
/// are kept too: they only matter on days with scheduled hours, which the calculator
/// checks, so a schedule that includes Saturdays still gets e.g. a Saturday 1 August off.
final class HolidayCalendar: @unchecked Sendable {
    static let shared = HolidayCalendar()

    private let lock = NSLock()
    private var years: [Int: [Date: Holiday]] = [:]

    func holiday(on date: Date) -> Holiday? {
        let day = date.startOfDayZurich
        return holidays(inYear: day.zurichYear)[day]
    }

    func holidays(inYear year: Int) -> [Date: Holiday] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = years[year] { return cached }
        var lookup: [Date: Holiday] = [:]
        for holiday in ZurichHolidays.holidays(for: year) {
            lookup[holiday.date.startOfDayZurich] = holiday
        }
        years[year] = lookup
        return lookup
    }
}
