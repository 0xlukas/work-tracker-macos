import XCTest
import SwiftData
@testable import WorkTracker

// MARK: - Merge rules

final class SyncMergeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func project(_ name: String, created: TimeInterval = 0, archived: Bool = false) -> SyncPayload {
        .project(ProjectRecord(name: name, createdAt: base.addingTimeInterval(created), color: "blue", isArchived: archived))
    }

    private func entry(_ project: String?, _ hour: Int, _ end: Int, on date: Date = day(9, 22), note: String = "") -> SyncPayload {
        .entry(EntryRecord(day: date, start: time(date, hour), end: time(date, end), project: project, note: note))
    }

    private func absence(_ date: Date, _ type: AbsenceType = .vacation, half: Bool = false) -> SyncPayload {
        .absence(AbsenceRecord(day: date, isHalfDay: half, type: type.rawValue, category: nil, categoryRule: nil))
    }

    private func newState() -> SyncState {
        SyncState()
    }

    private func live(_ state: SyncState) -> [String: SyncPayload] {
        Dictionary(uniqueKeysWithValues: state.liveRecords.map { ($0.id, $0.payload) })
    }

    func testAbsorbVersionsChangesAndKeepsDeletedContent() {
        var state = newState()
        XCTAssertEqual(SyncMerge.absorb(["p": project("Alpha"), "e": entry("p", 8, 12)], into: &state, device: "A", now: base), 2)
        XCTAssertEqual(SyncMerge.absorb(["p": project("Alpha"), "e": entry("p", 8, 12)], into: &state, device: "A", now: base), 0)
        let before = state.records["e"]!.version
        XCTAssertEqual(SyncMerge.absorb(["p": project("Alpha"), "e": entry("p", 8, 13)], into: &state, device: "A", now: base), 1)
        XCTAssertGreaterThan(state.records["e"]!.version, before, "a change gets a later version even at the same time")

        XCTAssertEqual(SyncMerge.pendingDeletions(["p": project("Alpha")], in: state), ["e"])
        SyncMerge.absorb(["p": project("Alpha")], into: &state, device: "A", now: base)
        XCTAssertTrue(state.records["e"]!.isDeleted)
        XCTAssertEqual(state.records["e"]!.payload, entry("p", 8, 13), "deleted records keep their content")
        XCTAssertEqual(state.liveItemCount, 1)

        // Without deletions, missing records stay (and syncing puts them back).
        SyncMerge.absorb(["p": project("Alpha"), "x": entry("p", 14, 15)], into: &state, device: "A", now: base)
        SyncMerge.absorb(["p": project("Alpha")], into: &state, device: "A", now: base, deletions: false)
        XCTAssertFalse(state.records["x"]!.isDeleted)
    }

    func testMergeTakesNewerVersionsAndAdvancesTheClock() {
        var mine = newState()
        SyncMerge.absorb(["p": project("Alpha")], into: &mine, device: "A", now: base)
        var theirs = mine
        // The other Mac's clock runs an hour ahead.
        SyncMerge.absorb(["p": project("Renamed")], into: &theirs, device: "B", now: base.addingTimeInterval(3600))

        XCTAssertEqual(SyncMerge.merge(Array(theirs.records.values), into: &mine), 1)
        XCTAssertEqual(mine.records["p"]!.payload, project("Renamed"))
        XCTAssertEqual(SyncMerge.merge(Array(theirs.records.values), into: &mine), 0, "merging again changes nothing")

        // A change made here afterwards wins, although this Mac's clock is behind.
        SyncMerge.absorb(["p": project("Mine")], into: &mine, device: "A", now: base)
        SyncMerge.merge(Array(mine.records.values), into: &theirs)
        XCTAssertEqual(theirs.records["p"]!.payload, project("Mine"))
    }

    func testConcurrentChangesConvergeOnTheLaterOne() {
        var common = newState()
        SyncMerge.absorb(["p": project("Alpha"), "e": entry("p", 8, 12)], into: &common, device: "A", now: base)
        var a = common, b = common
        SyncMerge.absorb(["p": project("Alpha"), "e": entry("p", 8, 11)], into: &a, device: "A", now: base.addingTimeInterval(60))
        SyncMerge.absorb(["p": project("Alpha")], into: &b, device: "B", now: base.addingTimeInterval(120))
        let fromA = Array(a.records.values), fromB = Array(b.records.values)
        SyncMerge.merge(fromB, into: &a)
        SyncMerge.merge(fromA, into: &b)
        XCTAssertEqual(a, b.with(clock: a.clock))
        XCTAssertTrue(a.records["e"]!.isDeleted, "the later deletion wins over the earlier edit")

        // An edit after the deletion brings the entry back.
        SyncMerge.absorb(["p": project("Alpha"), "e": entry("p", 9, 12)], into: &a, device: "A", now: base.addingTimeInterval(180))
        SyncMerge.merge(Array(a.records.values), into: &b)
        XCTAssertFalse(b.records["e"]!.isDeleted)
        XCTAssertEqual(b.records["e"]!.payload, entry("p", 9, 12))
    }

    /// Both Macs created "Alpha" (and "alpha"/"Älpha" count as the same name).
    func testProjectsWithOneNameMergeIntoTheOldest() {
        var a = newState(), b = newState()
        SyncMerge.absorb(["p1": project("Alpha", created: 10), "e1": entry("p1", 8, 12)], into: &a, device: "A", now: base)
        SyncMerge.absorb(["p2": project("älpha", created: 5, archived: true), "e2": entry("p2", 13, 17)], into: &b, device: "B", now: base)
        let fromA = Array(a.records.values), fromB = Array(b.records.values)
        SyncMerge.merge(fromB, into: &a)
        SyncMerge.merge(fromA, into: &b)

        let resolution = SyncMerge.resolve(&a, device: "A", now: base)
        SyncMerge.resolve(&b, device: "B", now: base)
        XCTAssertEqual(resolution.merged, ["p1": "p2"])
        XCTAssertEqual(live(a), live(b), "both Macs reach the same result on their own")
        XCTAssertEqual(live(a)["p2"], project("älpha", created: 5, archived: false), "active, as one of them was")
        XCTAssertNil(live(a)["p1"])
        XCTAssertEqual(live(a)["e1"], entry("p2", 8, 12))
        XCTAssertEqual(SyncMerge.resolve(&a, device: "A", now: base).changes, 0, "resolving is idempotent")
    }

    func testDeletedProjectComesBackWhenEntriesOrTheTimerUseIt() {
        var a = newState()
        SyncMerge.absorb(["p": project("Alpha"), "q": project("Beta")], into: &a, device: "A", now: base)
        var b = a
        SyncMerge.absorb([:], into: &a, device: "A", now: base.addingTimeInterval(60))   // A deletes both
        SyncMerge.absorb(["p": project("Alpha"), "q": project("Beta"), "e": entry("p", 8, 9)], into: &b, device: "B", now: base)
        SyncMerge.merge(Array(b.records.values), into: &a)
        XCTAssertTrue(a.records["p"]!.isDeleted)
        SyncMerge.resolve(&a, device: "A", now: base, pinned: ["q"])
        XCTAssertFalse(a.records["p"]!.isDeleted, "an entry still uses it")
        XCTAssertFalse(a.records["q"]!.isDeleted, "the timer runs for it")
        XCTAssertEqual(a.records["p"]!.payload, project("Alpha"))
    }

    func testOneAbsencePerDayAndEachEntryOnce() {
        var a = newState(), b = newState()
        SyncMerge.absorb(["a1": absence(day(9, 23)), "e1": entry("p", 8, 12, note: "first")], into: &a, device: "A", now: base)
        SyncMerge.absorb(["a2": absence(day(9, 23), .sick, half: true), "e2": entry("p", 8, 12, note: "second")],
                         into: &b, device: "B", now: base.addingTimeInterval(60))
        let fromA = Array(a.records.values), fromB = Array(b.records.values)
        SyncMerge.merge(fromB, into: &a)
        SyncMerge.merge(fromA, into: &b)
        SyncMerge.resolve(&a, device: "A", now: base.addingTimeInterval(120))
        SyncMerge.resolve(&b, device: "B", now: base.addingTimeInterval(120))
        XCTAssertEqual(live(a), live(b))
        XCTAssertEqual(live(a)["a1"], absence(day(9, 23), .sick, half: true), "the same record stays, with the latest content")
        XCTAssertNil(live(a)["a2"])
        XCTAssertEqual(live(a)["e1"], entry("p", 8, 12, note: "second"))
        XCTAssertNil(live(a)["e2"])
    }

    func testChangesBringTheDatabaseInLine() {
        var state = newState()
        SyncMerge.absorb(["p": project("Alpha"), "e": entry("p", 8, 12)], into: &state, device: "A", now: base)
        SyncMerge.absorb(["p": project("Beta")], into: &state, device: "A", now: base)
        let local: [String: SyncPayload] = ["p": project("Alpha"), "e": entry("p", 8, 12), "x": entry("p", 13, 14)]
        let changes = SyncMerge.changes(from: local, to: state)
        XCTAssertEqual(changes.upserts.map(\.id), ["p"])
        XCTAssertEqual(changes.deletions.map(\.id), ["e"], "unknown local records stay unless replacing")
        XCTAssertEqual(SyncMerge.changes(from: local, to: state, replacing: true).deletions.map(\.id), ["e", "x"])
    }

    func testSnapshotRoundTripAndFormatCheck() throws {
        var state = newState()
        var schedule = WorkSchedule.standard
        schedule.upsert(.weekdays(effectiveFrom: day(2027, 1, 1), percent: 80))
        SyncMerge.absorb([
            "p": project("Alpha"), "e": entry("p", 8, 12, note: "Notiz «ä»"), "a": absence(day(9, 23), .unpaid, half: true),
            "c": .category(CategoryRecord(name: "Training", icon: "book.fill", color: "purple", rule: "unchanged", isArchived: true)),
            "setting.schedule": .setting(.schedule(schedule)), "setting.flag": .setting(.flag(true)),
            "setting.date": .setting(.date(day(1, 1))), "setting.number": .setting(.number(-12.25)),
        ], into: &state, device: "A", now: base)
        SyncMerge.absorb(["p": project("Alpha")], into: &state, device: "A", now: base)
        let snapshot = DeviceSnapshot(device: .init(id: "A", name: "Mac", appVersion: "1"), publishedAt: base, state: state)
        let data = try DeviceSnapshot.encoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DeviceSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.state, state)
        XCTAssertEqual(try DeviceSnapshot.encoder().encode(decoded), data, "an unchanged ledger writes the same file")

        let folder = try temporaryDirectory(self)
        var newer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        newer["format"] = DeviceSnapshot.currentFormat + 1
        try JSONSerialization.data(withJSONObject: newer).write(to: SyncFolder.fileURL(device: "B", in: folder))
        try data.write(to: SyncFolder.fileURL(device: "C", in: folder))
        try Data("{".utf8).write(to: SyncFolder.fileURL(device: "D", in: folder))
        try data.write(to: SyncFolder.fileURL(device: "A", in: folder))
        let listing = try SyncFolder.read(folder, ownDevice: "A", cache: [:])
        XCTAssertTrue(listing.ownFileExists)
        XCTAssertEqual(listing.others.count, 3)
        let contents = Dictionary(uniqueKeysWithValues: listing.others.map { ($0.key.lastPathComponent, $0.value) })
        if case .newerFormat = contents["device-B.json"]?.content {} else { XCTFail("newer format not recognised") }
        XCTAssertEqual(contents["device-C.json"]?.snapshot, snapshot)
        if case .unreadable = contents["device-D.json"]?.content {} else { XCTFail("broken file not reported") }
        XCTAssertTrue(SyncFolder.hasChanges(folder, ownDevice: "A", cache: listing.others), "unreadable files are retried")
        try FileManager.default.removeItem(at: SyncFolder.fileURL(device: "D", in: folder))
        let readable = try SyncFolder.read(folder, ownDevice: "A", cache: listing.others)
        XCTAssertFalse(SyncFolder.hasChanges(folder, ownDevice: "A", cache: readable.others))
        try data.write(to: SyncFolder.fileURL(device: "E", in: folder))
        XCTAssertTrue(SyncFolder.hasChanges(folder, ownDevice: "A", cache: readable.others))
    }
}

private extension SyncState {
    func with(clock: Int64) -> SyncState {
        var copy = self
        copy.clock = clock
        return copy
    }
}

// MARK: - Two Macs

/// A Mac with its own database, preferences, timer and ledger, syncing through a shared folder.
@MainActor
private final class TestMac {
    let container: ModelContainer
    let defaults: UserDefaults
    let preferences: Preferences
    let timer: WorkTimer
    let sync: DeviceSync
    var backups = 0
    var context: ModelContext { container.mainContext }

    let name: String
    let root: URL

    init(_ name: String, folder: URL, root: URL, clock: TestClock) throws {
        self.name = name
        self.root = root
        let suite = "WorkTrackerTests.\(name).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        container = try inMemoryContainer()
        preferences = Preferences(defaults: defaults)
        timer = WorkTimer(defaults: defaults)
        sync = DeviceSync(folder: folder, ledger: root.appendingPathComponent("\(name)/ledger.json"),
                          device: .init(id: name, name: "\(name)’s Mac", appVersion: "test"),
                          defaults: defaults, preferences: preferences, timer: timer, now: { clock.now })
        connect()
    }

    /// A new DeviceSync for the same Mac, as after relaunching the app.
    func relaunch(folder: URL, root: URL, clock: TestClock, name: String) -> DeviceSync {
        let fresh = DeviceSync(folder: folder, ledger: root.appendingPathComponent("\(name)/ledger.json"),
                               device: .init(id: name, name: "\(name)’s Mac", appVersion: "test"),
                               defaults: defaults, preferences: preferences, timer: timer, now: { clock.now })
        fresh.connect(container: container, backupFolder: backupFolder) { [weak self] in self?.makeBackup() ?? false }
        return fresh
    }

    /// Whether backups work (sync refuses to delete or replace much without one).
    var backupsWork = true
    var backupFolder: URL { root.appendingPathComponent("\(name)/Backups", isDirectory: true) }

    private func makeBackup() -> Bool {
        guard backupsWork else { return false }
        backups += 1
        return true
    }

    private func connect() {
        sync.connect(container: container, backupFolder: backupFolder) { [weak self] in self?.makeBackup() ?? false }
    }

    @discardableResult
    func addProject(_ name: String) throws -> Project {
        let project = Project(name: name)
        context.insert(project)
        try context.save()
        return project
    }

    @discardableResult
    func addEntry(_ project: Project, on date: Date, _ hour: Int, _ end: Int, note: String = "") throws -> WorkSegment {
        let segment = WorkSegment(date: date, startTime: time(date, hour), endTime: time(date, end), project: project, note: note)
        context.insert(segment)
        try context.save()
        return segment
    }

    func projects() throws -> [Project] { try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])) }
    func entries() throws -> [WorkSegment] { try context.fetch(FetchDescriptor<WorkSegment>(sortBy: [SortDescriptor(\.startTime)])) }
    func absences() throws -> [VacationDay] { try context.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)])) }

    /// What the user sees: comparable across Macs.
    func summary() throws -> [String] {
        try projects().map { "project \($0.name) \($0.color.rawValue)\($0.isArchived ? " archived" : "")" }
            + entries().map { "entry \($0.project?.name ?? "–") \($0.startTime.timeIntervalSince1970)-\($0.endTime.timeIntervalSince1970) \($0.durationHours) \($0.note)" }
            + absences().map { "absence \($0.date.timeIntervalSince1970) \($0.resolvedType.rawValue) \($0.isHalfDay) \($0.category?.name ?? "")" }
            + context.fetch(FetchDescriptor<AbsenceCategory>(sortBy: [SortDescriptor(\.name)])).map { "category \($0.name) \($0.ruleRaw)" }
    }
}

private extension DeviceSync {
    /// Answer the question on screen, as the user would.
    func answerShown(_ answer: Answer) async {
        guard let question else { return XCTFail("no question to answer") }
        await self.answer(answer, to: question)
    }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 60) { now = now.addingTimeInterval(seconds) }
}

final class DeviceSyncTests: XCTestCase {
    private var folder: URL!
    private var root: URL!
    private let clock = TestClock()

    override func setUpWithError() throws {
        root = try temporaryDirectory(self)
        folder = root.appendingPathComponent("Work Tracker Sync", isDirectory: true)
    }

    @MainActor
    private func mac(_ name: String) throws -> TestMac {
        try TestMac(name, folder: folder, root: root, clock: clock)
    }

    /// Sync each Mac in turn, twice, as the app would over a few minutes.
    @MainActor
    private func syncAll(_ macs: TestMac...) async {
        for _ in 0..<2 {
            for mac in macs {
                clock.advance()
                await mac.sync.sync()
                XCTAssertNil(mac.sync.errorMessage)
            }
        }
    }

    @MainActor
    func testFirstMacPublishesAndAnEmptyMacTakesItsData() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        alpha.color = .green
        try a.addEntry(alpha, on: day(9, 22), 8, 12, note: "Review")
        let training = AbsenceCategory(name: "Training", rule: .unchanged)
        a.context.insert(training)
        let absence = VacationDay(date: day(9, 23))
        absence.assign(.custom(training))
        a.context.insert(absence)
        a.context.insert(VacationDay(date: day(9, 24), isHalfDay: true, type: .sick))
        try a.context.save()
        a.preferences.vacationEntitlement = 27.5
        a.preferences.openingBalanceHours = -3.25
        a.preferences.schedule.upsert(.weekdays(effectiveFrom: day(2027, 1, 1), percent: 80))

        await a.sync.turnOn()
        XCTAssertTrue(a.sync.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "A", in: folder).path))

        // As in the app, where Edit ▸ Undo covers the shared context.
        let undoManager = UndoManager()
        b.context.undoManager = undoManager
        await b.sync.turnOn()
        XCTAssertFalse(undoManager.canUndo, "syncing isn't undoable")
        XCTAssertTrue(undoManager.isUndoRegistrationEnabled)
        b.context.insert(Project(name: "After"))
        b.context.processPendingChanges()
        XCTAssertTrue(undoManager.canUndo, "the user's own changes still are")
        undoManager.undo()
        b.context.processPendingChanges()
        XCTAssertFalse(try b.projects().contains { $0.name == "After" })
        XCTAssertNil(b.sync.joinRequest, "an empty Mac joins without asking")
        XCTAssertTrue(b.sync.isEnabled)
        XCTAssertEqual(try a.summary().count, 5)
        XCTAssertEqual(try b.summary(), try a.summary())
        XCTAssertEqual(b.preferences.vacationEntitlement, 27.5)
        XCTAssertEqual(b.preferences.openingBalanceHours, -3.25)
        XCTAssertEqual(b.preferences.schedule, a.preferences.schedule)
        XCTAssertEqual(try b.absences().first?.entry.category.rule, .unchanged)
        XCTAssertEqual(b.backups, 0)
        XCTAssertEqual(b.sync.otherMacs.map(\.name), ["A’s Mac"])
        XCTAssertEqual(b.sync.otherMacs.first?.status, .inSync)
    }

    @MainActor
    func testChangesFlowBothWays() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        try a.addEntry(alpha, on: day(9, 22), 8, 12)
        await a.sync.turnOn()
        await b.sync.turnOn()

        // A adds, B edits and deletes, both change a preference.
        let beta = try a.addProject("Beta")
        try a.addEntry(beta, on: day(9, 23), 13, 17, note: "new")
        a.preferences.carryOverVacation = true
        await syncAll(a, b)
        XCTAssertEqual(try b.summary().count, 4)
        XCTAssertEqual(try b.summary(), try a.summary())
        XCTAssertTrue(b.preferences.carryOverVacation)

        let first = try XCTUnwrap(b.entries().first)
        first.endTime = time(day(9, 22), 11)
        first.recalculateDuration()
        let second = try XCTUnwrap(b.entries().last)
        b.context.delete(second)
        try b.projects().first { $0.name == "Beta" }?.isArchived = true
        try b.context.save()
        b.preferences.fullTimeWeeklyHours = 42
        await syncAll(b, a)
        XCTAssertEqual(try a.summary(), try b.summary())
        XCTAssertEqual(try a.entries().map(\.durationHours), [3])
        XCTAssertEqual(a.preferences.fullTimeWeeklyHours, 42)

        // Deleting a project after its entries are gone.
        try a.context.delete(XCTUnwrap(a.projects().first { $0.name == "Beta" }))
        try a.context.save()
        await syncAll(a, b)
        XCTAssertEqual(try b.projects().map(\.name), ["Alpha"])
    }

    @MainActor
    func testJoiningWithOwnDataAsksAndBacksUp() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addEntry(a.addProject("Real"), on: day(9, 22), 8, 12)
        await a.sync.turnOn()
        try b.addEntry(b.addProject("Test"), on: day(9, 1), 8, 9)

        await b.sync.turnOn()
        XCTAssertFalse(b.sync.isEnabled)
        XCTAssertEqual(b.sync.joinRequest?.otherMacs, ["A’s Mac"])
        await b.sync.join(.useOtherMacs)
        XCTAssertTrue(b.sync.isEnabled)
        XCTAssertEqual(b.backups, 1)
        XCTAssertEqual(try b.summary(), try a.summary())
        XCTAssertEqual(try b.projects().map(\.name), ["Real"])

        // Nothing of B's test data reaches A.
        await syncAll(a, b)
        XCTAssertEqual(try a.projects().map(\.name), ["Real"])
    }

    @MainActor
    func testUsingThisMacsDataEverywhereReplacesTheOthers() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addEntry(a.addProject("Test"), on: day(9, 1), 8, 9)
        await a.sync.turnOn()
        try b.addEntry(b.addProject("Real"), on: day(9, 22), 8, 12)
        b.preferences.vacationEntitlement = 30

        await b.sync.turnOn()
        XCTAssertEqual(b.sync.joinRequest?.localItems, 2)
        XCTAssertEqual(b.sync.joinRequest?.otherItems, 2)
        clock.advance()
        await b.sync.join(.useThisMac)
        XCTAssertEqual(try b.projects().map(\.name), ["Real"])

        // A follows (few items, so without asking).
        await syncAll(a, b)
        XCTAssertNil(a.sync.question)
        XCTAssertEqual(try a.summary(), try b.summary())
        XCTAssertEqual(try a.projects().map(\.name), ["Real"])
        XCTAssertEqual(a.preferences.vacationEntitlement, 30)
    }

    @MainActor
    func testManyMissingItemsWaitForADecision() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...15 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()

        // Something empties A's database: nothing is deleted anywhere until the user decides.
        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        XCTAssertEqual(a.sync.question, .missingItems(count: 15))
        await b.sync.sync()
        XCTAssertEqual(try b.entries().count, 15)

        await a.sync.answerShown(.restoreMissing)
        XCTAssertNil(a.sync.question)
        XCTAssertEqual(try a.entries().count, 15)

        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        await a.sync.answerShown(.deleteEverywhere)
        XCTAssertNil(a.sync.question)

        // B is asked too, and deletes only after a backup.
        clock.advance()
        await b.sync.sync()
        XCTAssertEqual(b.sync.question, .deletedElsewhere(mac: "A’s Mac", count: 15))
        XCTAssertEqual(try b.entries().count, 15)
        await b.sync.answerShown(.deleteHereToo)
        XCTAssertEqual(try b.entries().count, 0)
        XCTAssertEqual(b.backups, 1, "backed up before many items disappeared")
        XCTAssertEqual(try b.projects().map(\.name), ["Alpha"])
    }

    @MainActor
    func testRestoredBackupGoesToTheOtherMacs() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...12 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()

        // A restores a backup from before the entries; the app restarts.
        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        DeviceSync.prepareForRestore(defaults: a.defaults)
        let relaunched = a.relaunch(folder: folder, root: root, clock: clock, name: "A")
        clock.advance()
        await relaunched.sync()
        XCTAssertNil(relaunched.question)
        clock.advance()
        await b.sync.sync()
        XCTAssertEqual(b.sync.question, .deletedElsewhere(mac: "A’s Mac", count: 12))
        await b.sync.answerShown(.deleteHereToo)
        XCTAssertEqual(try b.entries().count, 0)
    }

    @MainActor
    func testRecoveryPutsEverythingBack() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...12 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()

        // B's database couldn't be opened and was replaced by an empty one.
        for entry in try b.entries() { b.context.delete(entry) }
        try b.context.save()
        for project in try b.projects() { b.context.delete(project) }
        try b.context.save()
        DeviceSync.prepareForRecovery(defaults: b.defaults)
        XCTAssertEqual(try b.summary(), [])
        let relaunched = b.relaunch(folder: folder, root: root, clock: clock, name: "B")
        clock.advance()
        await relaunched.sync()
        XCTAssertEqual(try b.summary().count, 13)
        XCTAssertEqual(try b.summary(), try a.summary())
    }

    @MainActor
    func testSameProjectCreatedOnBothMacs() async throws {
        let a = try mac("A"), b = try mac("B")
        await a.sync.turnOn()
        await b.sync.turnOn()
        XCTAssertTrue(a.sync.isWaiting && b.sync.isWaiting)
        let alphaA = try a.addProject("Alpha")
        try a.addEntry(alphaA, on: day(9, 22), 8, 12)
        await a.sync.startWithThisMacsData()
        XCTAssertFalse(a.sync.isWaiting)
        clock.advance()
        let alphaB = try b.addProject("alpha")
        try b.addEntry(alphaB, on: day(9, 22), 13, 17)
        b.timer.start(project: alphaB, at: time(day(9, 22), 17))

        await syncAll(a, b)
        XCTAssertEqual(try a.summary(), try b.summary())
        XCTAssertEqual(try a.projects().map(\.name), ["Alpha"])
        XCTAssertEqual(try a.entries().count, 2)
        XCTAssertEqual(try b.entries().compactMap(\.project?.name), ["Alpha", "Alpha"])
        XCTAssertEqual(b.timer.project(in: b.context)?.name, "Alpha", "the timer moved to the remaining project")
    }

    /// The race from the review: the empty Mac turns sync on before the other Mac's file
    /// has arrived. It waits instead of starting over with nothing, which would have
    /// replaced the other Mac's data and preferences.
    @MainActor
    func testEmptyMacWaitsForTheOthersData() async throws {
        let a = try mac("A"), b = try mac("B")
        await b.sync.turnOn()
        XCTAssertTrue(b.sync.isEnabled)
        XCTAssertTrue(b.sync.isWaiting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "B", in: folder).path),
                       "a waiting Mac publishes nothing")

        try a.addEntry(a.addProject("Real"), on: day(9, 22), 8, 12)
        a.preferences.openingBalanceHours = 12.5
        await a.sync.turnOn()
        XCTAssertNil(a.sync.joinRequest)
        await syncAll(b, a)
        XCTAssertNil(a.sync.question)
        XCTAssertNil(b.sync.question)
        XCTAssertFalse(b.sync.isWaiting)
        XCTAssertEqual(try b.summary(), try a.summary())
        XCTAssertEqual(try a.projects().map(\.name), ["Real"])
        XCTAssertEqual(b.preferences.openingBalanceHours, 12.5)
        XCTAssertEqual(a.preferences.openingBalanceHours, 12.5, "the waiting Mac's defaults don't win")

        // Waiting survives a relaunch, and a waiting Mac never goes first on its own.
        let c = try mac("C")
        let otherFolder = root.appendingPathComponent("Elsewhere", isDirectory: true)
        let alone = DeviceSync(folder: otherFolder, ledger: root.appendingPathComponent("C/ledger.json"),
                               device: .init(id: "C", name: "C", appVersion: "test"), defaults: c.defaults,
                               preferences: c.preferences, timer: c.timer)
        alone.connect(container: c.container) { true }
        await alone.turnOn()
        let relaunched = DeviceSync(folder: otherFolder, ledger: root.appendingPathComponent("C/ledger.json"),
                                    device: .init(id: "C", name: "C", appVersion: "test"), defaults: c.defaults,
                                    preferences: c.preferences, timer: c.timer)
        relaunched.connect(container: c.container) { true }
        XCTAssertTrue(relaunched.isWaiting)
        try c.addProject("First")
        await relaunched.sync()
        XCTAssertTrue(relaunched.isWaiting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "C", in: otherFolder).path))
        await relaunched.startWithThisMacsData()
        XCTAssertFalse(relaunched.isWaiting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "C", in: otherFolder).path))
    }

    /// Going first is refused while another Mac's file can't be read: it may hold the data.
    @MainActor
    func testUnreadableFileBlocksGoingFirst() async throws {
        let a = try mac("A")
        try a.addProject("Real")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: SyncFolder.fileURL(device: "B", in: folder))
        await a.sync.turnOn()
        XCTAssertFalse(a.sync.isEnabled)
        XCTAssertNotNil(a.sync.errorMessage)
    }

    /// The default schedule is the same at every launch, so a Mac that never edited it
    /// doesn't send a "new" default that undoes another Mac's schedule.
    func testDefaultScheduleIsStable() throws {
        XCTAssertEqual(WorkSchedule.defaultPeriod.id, UUID(uuidString: "6F2C3A1E-0000-4000-8000-000000000001"))
        XCTAssertEqual(WorkSchedule(periods: []), WorkSchedule.standard)
    }

    /// Records a newer version wrote (an absence type or preference this one doesn't
    /// know) are left alone: not written, not "deleted", not rewritten as changed.
    @MainActor
    func testRecordsFromANewerVersionAreLeftAlone() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addProject("Alpha")
        await a.sync.turnOn()
        await b.sync.turnOn()

        // A newer A adds an absence of a type B doesn't know, and a new preference.
        let url = SyncFolder.fileURL(device: "A", in: folder)
        var snapshot = try JSONDecoder().decode(DeviceSnapshot.self, from: Data(contentsOf: url))
        let version = SyncVersion(time: snapshot.clock + 10, device: "A")
        snapshot.records.append(SyncRecord(id: UUID().uuidString, version: version, payload: .absence(AbsenceRecord(
            day: day(9, 25), isHalfDay: false, type: "sabbatical", category: nil, categoryRule: nil)), isDeleted: false))
        snapshot.records.append(SyncRecord(id: "setting.futureThing", version: version, payload: .setting(.flag(true)), isDeleted: false))
        snapshot.clock += 10
        try DeviceSnapshot.encoder().encode(snapshot).write(to: url)

        await syncAll(b)
        XCTAssertEqual(try b.absences().count, 0, "not stored as some other type")
        let published = try JSONDecoder().decode(DeviceSnapshot.self, from: Data(contentsOf: SyncFolder.fileURL(device: "B", in: folder)))
        let foreign = published.records.filter { $0.id == "setting.futureThing" || $0.kind == .absence }
        XCTAssertEqual(foreign.count, 2)
        XCTAssertTrue(foreign.allSatisfy { !$0.isDeleted && $0.version == version }, "passed on unchanged")
    }

    /// A database file swapped for another one (another folder's database chosen in
    /// Settings ▸ Storage, a Time Machine restore) isn't taken as a pile of edits.
    @MainActor
    func testSwappedDatabaseAsksFirst() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        try a.addEntry(alpha, on: day(9, 22), 8, 12)
        try a.addEntry(alpha, on: day(9, 23), 8, 12)
        let store = root.appendingPathComponent("A.store")
        try Data("one".utf8).write(to: store)
        a.sync.connect(container: a.container, storeURL: store) { true }
        await a.sync.turnOn()
        await b.sync.turnOn()

        // Moved to a new file with the same content: nothing to ask.
        try FileManager.default.removeItem(at: store)
        try Data("two".utf8).write(to: store)
        clock.advance()
        await a.sync.sync()
        XCTAssertNil(a.sync.question)

        // Another file with older content: an entry it lacks, one it has differently.
        try FileManager.default.removeItem(at: store)
        try Data("three".utf8).write(to: store)
        let entries = try a.entries()
        a.context.delete(entries[0])
        entries[1].note = "old"
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        XCTAssertEqual(a.sync.question, .otherDatabase(changes: 2))
        await b.sync.sync()
        XCTAssertEqual(try b.entries().count, 2, "nothing reached the other Mac")

        await a.sync.answerShown(.useSyncedData)
        XCTAssertNil(a.sync.question)
        XCTAssertEqual(try a.summary(), try b.summary())
        XCTAssertEqual(try a.entries().map(\.note), ["", ""])
    }

    /// Taking over the other Macs' data keeps the project the timer runs for.
    @MainActor
    func testJoiningKeepsTheTimersProject() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addProject("Real")
        await a.sync.turnOn()
        let mine = try b.addProject("Mine")
        b.timer.start(project: mine, at: time(day(9, 22), 8))
        await b.sync.turnOn()
        await b.sync.join(.useOtherMacs)
        XCTAssertEqual(b.timer.project(in: b.context)?.name, "Mine")
        await syncAll(b, a)
        XCTAssertEqual(try a.projects().map(\.name), ["Mine", "Real"], "and it syncs like a new project")
    }

    /// Combining keeps both sides' items; preferences come from the Macs already
    /// syncing, and this Mac's previous ones are saved next to the backups.
    @MainActor
    func testCombiningKeepsBothSidesAndSavesReplacedSettings() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addEntry(a.addProject("Real"), on: day(9, 22), 8, 12)
        await a.sync.turnOn()
        try b.addEntry(b.addProject("Mine"), on: day(9, 23), 8, 12)
        b.preferences.vacationEntitlement = 30
        await b.sync.turnOn()
        await b.sync.join(.combine)
        await syncAll(a, b)
        XCTAssertEqual(try a.projects().map(\.name), ["Mine", "Real"])
        XCTAssertEqual(try b.summary(), try a.summary())
        XCTAssertEqual(b.preferences.vacationEntitlement, 25)
        XCTAssertNotNil(b.sync.notice)
        let saved = try FileManager.default.contentsOfDirectory(at: b.backupFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(saved.count, 1)
        let values = try JSONDecoder().decode([String: SettingValue].self, from: Data(contentsOf: saved[0]))
        XCTAssertEqual(values["setting.vacationEntitlement"], .number(30))
    }

    /// Two Macs that each started with their own data without seeing each other end
    /// up with both.
    @MainActor
    func testMacsThatStartedApartMergeLater() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addEntry(a.addProject("Alpha"), on: day(9, 22), 8, 12)
        await a.sync.turnOn()
        let aside = root.appendingPathComponent("aside.json")
        try FileManager.default.moveItem(at: SyncFolder.fileURL(device: "A", in: folder), to: aside)
        try b.addEntry(b.addProject("Beta"), on: day(9, 23), 8, 12)
        await b.sync.turnOn()
        XCTAssertNil(b.sync.joinRequest, "B saw no other Mac")
        try FileManager.default.moveItem(at: aside, to: SyncFolder.fileURL(device: "A", in: folder))
        await syncAll(a, b)
        XCTAssertNil(a.sync.question)
        XCTAssertNil(b.sync.question)
        XCTAssertEqual(try a.projects().map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(try b.summary(), try a.summary())
    }

    /// Answers are checked against the situation again: when more is at stake than
    /// when the user answered, sync asks again.
    @MainActor
    func testAnswersAreCheckedAgain() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...15 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        try a.addProject("Beta")
        await a.sync.turnOn()
        await b.sync.turnOn()

        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        XCTAssertEqual(a.sync.question, .missingItems(count: 15))
        // Meanwhile one more item goes.
        try a.context.delete(XCTUnwrap(a.projects().first { $0.name == "Beta" }))
        try a.context.save()
        await a.sync.answerShown(.deleteEverywhere)
        XCTAssertEqual(a.sync.question, .missingItems(count: 16), "asked again")
        clock.advance()
        await b.sync.sync()
        XCTAssertEqual(try b.entries().count, 15, "nothing deleted yet")

        // A question goes away by itself when it no longer applies.
        a.sync.connect(container: a.container) { true }
        for date in 1...15 { try a.addEntry(alpha, on: day(10, date), 8, 12) }
        await a.sync.sync()
        XCTAssertEqual(a.sync.question, .missingItems(count: 16))
        await a.sync.answerShown(.restoreMissing)
        XCTAssertNil(a.sync.question)
        XCTAssertEqual(try a.entries().count, 30)
    }

    /// Without a backup, sync deletes nothing in bulk.
    @MainActor
    func testFailedBackupBlocksDeleting() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...15 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()
        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        await a.sync.answerShown(.deleteEverywhere)

        b.backupsWork = false
        clock.advance()
        await b.sync.sync()
        await b.sync.answerShown(.deleteHereToo)
        XCTAssertNotNil(b.sync.errorMessage)
        XCTAssertEqual(try b.entries().count, 15)
        b.backupsWork = true
        await b.sync.sync()
        XCTAssertEqual(try b.entries().count, 0, "the answer still holds")
    }

    /// "Use the Synced Data" for a swapped database makes it match the synced data
    /// exactly: rows only that file has (an older copy's) don't spread.
    @MainActor
    func testSyncedDataReplacesASwappedDatabase() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        try a.addEntry(alpha, on: day(9, 22), 8, 12)
        let store = root.appendingPathComponent("A.store")
        try Data("one".utf8).write(to: store)
        a.sync.connect(container: a.container, storeURL: store, backupFolder: a.backupFolder) { true }
        await a.sync.turnOn()
        await b.sync.turnOn()

        // An older copy: different rows (other sync IDs), the synced entry missing.
        try FileManager.default.removeItem(at: store)
        try Data("old".utf8).write(to: store)
        for entry in try a.entries() { a.context.delete(entry) }
        try a.addEntry(alpha, on: day(9, 1), 8, 9, note: "old")
        try a.addEntry(alpha, on: day(9, 2), 8, 9, note: "old")
        clock.advance()
        await a.sync.sync()
        XCTAssertEqual(a.sync.question, .otherDatabase(changes: 1))
        await a.sync.answerShown(.useSyncedData)
        await syncAll(a, b)
        XCTAssertEqual(try a.entries().map(\.note), [""])
        XCTAssertEqual(try b.summary(), try a.summary())
    }

    /// After restoring a backup, the "send everything as it is" mode survives a sync
    /// that fails and a relaunch.
    @MainActor
    func testRestoreModeSurvivesAFailedSync() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...12 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()
        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        DeviceSync.prepareForRestore(defaults: a.defaults)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        let first = a.relaunch(folder: folder, root: root, clock: clock, name: "A")
        await first.sync()
        XCTAssertNotNil(first.errorMessage)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

        let second = a.relaunch(folder: folder, root: root, clock: clock, name: "A")
        clock.advance()
        await second.sync()
        XCTAssertNil(second.question, "still sent as restored, not asked about")
        XCTAssertNil(second.errorMessage)
    }

    /// Combining after a break doesn't undo what the other Macs did meanwhile: their
    /// deletions and newer edits stay; only this Mac's new items are added.
    @MainActor
    func testRejoiningDoesNotUndoTheOtherMacs() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...30 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()
        b.sync.turnOff()

        let entries = try a.entries()
        for entry in entries.prefix(12) { a.context.delete(entry) }
        for entry in entries.suffix(5) { entry.note = "fixed" }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        await a.sync.answerShown(.deleteEverywhere)
        XCTAssertEqual(try a.entries().count, 18)

        try b.addEntry(XCTUnwrap(b.projects().first), on: day(10, 1), 8, 9, note: "new on B")
        await b.sync.turnOn()
        XCTAssertNotNil(b.sync.joinRequest)
        await b.sync.join(.combine)
        XCTAssertEqual(b.backups, 1, "B's own items changed, so it backed up first")
        await syncAll(a, b)
        XCTAssertNil(a.sync.question)
        XCTAssertEqual(try a.entries().count, 19)
        XCTAssertEqual(try a.entries().filter { $0.note == "fixed" }.count, 5)
        XCTAssertEqual(try a.entries().filter { $0.note == "new on B" }.count, 1)
        XCTAssertEqual(try b.summary(), try a.summary())
    }

    /// Whenever another Mac's preferences replace this Mac's, a copy is kept; meeting a
    /// Mac for the first time says so.
    @MainActor
    func testReplacedSettingsAreAlwaysKept() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addProject("Alpha")
        a.preferences.vacationEntitlement = 30
        await a.sync.turnOn()
        // B starts without seeing A.
        let aside = root.appendingPathComponent("aside.json")
        try FileManager.default.moveItem(at: SyncFolder.fileURL(device: "A", in: folder), to: aside)
        clock.advance()
        try b.addProject("Beta")
        await b.sync.turnOn()
        try FileManager.default.moveItem(at: aside, to: SyncFolder.fileURL(device: "A", in: folder))
        await syncAll(a, b)
        XCTAssertEqual(a.preferences.vacationEntitlement, b.preferences.vacationEntitlement)
        let loser = a.preferences.vacationEntitlement == 30 ? b : a
        XCTAssertNotNil(loser.sync.notice)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: loser.backupFolder.path).count, 1)

        // A later change from the other Mac: kept as well, without a notice.
        loser.sync.notice = nil
        let winner = loser === a ? b : a
        winner.preferences.openingBalanceHours = 4
        await syncAll(winner, loser)
        XCTAssertEqual(loser.preferences.openingBalanceHours, 4)
        XCTAssertNil(loser.sync.notice)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: loser.backupFolder.path).count, 2)
    }

    /// Two questions in one sync are asked one after the other, not in a loop.
    @MainActor
    func testTwoQuestionsAreAnsweredInTurn() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...30 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        for date in 1...30 { try a.addEntry(alpha, on: day(10, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()

        // B deletes October and confirms; A deletes September.
        for entry in try b.entries() where entry.date >= day(10, 1) { b.context.delete(entry) }
        try b.context.save()
        clock.advance()
        await b.sync.sync()
        await b.sync.answerShown(.deleteEverywhere)
        for entry in try a.entries() where entry.date < day(10, 1) { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        XCTAssertEqual(a.sync.question, .missingItems(count: 30))
        await a.sync.answerShown(.deleteEverywhere)
        XCTAssertEqual(a.sync.question, .deletedElsewhere(mac: "B’s Mac", count: 30))
        await a.sync.answerShown(.deleteHereToo)
        XCTAssertNil(a.sync.question)
        XCTAssertEqual(try a.entries().count, 0)
        clock.advance()
        await b.sync.sync()
        XCTAssertEqual(b.sync.question, .deletedElsewhere(mac: "A’s Mac", count: 30))
        await b.sync.answerShown(.deleteHereToo)
        XCTAssertEqual(try b.entries().count, 0)
    }

    /// An answer belongs to the question shown: one that doesn't fit is ignored.
    @MainActor
    func testAnswersBelongToTheirQuestion() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...15 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()
        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        await a.sync.answerShown(.deleteEverywhere)
        clock.advance()
        await b.sync.sync()
        let shown = try XCTUnwrap(b.sync.question)
        await b.sync.answer(.deleteEverywhere, to: shown)
        XCTAssertEqual(b.sync.question, shown, "still asked")
        await b.sync.answer(.keepThem, to: .missingItems(count: 15))
        XCTAssertEqual(b.sync.question, shown)
        XCTAssertEqual(try b.entries().count, 15)
    }

    /// Deletions this Mac once made itself, coming back after its data was restored
    /// outside the app (database and ledger together), are asked about too.
    @MainActor
    func testOwnOldDeletionsAreAskedAbout() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...15 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()
        let ledger = root.appendingPathComponent("A/ledger.json")
        let oldLedger = try Data(contentsOf: ledger)
        let old = try a.entries().map { ($0.syncID!, $0.date, $0.startTime, $0.endTime) }

        for entry in try a.entries() { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        await a.sync.answerShown(.deleteEverywhere)
        await syncAll(b)
        await b.sync.answerShown(.deleteHereToo)

        // Time Machine brings back A's database and ledger from before.
        try oldLedger.write(to: ledger)
        for (id, date, start, end) in old {
            let entry = WorkSegment(date: date, startTime: start, endTime: end, project: alpha)
            entry.syncID = id
            a.context.insert(entry)
        }
        try a.context.save()
        let restored = a.relaunch(folder: folder, root: root, clock: clock, name: "A")
        clock.advance()
        await restored.sync()
        XCTAssertEqual(restored.question, .deletedElsewhere(mac: "A’s Mac", count: 15))
        XCTAssertEqual(try a.entries().count, 15)
    }

    /// An answer lapses once its situation is gone, also while another question waits:
    /// different deletions later are asked about anew.
    @MainActor
    func testAnswersLapseWithTheirSituation() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...30 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        for date in 1...12 { try a.addEntry(alpha, on: day(10, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()
        // B deletes October and confirms; A deletes the first twelve of September.
        for entry in try b.entries() where entry.date >= day(10, 1) { b.context.delete(entry) }
        try b.context.save()
        clock.advance()
        await b.sync.sync()
        await b.sync.answerShown(.deleteEverywhere)
        let september = try a.entries().filter { $0.date < day(10, 1) }
        let saved = september.prefix(12).map { ($0.syncID!, $0.date, $0.startTime, $0.endTime) }
        for entry in september.prefix(12) { a.context.delete(entry) }
        try a.context.save()
        clock.advance()
        await a.sync.sync()
        await a.sync.answerShown(.deleteEverywhere)
        XCTAssertEqual(a.sync.question, .deletedElsewhere(mac: "B’s Mac", count: 12))

        // A puts them back, then deletes eleven others by mistake.
        for (id, date, start, end) in saved {
            let entry = WorkSegment(date: date, startTime: start, endTime: end, project: alpha)
            entry.syncID = id
            a.context.insert(entry)
        }
        try a.context.save()
        await a.sync.sync()
        for entry in try a.entries().filter({ $0.date < day(10, 1) }).suffix(11) { a.context.delete(entry) }
        try a.context.save()
        await a.sync.sync()
        XCTAssertEqual(a.sync.question, .missingItems(count: 11), "asked, not covered by the earlier answer")
    }

    /// After a restore, a question about another Mac's deletions doesn't keep the
    /// "send everything" mode alive: later deletions here are asked about.
    @MainActor
    func testRestoreModeEndsBeforeOtherQuestions() async throws {
        let a = try mac("A"), b = try mac("B")
        let alpha = try a.addProject("Alpha")
        for date in 1...30 { try a.addEntry(alpha, on: day(9, date), 8, 12) }
        await a.sync.turnOn()
        await b.sync.turnOn()
        for entry in try b.entries().prefix(12) { b.context.delete(entry) }
        try b.context.save()
        clock.advance()
        await b.sync.sync()
        await b.sync.answerShown(.deleteEverywhere)

        DeviceSync.prepareForRestore(defaults: a.defaults)
        let restored = a.relaunch(folder: folder, root: root, clock: clock, name: "A")
        clock.advance()
        await restored.sync()
        XCTAssertEqual(restored.question, .deletedElsewhere(mac: "B’s Mac", count: 12))
        for entry in try a.entries().suffix(15) { a.context.delete(entry) }
        try a.context.save()
        await restored.sync()
        XCTAssertEqual(restored.question, .missingItems(count: 15))
    }

    /// Ledgers written before a field existed still load.
    @MainActor
    func testOlderLedgersLoad() async throws {
        let a = try mac("A")
        try a.addProject("Alpha")
        await a.sync.turnOn()
        let url = root.appendingPathComponent("A/ledger.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "devices")
        json.removeValue(forKey: "waiting")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let reloaded = a.relaunch(folder: folder, root: root, clock: clock, name: "A")
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertNil(reloaded.notice)
    }

    /// Turning sync off while joining is still under way (here: during the backup)
    /// leaves nothing behind once the step is done.
    @MainActor
    func testTurningOffWhileJoiningCleansUpAfterwards() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addProject("Real")
        await a.sync.turnOn()
        try b.addProject("Test")
        await b.sync.turnOn()
        XCTAssertNotNil(b.sync.joinRequest)
        b.sync.connect(container: b.container) { [weak b] in
            b?.sync.turnOff()
            return true
        }
        await b.sync.join(.useOtherMacs)
        XCTAssertFalse(b.sync.isEnabled)
        XCTAssertFalse(b.sync.isTurnedOnInSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/ledger.json").path))
        for _ in 0..<50 where FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "B", in: folder).path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "B", in: folder).path))
    }

    @MainActor
    func testICloudDriveOffIsReportedNotFakedLocally() async throws {
        let missing = root.appendingPathComponent("No iCloud Drive/Work Tracker Sync", isDirectory: true)
        let defaults = UserDefaults(suiteName: "WorkTrackerTests.off.\(UUID().uuidString)")!
        let sync = DeviceSync(folder: missing, ledger: root.appendingPathComponent("off/ledger.json"),
                              device: .init(id: "A", name: "A", appVersion: "test"), defaults: defaults,
                              preferences: Preferences(defaults: defaults), timer: WorkTimer(defaults: defaults))
        sync.connect(container: try inMemoryContainer()) { true }
        await sync.turnOn()
        XCTAssertFalse(sync.isEnabled)
        XCTAssertNotNil(sync.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))

        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertTrue(SyncFolder.isPermissionDenied(denied))
        XCTAssertTrue(SyncFolder.isPermissionDenied(CocoaError(.fileReadNoPermission)))
        XCTAssertFalse(SyncFolder.isPermissionDenied(CocoaError(.fileReadCorruptFile)))
    }

    @MainActor
    func testTurningOffRemovesThisMacsFile() async throws {
        let a = try mac("A"), b = try mac("B")
        try a.addProject("Alpha")
        await a.sync.turnOn()
        await b.sync.turnOn()
        await syncAll(a, b)
        XCTAssertEqual(a.sync.otherMacs.count, 1)

        b.sync.turnOff()
        XCTAssertFalse(b.sync.isEnabled)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "B", in: folder).path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncFolder.fileURL(device: "B", in: folder).path))
        await a.sync.sync()
        XCTAssertEqual(a.sync.otherMacs.count, 0)
        XCTAssertEqual(try b.projects().map(\.name), ["Alpha"], "B keeps its data")

        // A ledger that went missing turns sync off rather than guessing.
        let fresh = DeviceSync(folder: folder, ledger: root.appendingPathComponent("missing/ledger.json"),
                               device: .init(id: "A", name: "A", appVersion: "test"), defaults: a.defaults,
                               preferences: a.preferences, timer: a.timer)
        XCTAssertFalse(fresh.isEnabled)
        XCTAssertNotNil(fresh.notice)
    }
}
