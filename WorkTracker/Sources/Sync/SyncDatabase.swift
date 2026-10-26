import Foundation
import SwiftData

/// Reads the database and the synced preferences as sync records, and writes records
/// back. Record IDs are the models' sync IDs (a category's `id`), and `setting.<name>`
/// for preferences.
@MainActor
enum SyncDatabase {
    /// Preferences that sync, because balances depend on them. Language, export format,
    /// backups, the calendar and the daily quote stay per Mac.
    enum Setting: String, CaseIterable {
        case trackingStartDate, vacationEntitlement, carryOverVacation, openingVacationCarryOver,
             openingBalanceHours, fullTimeWeeklyHours, schedule

        static let prefix = "setting."
        var id: String { Self.prefix + rawValue }

        @MainActor func value(in preferences: Preferences) -> SettingValue {
            switch self {
            case .trackingStartDate: return .date(preferences.trackingStartDate)
            case .vacationEntitlement: return .number(preferences.vacationEntitlement)
            case .carryOverVacation: return .flag(preferences.carryOverVacation)
            case .openingVacationCarryOver: return .number(preferences.openingVacationCarryOver)
            case .openingBalanceHours: return .number(preferences.openingBalanceHours)
            case .fullTimeWeeklyHours: return .number(preferences.fullTimeWeeklyHours)
            case .schedule: return .schedule(preferences.schedule)
            }
        }

        /// Whether `value` has this preference's type.
        func accepts(_ value: SettingValue) -> Bool {
            switch (self, value) {
            case (.trackingStartDate, .date), (.carryOverVacation, .flag), (.schedule, .schedule),
                 (.vacationEntitlement, .number), (.openingVacationCarryOver, .number),
                 (.openingBalanceHours, .number), (.fullTimeWeeklyHours, .number):
                return true
            default:
                return false
            }
        }

        /// Set the preference; values of the wrong type are ignored.
        @MainActor func apply(_ value: SettingValue, to preferences: Preferences) {
            guard value != self.value(in: preferences) else { return }
            switch (self, value) {
            case (.trackingStartDate, .date(let date)): preferences.trackingStartDate = date
            case (.vacationEntitlement, .number(let number)): preferences.vacationEntitlement = number
            case (.carryOverVacation, .flag(let flag)): preferences.carryOverVacation = flag
            case (.openingVacationCarryOver, .number(let number)): preferences.openingVacationCarryOver = number
            case (.openingBalanceHours, .number(let number)): preferences.openingBalanceHours = number
            case (.fullTimeWeeklyHours, .number(let number)): preferences.fullTimeWeeklyHours = number
            case (.schedule, .schedule(let schedule)): preferences.schedule = schedule
            default: break
            }
        }
    }

    /// Records this version can't store as they are, because a newer version wrote them
    /// (an absence type or preference it doesn't know). Sync leaves them alone: they
    /// aren't written into the database, and the database lacking them isn't a change.
    nonisolated static func foreignRecords(in state: SyncState) -> Set<String> {
        Set(state.records.values.filter { !canStore($0) }.map(\.id))
    }

    nonisolated static func canStore(_ record: SyncRecord) -> Bool {
        switch record.payload {
        case .setting(let value):
            guard record.id.hasPrefix(Setting.prefix),
                  let setting = Setting(rawValue: String(record.id.dropFirst(Setting.prefix.count))) else { return false }
            return setting.accepts(value)
        case .absence(let data):
            return UUID(uuidString: record.id) != nil && (data.type.map { AbsenceType(rawValue: $0) != nil } ?? true)
        case .project, .entry, .category:
            return UUID(uuidString: record.id) != nil
        }
    }

    static func settings(_ preferences: Preferences) -> [String: SyncPayload] {
        Dictionary(uniqueKeysWithValues: Setting.allCases.map { ($0.id, .setting($0.value(in: preferences))) })
    }

    /// Give rows without a sync ID one, and a new one to rows sharing an ID. Returns
    /// whether anything changed.
    static func assignMissingIDs(in context: ModelContext) throws -> Bool {
        var changed = false
        var seen = Set<UUID>()
        func check(_ id: inout UUID?) {
            if let current = id, seen.insert(current).inserted { return }
            let fresh = UUID()
            seen.insert(fresh)
            id = fresh
            changed = true
        }
        for project in try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt)])) { check(&project.syncID) }
        for segment in try context.fetch(FetchDescriptor<WorkSegment>(sortBy: [SortDescriptor(\.startTime)])) { check(&segment.syncID) }
        for absence in try context.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)])) { check(&absence.syncID) }
        return changed
    }

    /// Everything that syncs, by record ID. Call `assignMissingIDs` first; rows without
    /// an ID are skipped.
    static func export(context: ModelContext, preferences: Preferences) throws -> [String: SyncPayload] {
        var records = settings(preferences)
        for project in try context.fetch(FetchDescriptor<Project>()) {
            guard let id = project.syncID else { continue }
            records[id.uuidString] = .project(ProjectRecord(name: project.name, createdAt: project.createdAt,
                                                            color: project.colorRaw, isArchived: project.isArchived))
        }
        for segment in try context.fetch(FetchDescriptor<WorkSegment>()) {
            guard let id = segment.syncID else { continue }
            records[id.uuidString] = .entry(EntryRecord(day: segment.date, start: segment.startTime, end: segment.endTime,
                                                        project: segment.project?.syncID?.uuidString, note: segment.note))
        }
        for absence in try context.fetch(FetchDescriptor<VacationDay>()) {
            guard let id = absence.syncID else { continue }
            records[id.uuidString] = .absence(AbsenceRecord(day: absence.date, isHalfDay: absence.isHalfDay,
                                                            type: absence.type?.rawValue,
                                                            category: absence.category?.id.uuidString,
                                                            categoryRule: absence.categoryRuleRaw))
        }
        for category in try context.fetch(FetchDescriptor<AbsenceCategory>()) {
            records[category.id.uuidString] = .category(CategoryRecord(name: category.name, icon: category.icon,
                                                                       color: category.colorRaw, rule: category.ruleRaw,
                                                                       isArchived: category.isArchived))
        }
        return records
    }

    /// True when the database holds anything entered by the user.
    static func hasData(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<Project>()) > 0
            || context.fetchCount(FetchDescriptor<WorkSegment>()) > 0
            || context.fetchCount(FetchDescriptor<VacationDay>()) > 0
            || context.fetchCount(FetchDescriptor<AbsenceCategory>()) > 0
    }

    /// Write `changes` into the context and preferences (without saving). Projects and
    /// categories something still uses are kept; the next sync brings them back on the
    /// other Macs.
    static func apply(_ changes: SyncMerge.Changes, to context: ModelContext, preferences: Preferences) throws {
        guard !changes.isEmpty else { return }
        var projects = index(try context.fetch(FetchDescriptor<Project>()), by: \.syncID)
        var categories = index(try context.fetch(FetchDescriptor<AbsenceCategory>()), by: { $0.id })
        var segments = index(try context.fetch(FetchDescriptor<WorkSegment>()), by: \.syncID)
        var absences = index(try context.fetch(FetchDescriptor<VacationDay>()), by: \.syncID)

        // Categories and projects first, so entries and absences can point at new ones.
        let order = Dictionary(uniqueKeysWithValues: SyncKind.allCases.enumerated().map { ($1, $0) })
        for record in changes.upserts.sorted(by: { order[$0.kind]! < order[$1.kind]! }) {
            switch record.payload {
            case .setting(let value):
                guard record.id.hasPrefix(Setting.prefix),
                      let setting = Setting(rawValue: String(record.id.dropFirst(Setting.prefix.count))) else { continue }
                setting.apply(value, to: preferences)
            case .category(let data):
                guard let id = UUID(uuidString: record.id) else { continue }
                let category = categories[record.id] ?? {
                    let category = AbsenceCategory(name: data.name)
                    category.id = id
                    context.insert(category)
                    categories[record.id] = category
                    return category
                }()
                category.name = data.name
                category.icon = data.icon
                category.colorRaw = data.color
                category.ruleRaw = data.rule
                category.isArchived = data.isArchived
            case .project(let data):
                guard let id = UUID(uuidString: record.id) else { continue }
                let project = projects[record.id] ?? {
                    let project = Project(name: data.name)
                    project.syncID = id
                    context.insert(project)
                    projects[record.id] = project
                    return project
                }()
                project.name = data.name
                project.createdAt = data.createdAt
                project.colorRaw = data.color
                project.isArchived = data.isArchived
            case .entry(let data):
                guard let id = UUID(uuidString: record.id) else { continue }
                let project = data.project.flatMap { projects[$0] }
                let segment = segments[record.id] ?? {
                    let segment = WorkSegment(date: data.day, startTime: data.start, endTime: data.end, project: project)
                    segment.syncID = id
                    context.insert(segment)
                    segments[record.id] = segment
                    return segment
                }()
                segment.date = data.day
                segment.startTime = data.start
                segment.endTime = data.end
                segment.project = project
                segment.note = data.note
                segment.recalculateDuration()
            case .absence(let data):
                guard let id = UUID(uuidString: record.id) else { continue }
                let absence = absences[record.id] ?? {
                    let absence = VacationDay(date: data.day)
                    absence.syncID = id
                    context.insert(absence)
                    absences[record.id] = absence
                    return absence
                }()
                absence.date = data.day
                absence.isHalfDay = data.isHalfDay
                absence.type = data.type.flatMap(AbsenceType.init(rawValue:))
                absence.category = data.category.flatMap { categories[$0] }
                absence.categoryRuleRaw = data.categoryRule
            }
        }

        // Entries and absences before the projects and categories they may use.
        for deletion in changes.deletions where deletion.kind == .entry || deletion.kind == .absence {
            if let segment = segments.removeValue(forKey: deletion.id) { context.delete(segment) }
            if let absence = absences.removeValue(forKey: deletion.id) { context.delete(absence) }
        }
        let usedProjects = Set(segments.values.compactMap { $0.project?.persistentModelID })
        let usedCategories = Set(absences.values.compactMap { $0.category?.id })
        for deletion in changes.deletions where deletion.kind == .project || deletion.kind == .category {
            // Deleting a project that still has entries would fail (`.deny`).
            if let project = projects[deletion.id], !usedProjects.contains(project.persistentModelID) {
                context.delete(project)
            }
            if let category = categories[deletion.id], !usedCategories.contains(category.id) {
                context.delete(category)
            }
        }
    }

    private static func index<Model>(_ models: [Model], by key: (Model) -> UUID?) -> [String: Model] {
        Dictionary(models.compactMap { model in key(model).map { ($0.uuidString, model) } }, uniquingKeysWith: { first, _ in first })
    }
}
