import Foundation

// The data that syncs between Macs, independent of SwiftData. Each Mac keeps a ledger
// (`SyncState`): every record it knows with the version of its last change, deleted
// records included. Macs publish their ledger and merge the others' record by record —
// the higher version wins — so the result is the same whatever order changes arrive in.

/// A project as it syncs.
struct ProjectRecord: Codable, Equatable, Sendable {
    var name: String
    var createdAt: Date
    var color: String?
    var isArchived: Bool
}

/// A time entry as it syncs. The duration follows from start and end.
struct EntryRecord: Codable, Equatable, Sendable {
    var day: Date
    var start: Date
    var end: Date
    var project: String?
    var note: String
}

/// An absence as it syncs.
struct AbsenceRecord: Codable, Equatable, Sendable {
    var day: Date
    var isHalfDay: Bool
    var type: String?
    var category: String?
    var categoryRule: String?
}

/// A custom absence category as it syncs.
struct CategoryRecord: Codable, Equatable, Sendable {
    var name: String
    var icon: String
    var color: String
    var rule: String
    var isArchived: Bool
}

/// One synced preference (see `SyncDatabase.settingKeys`).
enum SettingValue: Equatable, Sendable {
    case date(Date)
    case number(Double)
    case flag(Bool)
    case schedule(WorkSchedule)
}

enum SyncKind: String, Codable, Sendable, CaseIterable {
    case category, project, entry, absence, setting
}

enum SyncPayload: Equatable, Sendable {
    case project(ProjectRecord)
    case entry(EntryRecord)
    case absence(AbsenceRecord)
    case category(CategoryRecord)
    case setting(SettingValue)

    var kind: SyncKind {
        switch self {
        case .project: return .project
        case .entry: return .entry
        case .absence: return .absence
        case .category: return .category
        case .setting: return .setting
        }
    }
}

/// When and where a record last changed. Later times win; the device breaks ties.
struct SyncVersion: Codable, Hashable, Comparable, Sendable {
    /// Milliseconds since 1970 from a hybrid clock (see `SyncState.tick`).
    var time: Int64
    var device: String

    static func < (lhs: SyncVersion, rhs: SyncVersion) -> Bool {
        (lhs.time, lhs.device) < (rhs.time, rhs.device)
    }
}

struct SyncRecord: Equatable, Sendable {
    let id: String
    var version: SyncVersion
    /// The content; deleted records keep their last content, so a record that is still
    /// needed (a project with entries on another Mac) can come back.
    var payload: SyncPayload
    var isDeleted: Bool

    var kind: SyncKind { payload.kind }
}

/// One Mac's ledger.
struct SyncState: Equatable, Sendable {
    /// Last version time issued or seen, so new versions always come later.
    var clock: Int64 = 0
    var records: [String: SyncRecord] = [:]

    /// A new version for a change made now: later than the wall clock and than anything
    /// seen so far, so a change made after receiving another Mac's change always wins.
    mutating func tick(device: String, now: Date) -> SyncVersion {
        clock = max(clock + 1, Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
        return SyncVersion(time: clock, device: device)
    }

    mutating func observe(_ version: SyncVersion) {
        clock = max(clock, version.time)
    }

    var liveRecords: [SyncRecord] { records.values.filter { !$0.isDeleted } }

    /// Live records, other than preferences.
    var liveItemCount: Int { records.values.count { !$0.isDeleted && $0.kind != .setting } }
}

/// The ledger operations. All of them are deterministic, so two Macs holding the same
/// records reach the same result.
enum SyncMerge {
    /// Bring the ledger in line with the local database (`local`: content by ID): new or
    /// changed records get a new version, records missing locally are marked deleted
    /// (unless `deletions` is false: then they stay, and syncing puts them back).
    /// Returns how many records changed.
    /// `foreign`: records this version can't store as they are (see
    /// `SyncDatabase.foreignRecords`); they are left alone.
    @discardableResult
    static func absorb(_ local: [String: SyncPayload], into state: inout SyncState, device: String, now: Date,
                       deletions: Bool = true, ignoring foreign: Set<String> = []) -> Int {
        var changed = 0
        for (id, payload) in local.sorted(by: { $0.key < $1.key }) where !foreign.contains(id) {
            if let existing = state.records[id], !existing.isDeleted, existing.payload == payload { continue }
            state.records[id] = SyncRecord(id: id, version: state.tick(device: device, now: now), payload: payload, isDeleted: false)
            changed += 1
        }
        for id in deletions ? pendingDeletions(local, in: state, ignoring: foreign) : [] {
            let version = state.tick(device: device, now: now)
            state.records[id]?.isDeleted = true
            state.records[id]?.version = version
            changed += 1
        }
        return changed
    }

    /// Items the ledger has but the database no longer does: what `absorb` would delete.
    static func pendingDeletions(_ local: [String: SyncPayload], in state: SyncState,
                                 ignoring foreign: Set<String> = []) -> [String] {
        state.records.values.filter { !$0.isDeleted && local[$0.id] == nil && !foreign.contains($0.id) }.map(\.id).sorted()
    }

    /// Items (not preferences) the database has differently from the ledger: changed,
    /// missing, or there although deleted. Items new to the ledger don't count.
    static func differences(_ local: [String: SyncPayload], from state: SyncState,
                            ignoring foreign: Set<String> = []) -> Int {
        state.records.values.count { record in
            guard record.kind != .setting, !foreign.contains(record.id) else { return false }
            return record.isDeleted ? local[record.id] != nil : local[record.id] != record.payload
        }
    }

    /// Take every remote record that is newer than ours. Returns how many were taken.
    @discardableResult
    static func merge(_ remote: [SyncRecord], into state: inout SyncState) -> Int {
        var taken = 0
        for record in remote {
            state.observe(record.version)
            if let existing = state.records[record.id], existing.version >= record.version { continue }
            state.records[record.id] = record
            taken += 1
        }
        return taken
    }

    /// What resolving changed: projects (and categories) merged into another one with the
    /// same name, by old ID, and every record it marked deleted (merged duplicates).
    struct Resolution: Equatable {
        var merged: [String: String] = [:]
        var removed: Set<String> = []
        var changes = 0
    }

    /// Repair what merging two Macs' changes can produce but the app never creates on its
    /// own: two projects or categories with one name, two absences on one day, the same
    /// entry twice, and entries or absences pointing at something another Mac deleted.
    /// `pinned`: projects that must stay (the one this Mac's timer is running for).
    @discardableResult
    static func resolve(_ state: inout SyncState, device: String, now: Date, pinned: Set<String> = []) -> Resolution {
        var resolution = Resolution()

        func update(_ id: String, _ change: (inout SyncRecord) -> Void) {
            guard var record = state.records[id] else { return }
            let before = record
            change(&record)
            guard record != before else { return }
            record.version = state.tick(device: device, now: now)
            state.records[id] = record
            resolution.changes += 1
        }

        // Projects and categories something still uses come back.
        var needed = pinned
        var neededCategories = Set<String>()
        for record in state.liveRecords {
            if case .entry(let entry) = record.payload, let project = entry.project { needed.insert(project) }
            if case .absence(let absence) = record.payload, let category = absence.category { neededCategories.insert(category) }
        }
        for id in needed.union(neededCategories).sorted() where state.records[id]?.isDeleted == true {
            update(id) { $0.isDeleted = false }
        }

        // One project per name: the oldest stays and takes over the others' entries.
        let projects = state.liveRecords.compactMap { record -> (id: String, project: ProjectRecord)? in
            if case .project(let project) = record.payload { return (record.id, project) }
            return nil
        }
        for group in Dictionary(grouping: projects, by: { normalized($0.project.name) }).values where group.count > 1 {
            let ordered = group.sorted { ($0.project.createdAt, $0.id) < ($1.project.createdAt, $1.id) }
            let survivor = ordered[0]
            for duplicate in ordered.dropFirst() {
                resolution.merged[duplicate.id] = survivor.id
                resolution.removed.insert(duplicate.id)
                update(duplicate.id) { $0.isDeleted = true }
            }
            // Keep it active if any of them was.
            if ordered.contains(where: { !$0.project.isArchived }) {
                update(survivor.id) { record in
                    if case .project(var project) = record.payload {
                        project.isArchived = false
                        record.payload = .project(project)
                    }
                }
            }
        }

        // One category per name, the same way (categories have no creation date).
        let categories = state.liveRecords.compactMap { record -> (id: String, category: CategoryRecord)? in
            if case .category(let category) = record.payload { return (record.id, category) }
            return nil
        }
        for group in Dictionary(grouping: categories, by: { normalized($0.category.name) }).values where group.count > 1 {
            let ordered = group.sorted { $0.id < $1.id }
            for duplicate in ordered.dropFirst() {
                resolution.merged[duplicate.id] = ordered[0].id
                resolution.removed.insert(duplicate.id)
                update(duplicate.id) { $0.isDeleted = true }
            }
        }

        // Re-point entries and absences at the surviving project or category.
        for record in state.liveRecords {
            switch record.payload {
            case .entry(var entry):
                if let project = entry.project, let survivor = resolution.merged[project] {
                    entry.project = survivor
                    update(record.id) { $0.payload = .entry(entry) }
                }
            case .absence(var absence):
                if let category = absence.category, let survivor = resolution.merged[category] {
                    absence.category = survivor
                    update(record.id) { $0.payload = .absence(absence) }
                }
            default:
                break
            }
        }

        // One absence per day, and each entry once (the same times on the same project,
        // added on two Macs). The record with the smallest ID stays, so every Mac keeps
        // the same one, and takes the most recently changed content.
        func keepOne(_ group: [SyncRecord]) {
            guard group.count > 1 else { return }
            let ordered = group.sorted { $0.id < $1.id }
            let newest = group.max { $0.version < $1.version }!
            if newest.id != ordered[0].id {
                update(ordered[0].id) { $0.payload = newest.payload }
            }
            for duplicate in ordered.dropFirst() {
                resolution.removed.insert(duplicate.id)
                update(duplicate.id) { $0.isDeleted = true }
            }
        }
        struct EntryKey: Hashable { let start: Date, end: Date, project: String? }
        var absencesByDay: [Date: [SyncRecord]] = [:]
        var entriesByTime: [EntryKey: [SyncRecord]] = [:]
        for record in state.liveRecords {
            switch record.payload {
            case .absence(let absence): absencesByDay[absence.day.startOfDayZurich, default: []].append(record)
            case .entry(let entry): entriesByTime[EntryKey(start: entry.start, end: entry.end, project: entry.project), default: []].append(record)
            default: break
            }
        }
        absencesByDay.values.forEach(keepOne)
        entriesByTime.values.forEach(keepOne)
        return resolution
    }

    /// Names compare like the app's own duplicate check: ignoring case and diacritics.
    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// What the database needs so that it matches the ledger.
    struct Changes: Equatable {
        /// Records to insert or update.
        var upserts: [SyncRecord] = []
        /// Local records to delete (ID and kind).
        var deletions: [(id: String, kind: SyncKind)] = []

        var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }
        /// Deleted items, other than preferences.
        var deletedItemCount: Int { deletions.count { $0.kind != .setting } }

        static func == (lhs: Changes, rhs: Changes) -> Bool {
            lhs.upserts == rhs.upserts && lhs.deletions.map(\.id) == rhs.deletions.map(\.id)
        }
    }

    /// `replacing`: also delete local records the ledger doesn't know (when this Mac
    /// takes over another Mac's data). Foreign records aren't written.
    static func changes(from local: [String: SyncPayload], to state: SyncState, replacing: Bool = false,
                        ignoring foreign: Set<String> = []) -> Changes {
        var changes = Changes()
        for record in state.records.values.sorted(by: { $0.id < $1.id }) {
            if record.isDeleted {
                if let payload = local[record.id] { changes.deletions.append((record.id, payload.kind)) }
            } else if local[record.id] != record.payload && !foreign.contains(record.id) {
                changes.upserts.append(record)
            }
        }
        if replacing {
            for (id, payload) in local.sorted(by: { $0.key < $1.key }) where state.records[id] == nil && payload.kind != .setting {
                changes.deletions.append((id, payload.kind))
            }
        }
        return changes
    }
}

// MARK: - File format

extension SettingValue: Codable {
    private enum CodingKeys: String, CodingKey { case date, number, flag, schedule }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Date.self, forKey: .date) { self = .date(value) }
        else if let value = try container.decodeIfPresent(Double.self, forKey: .number) { self = .number(value) }
        else if let value = try container.decodeIfPresent(Bool.self, forKey: .flag) { self = .flag(value) }
        else if let value = try container.decodeIfPresent(WorkSchedule.self, forKey: .schedule) { self = .schedule(value) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown setting value")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .date(let value): try container.encode(value, forKey: .date)
        case .number(let value): try container.encode(value, forKey: .number)
        case .flag(let value): try container.encode(value, forKey: .flag)
        case .schedule(let value): try container.encode(value, forKey: .schedule)
        }
    }
}

extension SyncRecord: Codable {
    private enum CodingKeys: String, CodingKey { case id, kind, version, deleted, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(SyncVersion.self, forKey: .version)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        switch try container.decode(SyncKind.self, forKey: .kind) {
        case .project: payload = .project(try container.decode(ProjectRecord.self, forKey: .data))
        case .entry: payload = .entry(try container.decode(EntryRecord.self, forKey: .data))
        case .absence: payload = .absence(try container.decode(AbsenceRecord.self, forKey: .data))
        case .category: payload = .category(try container.decode(CategoryRecord.self, forKey: .data))
        case .setting: payload = .setting(try container.decode(SettingValue.self, forKey: .data))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(version, forKey: .version)
        if isDeleted { try container.encode(true, forKey: .deleted) }
        switch payload {
        case .project(let data): try container.encode(data, forKey: .data)
        case .entry(let data): try container.encode(data, forKey: .data)
        case .absence(let data): try container.encode(data, forKey: .data)
        case .category(let data): try container.encode(data, forKey: .data)
        case .setting(let data): try container.encode(data, forKey: .data)
        }
    }
}

/// What a Mac publishes to the sync folder, and also how it stores its own ledger.
struct DeviceSnapshot: Codable, Equatable, Sendable {
    /// Bump this whenever a record gains a field, a kind or setting is added, or a
    /// stored value can take a new value (an `AbsenceType` case, a counting rule): Macs
    /// skip files in a newer format and say so, instead of reading them half.
    static let currentFormat = 1

    struct Device: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var appVersion: String
    }

    var format: Int = currentFormat
    var device: Device
    var publishedAt: Date
    var clock: Int64
    /// Sorted by ID, so an unchanged ledger produces an identical file.
    var records: [SyncRecord]

    init(device: Device, publishedAt: Date, state: SyncState) {
        self.device = device
        self.publishedAt = publishedAt
        self.clock = state.clock
        self.records = state.records.values.sorted { $0.id < $1.id }
    }

    var state: SyncState {
        SyncState(clock: clock, records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { $0.version >= $1.version ? $0 : $1 }))
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Only the format number, to recognise files from a newer app version.
    struct Header: Decodable { var format: Int }
}
