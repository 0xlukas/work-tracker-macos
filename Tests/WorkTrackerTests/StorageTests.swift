import XCTest
import SQLite3
import SwiftData
@testable import WorkTracker

final class MigrationTests: XCTestCase {
    @MainActor
    func testV1Migration() throws {
        let url = try temporaryDirectory(self).appendingPathComponent("v1.store")
        do {
            let legacy = try ModelContainer(for: Schema(versionedSchema: WorkTrackerSchemaV1.self), configurations: ModelConfiguration(url: url))
            legacy.mainContext.insert(WorkTrackerSchemaV1.VacationDay(date: day(9, 22), isHalfDay: true))
            try legacy.mainContext.save()
        }
        let migrated = try ModelContainer.workTracker(url: url)
        let absence = try XCTUnwrap(migrated.mainContext.fetch(FetchDescriptor<VacationDay>()).first)
        XCTAssertEqual(absence.resolvedType, .vacation)
        XCTAssertTrue(absence.isHalfDay)
        XCTAssertNil(absence.category)
    }

    @MainActor
    func testV2Migration() throws {
        let url = try temporaryDirectory(self).appendingPathComponent("v2.store")
        do {
            let legacy = try ModelContainer(for: Schema(versionedSchema: WorkTrackerSchemaV2.self), configurations: ModelConfiguration(url: url))
            legacy.mainContext.insert(WorkTrackerSchemaV2.VacationDay(date: day(9, 21), type: nil))
            legacy.mainContext.insert(WorkTrackerSchemaV2.VacationDay(date: day(9, 22), type: .sick))
            legacy.mainContext.insert(WorkTrackerSchemaV2.VacationDay(date: day(9, 23), type: .service))
            try legacy.mainContext.save()
        }
        let migrated = try ModelContainer.workTracker(url: url)
        let days = try migrated.mainContext.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)]))
        XCTAssertEqual(days.map(\.resolvedType), [.vacation, .sick, .service])
    }

    /// V3 → V4: custom entries get `.custom`, projects keep their old colour, duplicate
    /// days are removed, and new fields get their defaults.
    @MainActor
    func testV3Migration() throws {
        let url = try temporaryDirectory(self).appendingPathComponent("v3.store")
        do {
            let legacy = try ModelContainer(for: Schema(versionedSchema: WorkTrackerSchemaV3.self), configurations: ModelConfiguration(url: url))
            let context = legacy.mainContext
            let project = WorkTrackerSchemaV3.Project(name: "Kunde A")
            context.insert(project)
            context.insert(WorkTrackerSchemaV3.WorkSegment(date: day(9, 22), startTime: time(day(9, 22), 8),
                                                           endTime: time(day(9, 22), 12), project: project))
            let category = WorkTrackerSchemaV3.AbsenceCategory(name: "Training", rule: "unchanged")
            context.insert(category)
            let customDay = WorkTrackerSchemaV3.VacationDay(date: day(9, 23), type: .service)
            customDay.category = category
            customDay.categoryRuleRaw = "holiday"
            context.insert(customDay)
            context.insert(WorkTrackerSchemaV3.VacationDay(date: day(9, 24), type: .sick))
            context.insert(WorkTrackerSchemaV3.VacationDay(date: day(9, 24), type: .vacation))
            try context.save()
        }

        let migrated = try ModelContainer.workTracker(url: url)
        let context = migrated.mainContext
        let project = try XCTUnwrap(context.fetch(FetchDescriptor<Project>()).first)
        XCTAssertEqual(project.colorRaw, Project.legacyColor(for: "Kunde A").rawValue)
        XCTAssertFalse(project.isArchived)
        let segment = try XCTUnwrap(context.fetch(FetchDescriptor<WorkSegment>()).first)
        XCTAssertEqual(segment.note, "")
        XCTAssertEqual(segment.durationHours, 4)

        let absences = try context.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)]))
        XCTAssertEqual(absences.count, 2, "duplicate day removed")
        let custom = try XCTUnwrap(absences.first { $0.category != nil })
        XCTAssertEqual(custom.type, .custom)
        XCTAssertEqual(custom.entry.category.rule, .reduceHours, "rule snapshot kept")
        XCTAssertEqual(custom.categoryDetails.name, "Training")
    }

    /// V4 → V5: every project, entry and absence gets its own sync ID; nothing else changes.
    @MainActor
    func testV4Migration() throws {
        let url = try temporaryDirectory(self).appendingPathComponent("v4.store")
        do {
            let legacy = try ModelContainer(for: Schema(versionedSchema: WorkTrackerSchemaV4.self), configurations: ModelConfiguration(url: url))
            let context = legacy.mainContext
            let project = WorkTrackerSchemaV4.Project(name: "Kunde A")
            project.colorRaw = PaletteColor.green.rawValue
            context.insert(project)
            for hour in [8, 13] {
                context.insert(WorkTrackerSchemaV4.WorkSegment(date: day(9, 22), startTime: time(day(9, 22), hour),
                                                               endTime: time(day(9, 22), hour + 2), project: project))
            }
            let category = WorkTrackerSchemaV4.AbsenceCategory(name: "Training", rule: "unchanged")
            context.insert(category)
            let customDay = WorkTrackerSchemaV4.VacationDay(date: day(9, 23), type: .custom)
            customDay.category = category
            context.insert(customDay)
            context.insert(WorkTrackerSchemaV4.VacationDay(date: day(9, 24), isHalfDay: true, type: .sick))
            try context.save()
        }

        let migrated = try ModelContainer.workTracker(url: url)
        let context = migrated.mainContext
        let project = try XCTUnwrap(context.fetch(FetchDescriptor<Project>()).first)
        let segments = try context.fetch(FetchDescriptor<WorkSegment>())
        let absences = try context.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)]))
        XCTAssertEqual(project.color, .green)
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { $0.project === project && $0.durationHours == 2 })
        XCTAssertEqual(absences.map(\.resolvedType), [.custom, .sick])
        XCTAssertEqual(absences.first?.category?.name, "Training")
        let ids = [project.syncID] + segments.map(\.syncID) + absences.map(\.syncID)
        XCTAssertFalse(ids.contains(nil))
        XCTAssertEqual(Set(ids).count, 5, "each row has its own ID")
    }

    @MainActor
    func testCategoryRuleSnapshotSurvivesEdits() throws {
        let url = try temporaryDirectory(self).appendingPathComponent("v4.store")
        do {
            let container = try ModelContainer.workTracker(url: url)
            let context = container.mainContext
            let category = AbsenceCategory(name: "Training", rule: .reduceHours)
            context.insert(category)
            let absence = VacationDay(date: day(9, 24))
            absence.assign(.custom(category))
            context.insert(absence)
            category.name = "Study"
            category.ruleRaw = AbsenceCountingRule.unchanged.rawValue
            category.isArchived = true
            try context.save()
        }
        let reopened = try ModelContainer.workTracker(url: url)
        let absence = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<VacationDay>()).first)
        XCTAssertEqual(absence.category?.name, "Study")
        XCTAssertEqual(absence.entry.category.rule, .reduceHours)
        XCTAssertEqual(WorkHoursCalculator(absences: VacationDay.lookup([absence])).classify(date: absence.date).expectedHours, 0)

        let newDay = VacationDay(date: day(9, 25))
        newDay.assign(.custom(absence.category!))
        XCTAssertEqual(newDay.entry.category.rule, .unchanged)
        newDay.assign(.builtIn(.sick))
        XCTAssertNil(newDay.category)
        XCTAssertNil(newDay.categoryRuleRaw)
        XCTAssertEqual(newDay.resolvedType, .sick)
    }

    /// Set WORK_TRACKER_TEST_STORE to a standalone snapshot of a real store to check that
    /// it migrates without losing entries or hours.
    @MainActor
    func testExistingStoreCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["WORK_TRACKER_TEST_STORE"] else {
            throw XCTSkip("Set WORK_TRACKER_TEST_STORE to validate a copy of an existing store.")
        }
        let source = URL(fileURLWithPath: path)
        var before: (segments: Int32, absences: Int32, hours: Double) = (0, 0, 0)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        func scalar(_ sql: String) -> Double {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return sqlite3_column_double(statement, 0)
        }
        before = (Int32(scalar("SELECT COUNT(*) FROM ZWORKSEGMENT")), Int32(scalar("SELECT COUNT(*) FROM ZVACATIONDAY")),
                  scalar("SELECT TOTAL(ZDURATIONHOURS) FROM ZWORKSEGMENT"))
        sqlite3_close(db)

        let store = try temporaryDirectory(self).appendingPathComponent("WorkTracker.store")
        try FileManager.default.copyItem(at: source, to: store)
        let container = try ModelContainer.workTracker(url: store)
        let context = container.mainContext
        let segments = try context.fetch(FetchDescriptor<WorkSegment>())
        XCTAssertEqual(segments.count, Int(before.segments))
        XCTAssertEqual(segments.reduce(0) { $0 + $1.durationHours }, before.hours, accuracy: 0.0001)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VacationDay>()), Int(before.absences))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Project>()).allSatisfy { $0.colorRaw != nil })
        let ids = try context.fetch(FetchDescriptor<Project>()).map(\.syncID) + segments.map(\.syncID)
            + context.fetch(FetchDescriptor<VacationDay>()).map(\.syncID)
        XCTAssertFalse(ids.contains(nil), "every row has a sync ID")
        XCTAssertEqual(Set(ids).count, ids.count)

        // A type added after the store was created must still save and load.
        context.insert(VacationDay(date: day(2030, 9, 23), type: .unpaid))
        try context.save()
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<VacationDay>()), Int(before.absences) + 1)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<VacationDay>()).contains { $0.resolvedType == .unpaid })
    }
}

final class BackupTests: XCTestCase {
    private func makeWALStore(in root: URL) throws -> (URL, OpaquePointer?) {
        let store = root.appendingPathComponent("test.store")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE sample(value); INSERT INTO sample VALUES (42);", nil, nil, nil), SQLITE_OK)
        return (store, db)
    }

    private func value(in snapshot: URL) -> Int32 {
        var copy: OpaquePointer?
        defer { sqlite3_close(copy) }
        guard sqlite3_open(snapshot.path, &copy) == SQLITE_OK else { return -1 }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(copy, "SELECT MAX(value) FROM sample", -1, &query, nil) == SQLITE_OK,
              sqlite3_step(query) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(query, 0)
    }

    func testBackupIncludesWALAndRotatesOnlySnapshots() throws {
        let root = try temporaryDirectory(self)
        let (store, db) = try makeWALStore(in: root)
        defer { sqlite3_close(db) }
        let backups = root.appendingPathComponent("backups")
        let now = Date()
        XCTAssertEqual(try DatabaseBackup.create(store: store, directory: backups, now: now), now)
        XCTAssertNotNil(try DatabaseBackup.create(store: store, directory: backups, now: now.addingTimeInterval(3600)))
        XCTAssertEqual(try DatabaseBackup.snapshots(in: backups).count, 1)
        XCTAssertEqual(value(in: try XCTUnwrap(DatabaseBackup.snapshots(in: backups).first)), 42)

        let manual = backups.appendingPathComponent("manual.store")
        try Data("keep".utf8).write(to: manual)
        for offset in 1...32 {
            sqlite3_exec(db, "INSERT INTO sample VALUES (\(100 + offset));", nil, nil, nil)
            _ = try DatabaseBackup.create(store: store, directory: backups, now: now.addingTimeInterval(Double(offset) * 86400))
        }
        XCTAssertEqual(try DatabaseBackup.snapshots(in: backups).count, 30)
        XCTAssertEqual(value(in: try XCTUnwrap(DatabaseBackup.snapshots(in: backups).first)), 132)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path))
        XCTAssertThrowsError(try DatabaseBackup.create(store: root, directory: backups, force: true))
        XCTAssertEqual(try DatabaseBackup.snapshots(in: backups).count, 30)
    }

    /// Snapshots are single files: no WAL/SHM or temporary files are left behind, and
    /// stale temporary files from an interrupted run are cleaned up.
    func testNoSidecarOrTemporaryFilesRemain() throws {
        let root = try temporaryDirectory(self)
        let (store, db) = try makeWALStore(in: root)
        defer { sqlite3_close(db) }
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stale = backups.appendingPathComponent(".pending-OLD-wal")
        try Data().write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)

        try DatabaseBackup.create(store: store, directory: backups)
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(names.count, 1, "\(names)")
        XCTAssertTrue(names[0].hasPrefix("backup-"))
        XCTAssertEqual(value(in: backups.appendingPathComponent(names[0])), 42)
    }

    /// Unchanged data re-dates the latest snapshot instead of adding a copy.
    func testUnchangedDataDoesNotAddSnapshots() throws {
        let root = try temporaryDirectory(self)
        let (store, db) = try makeWALStore(in: root)
        defer { sqlite3_close(db) }
        let backups = root.appendingPathComponent("backups")
        let now = Date()
        for offset in 0..<5 {
            try DatabaseBackup.create(store: store, directory: backups, now: now.addingTimeInterval(Double(offset) * 86400))
        }
        let snapshots = try DatabaseBackup.snapshots(in: backups)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(DatabaseBackup.modificationDate(of: snapshots[0])!.timeIntervalSince1970,
                       now.addingTimeInterval(4 * 86400).timeIntervalSince1970, accuracy: 1)
    }

    func testMirrorCopiesLatestAndRotates() throws {
        let root = try temporaryDirectory(self)
        let (store, db) = try makeWALStore(in: root)
        defer { sqlite3_close(db) }
        let backups = root.appendingPathComponent("backups")
        let mirror = root.appendingPathComponent("mirror")
        let now = Date()
        for offset in 0..<33 {
            sqlite3_exec(db, "INSERT INTO sample VALUES (\(offset));", nil, nil, nil)
            try DatabaseBackup.create(store: store, directory: backups, now: now.addingTimeInterval(Double(offset) * 86400))
            try DatabaseBackup.mirror(from: backups, to: mirror)
        }
        let mirrored = try DatabaseBackup.snapshots(in: mirror)
        XCTAssertEqual(mirrored.count, 30)
        XCTAssertEqual(mirrored.first?.lastPathComponent, try DatabaseBackup.snapshots(in: backups).first?.lastPathComponent)
    }
}

final class StoreLocationTests: XCTestCase {
    private var savedDirectory: URL?

    override func setUp() {
        savedDirectory = StoreLocation.customDirectory
    }

    override func tearDown() {
        StoreLocation.customDirectory = savedDirectory
    }

    private func makeStore(in directory: URL, value: Int) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = StoreLocation.storeURL(in: directory)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE sample(value); INSERT INTO sample VALUES (\(value));", nil, nil, nil)
        return store
    }

    private func value(at store: URL) -> Int32 {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(store.path, &db) == SQLITE_OK else { return -1 }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM sample", -1, &query, nil) == SQLITE_OK,
              sqlite3_step(query) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(query, 0)
    }

    func testMoveCopiesSnapshot() throws {
        let root = try temporaryDirectory(self)
        let source = try makeStore(in: root.appendingPathComponent("old"), value: 7)
        let target = root.appendingPathComponent("new")
        try StoreLocation.moveStore(to: target, from: source, backupsRoot: root)
        XCTAssertEqual(value(at: StoreLocation.storeURL(in: target)), 7)
        XCTAssertEqual(StoreLocation.customDirectory?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(value(at: source), 7, "old copy left in place")
    }

    /// The old code kept an existing store but copied the current WAL next to it.
    func testMoveRefusesExistingStore() throws {
        let root = try temporaryDirectory(self)
        let source = try makeStore(in: root.appendingPathComponent("old"), value: 1)
        let target = root.appendingPathComponent("new")
        _ = try makeStore(in: target, value: 2)
        StoreLocation.customDirectory = nil
        XCTAssertThrowsError(try StoreLocation.moveStore(to: target, from: source, backupsRoot: root)) {
            XCTAssertEqual($0 as? StoreLocation.MoveError, .destinationHasStore)
        }
        XCTAssertNil(StoreLocation.customDirectory)
        XCTAssertEqual(value(at: StoreLocation.storeURL(in: target)), 2)
    }

    func testMoveReplaceKeepsOldFileAside() throws {
        let root = try temporaryDirectory(self)
        let source = try makeStore(in: root.appendingPathComponent("old"), value: 1)
        let target = root.appendingPathComponent("new")
        _ = try makeStore(in: target, value: 2)
        try StoreLocation.moveStore(to: target, existing: .replace, from: source, backupsRoot: root)
        XCTAssertEqual(value(at: StoreLocation.storeURL(in: target)), 1)
        let aside = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(value(at: aside[0].appendingPathComponent(StoreLocation.fileName)), 2)
    }

    func testMoveUseExistingSwitchesWithoutCopy() throws {
        let root = try temporaryDirectory(self)
        let source = try makeStore(in: root.appendingPathComponent("old"), value: 1)
        let target = root.appendingPathComponent("new")
        _ = try makeStore(in: target, value: 2)
        try StoreLocation.moveStore(to: target, existing: .useExisting, from: source, backupsRoot: root)
        XCTAssertEqual(value(at: StoreLocation.storeURL(in: target)), 2)
        XCTAssertEqual(StoreLocation.customDirectory?.standardizedFileURL, target.standardizedFileURL)
    }

    func testOrphanedWALIsMovedAsideBeforeCopy() throws {
        let root = try temporaryDirectory(self)
        let source = try makeStore(in: root.appendingPathComponent("old"), value: 5)
        let target = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: target.appendingPathComponent(StoreLocation.fileName + "-wal"))
        try StoreLocation.moveStore(to: target, from: source, backupsRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(StoreLocation.fileName + "-wal").path))
        XCTAssertEqual(value(at: StoreLocation.storeURL(in: target)), 5)
    }

    func testStagedRestoreReplacesStore() throws {
        let root = try temporaryDirectory(self)
        let live = try makeStore(in: root.appendingPathComponent("live"), value: 1)
        let snapshot = root.appendingPathComponent("snapshot.store")
        try DatabaseBackup.copyDatabase(from: try makeStore(in: root.appendingPathComponent("other"), value: 9), to: snapshot)

        StoreLocation.stageRestore(of: snapshot)
        StoreLocation.applyPendingRestore(to: live, backupsRoot: root)
        XCTAssertEqual(value(at: live), 9)
        XCTAssertNotNil(StoreLocation.takeRestoreResult())
        // The replaced database is kept.
        let aside = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(value(at: aside[0].appendingPathComponent(StoreLocation.fileName)), 1)
        // Applying again without a staged restore does nothing.
        StoreLocation.applyPendingRestore(to: live, backupsRoot: root)
        XCTAssertEqual(value(at: live), 9)
    }

    func testCloudFolderDetection() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(StoreLocation.isCloudSynced(home.appendingPathComponent("Library/CloudStorage/GoogleDrive-x/My Drive/HR")))
        XCTAssertTrue(StoreLocation.isCloudSynced(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x")))
        XCTAssertFalse(StoreLocation.isCloudSynced(StoreLocation.defaultDirectory))
    }
}
