import XCTest
import SwiftData
@testable import WorkTracker

func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.zurich.zurichDate(year: year, month: month, day: day)
}

/// Same day in 2026, for tests that don't care about the year.
func day(_ month: Int, _ day: Int) -> Date {
    WorkTrackerTests.day(2026, month, day)
}

func time(_ date: Date, _ hour: Int, _ minute: Int = 0) -> Date {
    Calendar.zurich.date(byAdding: .minute, value: hour * 60 + minute, to: date.startOfDayZurich)!
}

/// A fresh temporary folder, removed when the test ends.
func temporaryDirectory(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkTrackerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

@MainActor
func inMemoryContainer() throws -> ModelContainer {
    try ModelContainer(for: Schema(versionedSchema: WorkTrackerSchemaV6.self),
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

func entry(_ type: AbsenceType, half: Bool = false) -> AbsenceEntry {
    AbsenceEntry(type: type, isHalfDay: half)
}

func custom(_ rule: AbsenceCountingRule, half: Bool = false, name: String = "Training") -> AbsenceEntry {
    AbsenceEntry(category: CategoryDetails(id: "custom-\(name)", name: name, icon: "book.fill", color: .purple, rule: rule),
                 isHalfDay: half)
}
