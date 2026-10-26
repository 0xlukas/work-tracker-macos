import Foundation

/// A calendar day without a time or time zone, so all-day events land on the same date
/// whatever time zone the Mac is in.
struct CalendarDay: Hashable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Midnight of this day in `calendar`.
    func date(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// One all-day event: a run of absence days of one category, first to last day inclusive.
struct AbsenceEvent: Hashable {
    let title: String
    let first: CalendarDay
    let last: CalendarDay
}

/// An event already in the calendar, with the identifier needed to remove it.
struct StoredAbsenceEvent {
    let id: String
    let event: AbsenceEvent
}

/// The calendar the absences are written to: EventKit in the app, a fake in tests.
@MainActor
protocol AbsenceCalendarTarget {
    func events(from: CalendarDay, to: CalendarDay) throws -> [StoredAbsenceEvent]
    func add(_ event: AbsenceEvent) throws
    func remove(id: String) throws
    func commit() throws
}

enum AbsenceCalendarPlan {
    /// One event per run of absence days with the same category. Days without expected
    /// work in between (weekends, public holidays) don't break a run, so two weeks of
    /// vacation become one event. Half days are always events of their own.
    static func events(absences: [Date: AbsenceEntry], calculator: WorkHoursCalculator) -> [AbsenceEvent] {
        var events: [AbsenceEvent] = []
        var run: (entry: AbsenceEntry, first: Date, last: Date)?

        func close() {
            guard let run else { return }
            let name = run.entry.category.name
            events.append(AbsenceEvent(title: run.entry.isHalfDay ? tr("%@ (half day)", name) : name,
                                       first: CalendarDay(run.first, in: .zurich),
                                       last: CalendarDay(run.last, in: .zurich)))
        }

        for day in absences.keys.sorted() where calculator.isAbsenceEligible(day) {
            let entry = absences[day]!
            if let current = run, !entry.isHalfDay, !current.entry.isHalfDay,
               entry.category.id == current.entry.category.id,
               current.last.addingDays(1).daysThrough(day.addingDays(-1)).allSatisfy({ !calculator.isAbsenceEligible($0) }) {
                run?.last = day
            } else {
                close()
                run = (entry, day, day)
            }
        }
        close()
        return events
    }

    /// Make the calendar hold exactly `desired`: events that match are left alone, the rest
    /// are removed, missing ones added. Returns how many were added and removed.
    @MainActor
    @discardableResult
    static func reconcile(_ desired: [AbsenceEvent], with target: some AbsenceCalendarTarget,
                          today: CalendarDay) throws -> (added: Int, removed: Int) {
        // Look well beyond the absences so events of since-deleted absences are found too.
        let from = min(desired.map(\.first).min() ?? today, CalendarDay(year: today.year - 20, month: 1, day: 1))
        let to = max(desired.map(\.last).max() ?? today, CalendarDay(year: today.year + 10, month: 12, day: 31))

        var missing = Dictionary(desired.map { ($0, 1) }, uniquingKeysWith: +)
        var stale: [String] = []
        for stored in try target.events(from: from, to: to) {
            if let count = missing[stored.event], count > 0 {
                missing[stored.event] = count - 1
            } else {
                stale.append(stored.id)
            }
        }

        var added = 0
        for event in desired where (missing[event] ?? 0) > 0 {
            try target.add(event)
            missing[event]! -= 1
            added += 1
        }
        for id in stale { try target.remove(id: id) }
        if added + stale.count > 0 { try target.commit() }
        return (added, stale.count)
    }
}
