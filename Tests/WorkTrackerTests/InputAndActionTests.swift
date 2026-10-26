import XCTest
import SwiftData
@testable import WorkTracker

final class TimeFieldTests: XCTestCase {
    let today = day(9, 22)

    private func parsed(_ input: String, endOfDay: Bool = false) -> String? {
        TimeField.parse(input, on: today, allowsEndOfDay: endOfDay).map { TimeField.format($0, on: today) }
    }

    func testFormats() {
        XCTAssertEqual(parsed("0930"), "09:30")
        XCTAssertEqual(parsed("930"), "09:30")
        XCTAssertEqual(parsed("9"), "09:00")
        XCTAssertEqual(parsed("09"), "09:00")
        XCTAssertEqual(parsed("9:30"), "09:30")
        XCTAssertEqual(parsed("9.30"), "09:30")
        XCTAssertEqual(parsed("9 30"), "09:30")
        XCTAssertEqual(parsed(" 17:05 "), "17:05")
        XCTAssertEqual(parsed("0"), "00:00")
        XCTAssertNil(parsed("123456"), "last four digits 3456 is not a time")
    }

    func testInvalid() {
        XCTAssertNil(parsed(""))
        XCTAssertNil(parsed("25"))
        XCTAssertNil(parsed("9:60"))
        XCTAssertNil(parsed("abc"))
        XCTAssertNil(parsed("9:"), "a separator needs minutes")
    }

    func testEndOfDay() {
        XCTAssertNil(parsed("24"))
        XCTAssertEqual(parsed("24", endOfDay: true), "24:00")
        XCTAssertEqual(parsed("2400", endOfDay: true), "24:00")
        XCTAssertEqual(parsed("24:00", endOfDay: true), "24:00")
        XCTAssertNil(parsed("24:30", endOfDay: true))
        XCTAssertEqual(TimeField.parse("24", on: today, allowsEndOfDay: true), day(9, 23))
    }

    func testFormatUsesZurichTime() {
        // 07:30 UTC is 09:30 in Zurich (summer time).
        let date = ISO8601DateFormatter().date(from: "2026-09-22T07:30:00Z")!
        XCTAssertEqual(TimeField.format(date), "09:30")
    }
}

final class TimeFormattingTests: XCTestCase {
    func testSignedHoursParsing() {
        XCTAssertEqual(TimeFormatting.parseSignedHours("12:30"), 12.5)
        XCTAssertEqual(TimeFormatting.parseSignedHours("-4:15"), -4.25)
        XCTAssertEqual(TimeFormatting.parseSignedHours("+3"), 3)
        XCTAssertEqual(TimeFormatting.parseSignedHours("7.5"), 7.5)
        XCTAssertEqual(TimeFormatting.parseSignedHours("−2,25"), -2.25)
        XCTAssertNil(TimeFormatting.parseSignedHours("1:75"))
        XCTAssertNil(TimeFormatting.parseSignedHours("abc"))
        XCTAssertEqual(TimeFormatting.signedClock(-4.25), "-4:15")
        XCTAssertEqual(TimeFormatting.signedClock(12.5), "12:30")
    }

    func testHoursRounding() {
        XCTAssertEqual(TimeFormatting.hours(7.999), "8h 00m")
        XCTAssertEqual(TimeFormatting.signedHours(-0.5), "-0h 30m")
        XCTAssertEqual(TimeFormatting.signedHours(0.001), "+0h 00m")
    }
}

final class CSVTests: XCTestCase {
    func testDailyReportStandardAndGerman() {
        let calculator = WorkHoursCalculator(absences: [day(9, 23): entry(.vacation, half: true)])
        let days = day(9, 22).daysThrough(day(9, 23)).map(calculator.classify(date:))
        let hours = [day(9, 22): 8.5, day(9, 23): 4]

        let standard = CSVExporter(format: .standard).dailyReport(days: days, hours: hours)
        let lines = standard.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].hasPrefix("2026-09-22,"))
        XCTAssertTrue(lines[1].contains(",8.00,8.50,0.50,"))
        XCTAssertTrue(lines[2].contains(tr("%@ (half day)", tr("Vacation"))))
        XCTAssertTrue(lines[3].contains(",12.00,12.50,0.50,"))

        let german = CSVExporter(format: .excelGerman).dailyReport(days: days, hours: hours)
        XCTAssertTrue(german.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(german.contains(";8,00;8,50;0,50;"))
        XCTAssertFalse(german.contains(","+"8"))
    }

    func testFieldQuoting() {
        let csv = CSVExporter(format: .standard)
        XCTAssertEqual(csv.field("plain"), "plain")
        XCTAssertEqual(csv.field("a,b"), "\"a,b\"")
        XCTAssertEqual(csv.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExporter(format: .excelGerman).field("a,b"), "a,b")
        XCTAssertEqual(CSVExporter(format: .excelGerman).field("a;b"), "\"a;b\"")
    }

    @MainActor
    func testEntriesExport() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let project = Project(name: "Kunde, A")
        context.insert(project)
        let date = day(9, 22)
        context.insert(WorkSegment(date: date, startTime: time(date, 13), endTime: time(date, 24), project: project, note: "Late"))
        context.insert(WorkSegment(date: date, startTime: time(date, 8), endTime: time(date, 12), project: project))
        let segments = try context.fetch(FetchDescriptor<WorkSegment>())
        let lines = CSVExporter(format: .standard).entries(segments).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].contains(",08:00,12:00,4.00,\"Kunde, A\","))
        XCTAssertTrue(lines[2].contains(",13:00,24:00,11.00,\"Kunde, A\",Late"))
        XCTAssertTrue(lines[3].contains(",15.00,"))
    }
}

final class TimerTests: XCTestCase {
    func testSlicesSplitAtMidnightAndAroundBusy() {
        let start = time(day(9, 22), 22), end = time(day(9, 23), 2)
        let slices = TimeSlicer.slices(start: start, end: end, excluding: [(time(day(9, 22), 23), time(day(9, 22), 23, 30))])
        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(slices[0].end, time(day(9, 22), 23))
        XCTAssertEqual(slices[1].start, time(day(9, 22), 23, 30))
        XCTAssertEqual(slices[1].end, day(9, 23))
        XCTAssertEqual(slices[2].start, day(9, 23))
    }

    func testTinySlicesDropped() {
        let start = time(day(9, 22), 9)
        XCTAssertTrue(TimeSlicer.slices(start: start, end: start.addingTimeInterval(30), excluding: []).isEmpty)
        XCTAssertTrue(TimeSlicer.slices(start: start, end: start.addingTimeInterval(3600),
                                        excluding: [(start.addingTimeInterval(-60), start.addingTimeInterval(7200))]).isEmpty)
    }

    @MainActor
    func testTimerCreatesEntriesAndPersists() throws {
        let defaults = UserDefaults(suiteName: "WorkTrackerTests-\(UUID().uuidString)")!
        let container = try inMemoryContainer()
        let context = container.mainContext
        let project = Project(name: "A")
        context.insert(project)
        let date = day(9, 22)
        context.insert(WorkSegment(date: date, startTime: time(date, 10), endTime: time(date, 11), project: project))
        try context.save()

        let timer = WorkTimer(defaults: defaults)
        timer.start(project: project, at: time(date, 9))
        XCTAssertTrue(WorkTimer(defaults: defaults).isRunning, "state survives relaunch")

        let created = timer.stop(context: context, at: time(date, 12, 20))
        XCTAssertEqual(created.map(\.durationHours), [1, 1 + 20.0 / 60])
        XCTAssertFalse(timer.isRunning)
        XCTAssertFalse(WorkTimer(defaults: defaults).isRunning)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkSegment>()), 3)
    }

    @MainActor
    func testSwitchProject() throws {
        let defaults = UserDefaults(suiteName: "WorkTrackerTests-\(UUID().uuidString)")!
        let container = try inMemoryContainer()
        let context = container.mainContext
        let a = Project(name: "A"), b = Project(name: "B")
        context.insert(a); context.insert(b)
        try context.save()
        let timer = WorkTimer(defaults: defaults)
        let date = day(9, 22)
        timer.start(project: a, at: time(date, 8))
        timer.switchProject(to: b, context: context, at: time(date, 9))
        XCTAssertEqual(timer.project(in: context)?.name, "B")
        timer.stop(context: context, at: time(date, 10))
        let segments = try context.fetch(FetchDescriptor<WorkSegment>(sortBy: [SortDescriptor(\.startTime)]))
        XCTAssertEqual(segments.map { $0.project?.name }, ["A", "B"])
    }
}

final class EntryActionTests: XCTestCase {
    @MainActor
    func testCopyEntriesSkipsOverlaps() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let project = Project(name: "A")
        context.insert(project)
        let monday = day(9, 21), tuesday = day(9, 22)
        context.insert(WorkSegment(date: monday, startTime: time(monday, 8), endTime: time(monday, 12), project: project, note: "n"))
        context.insert(WorkSegment(date: monday, startTime: time(monday, 13), endTime: time(monday, 24), project: project))
        context.insert(WorkSegment(date: tuesday, startTime: time(tuesday, 9), endTime: time(tuesday, 10), project: project))
        try context.save()

        XCTAssertEqual(EntryActions.previousDayWithEntries(before: tuesday, in: context), monday)
        let result = EntryActions.copyEntries(from: monday, to: tuesday, in: context)
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.skipped, 1)
        let copied = EntryActions.segments(on: tuesday, in: context).last!
        XCTAssertEqual(copied.endTime, day(9, 23), "24:00 stays 24:00")
        XCTAssertEqual(copied.durationHours, 11)
    }

    @MainActor
    func testLastUsedProjectSkipsArchived() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let a = Project(name: "A"), b = Project(name: "B")
        context.insert(a); context.insert(b)
        let date = day(9, 22)
        context.insert(WorkSegment(date: date, startTime: time(date, 8), endTime: time(date, 9), project: a))
        context.insert(WorkSegment(date: date, startTime: time(date, 9), endTime: time(date, 10), project: b))
        try context.save()
        XCTAssertEqual(EntryActions.lastUsedProject(in: context)?.name, "B")
        b.isArchived = true
        XCTAssertEqual(EntryActions.lastUsedProject(in: context)?.name, "A")
    }

    @MainActor
    func testAbsenceClickCycleAndRange() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let date = day(9, 22)
        func absences() -> [VacationDay] { (try? context.fetch(FetchDescriptor<VacationDay>())) ?? [] }

        AbsenceEditor(context: context, absences: absences()).click(date, selection: .builtIn(.vacation))
        XCTAssertEqual(absences().first?.isHalfDay, false)
        AbsenceEditor(context: context, absences: absences()).click(date, selection: .builtIn(.vacation))
        XCTAssertEqual(absences().first?.isHalfDay, true)
        AbsenceEditor(context: context, absences: absences()).click(date, selection: .builtIn(.sick))
        XCTAssertEqual(absences().first?.resolvedType, .sick)
        XCTAssertEqual(absences().first?.isHalfDay, false)
        AbsenceEditor(context: context, absences: absences()).click(date, selection: .builtIn(.sick))
        AbsenceEditor(context: context, absences: absences()).click(date, selection: .builtIn(.sick))
        XCTAssertTrue(absences().isEmpty)

        let category = AbsenceCategory(name: "Training")
        context.insert(category)
        AbsenceEditor(context: context, absences: absences()).fill(day(9, 21).daysThrough(day(9, 23)), selection: .custom(category))
        XCTAssertEqual(absences().count, 3)
        XCTAssertTrue(absences().allSatisfy { $0.type == .custom && $0.category === category })
    }

    @MainActor
    func testDuplicateAbsencesDoNotCrashAndAreRemoved() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        context.insert(VacationDay(date: day(9, 22), type: .vacation))
        context.insert(VacationDay(date: day(9, 22), type: .sick))
        let all = try context.fetch(FetchDescriptor<VacationDay>())
        XCTAssertEqual(VacationDay.lookup(all).count, 1)
        _ = AbsenceEditor(context: context, absences: all)
        XCTAssertEqual(try VacationDay.removeDuplicates(in: context), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VacationDay>()), 1)
    }

    @MainActor
    func testProjectNamesAndColours() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let a = Project(name: "Zürich", color: .blue)
        context.insert(a)
        let projects = try context.fetch(FetchDescriptor<Project>())
        XCTAssertTrue(Project.isDuplicate(name: "zurich", in: projects))
        XCTAssertFalse(Project.isDuplicate(name: "zurich", in: projects, excluding: a))
        XCTAssertNotEqual(Project.suggestedColor(existing: projects), .blue)
        a.name = "Renamed"
        XCTAssertEqual(a.color, .blue, "renaming keeps the colour")
    }

    @MainActor
    func testProjectBreakdownKeepsSameNamedProjectsApart() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let a = Project(name: "Same"), b = Project(name: "Same")
        context.insert(a); context.insert(b)
        let date = day(9, 22)
        context.insert(WorkSegment(date: date, startTime: time(date, 8), endTime: time(date, 9), project: a))
        context.insert(WorkSegment(date: date, startTime: time(date, 9), endTime: time(date, 11), project: b))
        try context.save()
        let breakdown = WorkHoursCalculator.projectBreakdown(from: date, to: date,
                                                             segments: try context.fetch(FetchDescriptor<WorkSegment>()))
        XCTAssertEqual(breakdown.map(\.hours), [2, 1])
    }
}
