import Foundation

extension TimeZone {
    static let zurich = TimeZone(identifier: "Europe/Zurich")!
}

extension Calendar {
    static let zurich: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .zurich
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    /// Midnight (Zurich) of the given calendar day.
    func zurichDate(year: Int, month: Int, day: Int) -> Date {
        date(from: DateComponents(timeZone: .zurich, year: year, month: month, day: day))!
    }
}

extension Date {
    var startOfDayZurich: Date {
        Calendar.zurich.startOfDay(for: self)
    }

    var isWeekend: Bool {
        let weekday = Calendar.zurich.component(.weekday, from: self)
        return weekday == 1 || weekday == 7 // Sunday = 1, Saturday = 7
    }

    /// 0 = Monday … 6 = Sunday.
    var mondayBasedWeekday: Int {
        (Calendar.zurich.component(.weekday, from: self) + 5) % 7
    }

    var zurichYear: Int { Calendar.zurich.component(.year, from: self) }

    /// Monday of the week containing this date (Zurich midnight).
    var startOfWeekZurich: Date {
        Calendar.zurich.date(byAdding: .day, value: -mondayBasedWeekday, to: startOfDayZurich)!
    }

    func addingDays(_ days: Int) -> Date {
        Calendar.zurich.date(byAdding: .day, value: days, to: self)!
    }

    func isSameDay(as other: Date) -> Bool {
        Calendar.zurich.isDate(self, inSameDayAs: other)
    }

    /// Returns all dates from self to end (inclusive), stepping by 1 day.
    func daysThrough(_ end: Date) -> [Date] {
        var dates: [Date] = []
        var current = self.startOfDayZurich
        let endNormalized = end.startOfDayZurich
        while current <= endNormalized {
            dates.append(current)
            current = current.addingDays(1)
        }
        return dates
    }

    /// Rounded to the nearest whole minute.
    var roundedToMinute: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }
}

extension FormatStyle where Self == Date.FormatStyle {
    /// Formatting in the app's language, the Gregorian calendar and Zurich time, so every
    /// screen shows the same wall-clock times regardless of the Mac's time zone.
    static var app: Date.FormatStyle {
        Date.FormatStyle(locale: Localization.locale, calendar: .zurich, timeZone: .zurich)
    }
}
