import XCTest
@testable import WorkTracker

final class CalendarSyncTests: XCTestCase {
    private func events(_ absences: [Date: AbsenceEntry]) -> [AbsenceEvent] {
        AbsenceCalendarPlan.events(absences: absences, calculator: WorkHoursCalculator(absences: absences))
    }

    private func stamp(_ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: month, day: day)
    }

    private func weekdays(_ from: Date, _ to: Date, _ entry: AbsenceEntry) -> [Date: AbsenceEntry] {
        Dictionary(uniqueKeysWithValues: from.daysThrough(to).filter { !$0.isWeekend }.map { ($0, entry) })
    }

    /// Two weeks of vacation (Mon 9 – Fri 20 Nov 2026) are one event across the weekend.
    func testRunSpansWeekend() {
        XCTAssertEqual(events(weekdays(day(11, 9), day(11, 20), entry(.vacation))),
                       [AbsenceEvent(title: tr("Vacation"), first: stamp(11, 9), last: stamp(11, 20))])
    }

    /// Thursday before Easter and Tuesday after: Karfreitag, the weekend and Ostermontag
    /// are days off anyway, so the run continues.
    func testRunSpansPublicHolidays() {
        XCTAssertEqual(events([day(4, 2): entry(.vacation), day(4, 7): entry(.vacation)]),
                       [AbsenceEvent(title: tr("Vacation"), first: stamp(4, 2), last: stamp(4, 7))])
    }

    /// A working day without an absence, another category or a half day ends a run.
    func testRunBreaks() {
        let result = events([
            day(9, 21): entry(.vacation), day(9, 22): entry(.vacation),
            day(9, 24): entry(.vacation),
            day(9, 25): entry(.unpaid),
            day(9, 28): entry(.unpaid, half: true), day(9, 29): entry(.unpaid),
        ])
        XCTAssertEqual(result, [
            AbsenceEvent(title: tr("Vacation"), first: stamp(9, 21), last: stamp(9, 22)),
            AbsenceEvent(title: tr("Vacation"), first: stamp(9, 24), last: stamp(9, 24)),
            AbsenceEvent(title: tr("Unpaid Leave"), first: stamp(9, 25), last: stamp(9, 25)),
            AbsenceEvent(title: tr("%@ (half day)", tr("Unpaid Leave")), first: stamp(9, 28), last: stamp(9, 28)),
            AbsenceEvent(title: tr("Unpaid Leave"), first: stamp(9, 29), last: stamp(9, 29)),
        ])
    }

    /// Custom categories use their own name; absences on days without work are left out.
    func testCustomCategoryAndIneligibleDays() {
        XCTAssertEqual(events([day(9, 23): custom(.reduceHours, name: "Workation Bonus"), day(9, 26): entry(.sick)]),
                       [AbsenceEvent(title: "Workation Bonus", first: stamp(9, 23), last: stamp(9, 23))])
    }

    @MainActor
    func testReconcileAddsRemovesAndKeeps() throws {
        let keep = AbsenceEvent(title: "Vacation", first: stamp(11, 9), last: stamp(11, 20))
        let changed = AbsenceEvent(title: "Sick", first: stamp(12, 1), last: stamp(12, 1))
        let calendar = FakeCalendar([keep, changed, keep])

        let desired = [keep, AbsenceEvent(title: "Sick", first: stamp(12, 1), last: stamp(12, 2))]
        let result = try AbsenceCalendarPlan.reconcile(desired, with: calendar, today: stamp(10, 21))
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 2, "the outdated event and the duplicate")
        XCTAssertEqual(Set(calendar.stored.values), Set(desired))
        XCTAssertEqual(calendar.stored.count, 2)
        XCTAssertEqual(calendar.commits, 1)

        // Already in step: nothing written.
        XCTAssertEqual(try AbsenceCalendarPlan.reconcile(desired, with: calendar, today: stamp(10, 21)).added, 0)
        XCTAssertEqual(calendar.commits, 1)

        // All absences removed: the calendar empties.
        XCTAssertEqual(try AbsenceCalendarPlan.reconcile([], with: calendar, today: stamp(10, 21)).removed, 2)
        XCTAssertTrue(calendar.stored.isEmpty)
    }

    /// The search covers absences far in the past and future, not just the current year.
    @MainActor
    func testReconcileSearchRange() throws {
        let old = AbsenceEvent(title: "Vacation", first: CalendarDay(year: 1999, month: 3, day: 1),
                               last: CalendarDay(year: 1999, month: 3, day: 5))
        let calendar = FakeCalendar([])
        try AbsenceCalendarPlan.reconcile([old], with: calendar, today: stamp(10, 21))
        XCTAssertEqual(calendar.searched?.from, old.first)
        XCTAssertEqual(calendar.searched?.to, CalendarDay(year: 2036, month: 12, day: 31))
    }
}

@MainActor
private final class FakeCalendar: AbsenceCalendarTarget {
    var stored: [String: AbsenceEvent] = [:]
    var commits = 0
    var searched: (from: CalendarDay, to: CalendarDay)?
    private var nextID = 0

    init(_ events: [AbsenceEvent]) {
        events.forEach(insert)
    }

    private func insert(_ event: AbsenceEvent) {
        nextID += 1
        stored["\(nextID)"] = event
    }

    func events(from: CalendarDay, to: CalendarDay) throws -> [StoredAbsenceEvent] {
        searched = (from, to)
        return stored.filter { $0.value.last >= from && $0.value.first <= to }
            .map { StoredAbsenceEvent(id: $0.key, event: $0.value) }
    }

    func add(_ event: AbsenceEvent) throws { insert(event) }
    func remove(id: String) throws { stored[id] = nil }
    func commit() throws { commits += 1 }
}
