import Foundation

/// Contract hours per weekday, with a history of changes so a new contract (e.g. 80%
/// from next year) never rewrites earlier balances.
struct WorkSchedule: Codable, Equatable {
    struct Period: Codable, Equatable, Identifiable {
        var id = UUID()
        /// First day (Zurich midnight) this schedule applies.
        var effectiveFrom: Date
        /// Hours per weekday, index 0 = Monday … 6 = Sunday.
        var hours: [Double]

        var weeklyHours: Double { hours.reduce(0, +) }

        /// Workload relative to a full-time week of `fullTimeWeeklyHours`.
        func workload(fullTimeWeeklyHours: Double) -> Double {
            fullTimeWeeklyHours > 0 ? weeklyHours / fullTimeWeeklyHours : 0
        }

        /// Mon–Fri with `percent` of a full-time week, weekends off.
        static func weekdays(effectiveFrom: Date, fullTimeWeeklyHours: Double = 40, percent: Double = 100) -> Period {
            let daily = fullTimeWeeklyHours / 5 * percent / 100
            return Period(effectiveFrom: effectiveFrom.startOfDayZurich, hours: [daily, daily, daily, daily, daily, 0, 0])
        }
    }

    /// Sorted by `effectiveFrom`. Never empty.
    private(set) var periods: [Period]

    init(periods: [Period]) {
        self.periods = periods.isEmpty ? [Self.defaultPeriod] : periods.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    /// Mon–Fri, 8 hours a day — the schedule the app always assumed before schedules existed.
    /// Its ID is fixed: a new one at every launch would look like a schedule change to
    /// sync and undo changes made on another Mac.
    static let defaultPeriod: Period = {
        var period = Period.weekdays(effectiveFrom: .distantPast)
        period.id = UUID(uuidString: "6F2C3A1E-0000-4000-8000-000000000001")!
        return period
    }()
    static let standard = WorkSchedule(periods: [defaultPeriod])

    /// The period in force on `date`. The first period also covers any earlier dates.
    func period(on date: Date) -> Period {
        let day = date.startOfDayZurich
        return periods.last { $0.effectiveFrom <= day } ?? periods[0]
    }

    func hours(on date: Date) -> Double {
        let hours = period(on: date).hours
        let index = date.mondayBasedWeekday
        return index < hours.count ? hours[index] : 0
    }

    mutating func upsert(_ period: Period) {
        var list = periods.filter { $0.id != period.id }
        var normalized = period
        normalized.effectiveFrom = period.effectiveFrom == .distantPast ? .distantPast : period.effectiveFrom.startOfDayZurich
        list.append(normalized)
        self = WorkSchedule(periods: list)
    }

    mutating func remove(id: Period.ID) {
        guard periods.count > 1 else { return }
        self = WorkSchedule(periods: periods.filter { $0.id != id })
    }
}
