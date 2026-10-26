import Foundation
import SwiftData

enum AbsenceType: String, Codable, CaseIterable {
    case vacation
    case sick
    case service
    /// Stored as its raw string like the others, so adding it needed no new schema version.
    case unpaid
    /// Entry belongs to a custom `AbsenceCategory` (V4+; V3 stored `.service` here).
    case custom
}

// Each schema version freezes the model shapes it shipped with, so SwiftData can still
// recognise older stores after the live models change. Project and WorkSegment kept the
// same shape from V1 through V3, so those versions share V3's frozen copies.

enum WorkTrackerSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [WorkTrackerSchemaV3.Project.self, WorkTrackerSchemaV3.WorkSegment.self, VacationDay.self]
    }

    @Model
    final class VacationDay {
        var date: Date
        var isHalfDay: Bool

        init(date: Date, isHalfDay: Bool = false) {
            self.date = Calendar.zurich.startOfDay(for: date)
            self.isHalfDay = isHalfDay
        }
    }
}

enum WorkTrackerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [WorkTrackerSchemaV3.Project.self, WorkTrackerSchemaV3.WorkSegment.self, VacationDay.self]
    }

    @Model
    final class VacationDay {
        var date: Date
        var isHalfDay: Bool
        var type: AbsenceType?

        init(date: Date, isHalfDay: Bool = false, type: AbsenceType? = nil) {
            self.date = date
            self.isHalfDay = isHalfDay
            self.type = type
        }
    }
}

enum WorkTrackerSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Project.self, WorkSegment.self, VacationDay.self, AbsenceCategory.self]
    }

    @Model
    final class Project {
        var name: String
        var createdAt: Date
        @Relationship(deleteRule: .deny, inverse: \WorkSegment.project)
        var segments: [WorkSegment] = []

        init(name: String) {
            self.name = name
            self.createdAt = Date()
        }
    }

    @Model
    final class WorkSegment {
        var date: Date
        var startTime: Date
        var endTime: Date
        var durationHours: Double
        var project: Project?

        init(date: Date, startTime: Date, endTime: Date, project: Project) {
            self.date = Calendar.zurich.startOfDay(for: date)
            self.startTime = startTime
            self.endTime = endTime
            self.durationHours = endTime.timeIntervalSince(startTime) / 3600.0
            self.project = project
        }
    }

    @Model
    final class VacationDay {
        var date: Date
        var isHalfDay: Bool
        var type: AbsenceType?
        var category: AbsenceCategory?
        var categoryRuleRaw: String?

        init(date: Date, isHalfDay: Bool = false, type: AbsenceType = .vacation) {
            self.date = Calendar.zurich.startOfDay(for: date)
            self.isHalfDay = isHalfDay
            self.type = type
        }
    }

    @Model
    final class AbsenceCategory {
        var id: UUID
        var name: String
        var icon: String
        var colorRaw: String
        var ruleRaw: String
        var isArchived: Bool

        init(name: String, rule: String = "holiday") {
            self.id = UUID()
            self.name = name
            self.icon = "calendar.badge.clock"
            self.colorRaw = "purple"
            self.ruleRaw = rule
            self.isArchived = false
        }
    }
}

/// V4: project colours and archiving, entry notes, and a dedicated `.custom` absence type.
enum WorkTrackerSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Project.self, WorkSegment.self, VacationDay.self, AbsenceCategory.self]
    }

    @Model
    final class Project {
        var name: String
        var createdAt: Date
        var colorRaw: String?
        var isArchived: Bool = false
        @Relationship(deleteRule: .deny, inverse: \WorkSegment.project)
        var segments: [WorkSegment] = []

        init(name: String) {
            self.name = name
            self.createdAt = Date()
        }
    }

    @Model
    final class WorkSegment {
        var date: Date
        var startTime: Date
        var endTime: Date
        var durationHours: Double
        var project: Project?
        var note: String = ""

        init(date: Date, startTime: Date, endTime: Date, project: Project) {
            self.date = Calendar.zurich.startOfDay(for: date)
            self.startTime = startTime
            self.endTime = endTime
            self.durationHours = endTime.timeIntervalSince(startTime) / 3600.0
            self.project = project
        }
    }

    @Model
    final class VacationDay {
        var date: Date
        var isHalfDay: Bool
        var type: AbsenceType?
        var category: AbsenceCategory?
        var categoryRuleRaw: String?

        init(date: Date, isHalfDay: Bool = false, type: AbsenceType = .vacation) {
            self.date = Calendar.zurich.startOfDay(for: date)
            self.isHalfDay = isHalfDay
            self.type = type
        }
    }

    /// Same shape as the live class; a frozen copy all the same, because SwiftData
    /// mixes up versions whose models link to a class they share.
    @Model
    final class AbsenceCategory {
        var id: UUID
        var name: String
        var icon: String
        var colorRaw: String
        var ruleRaw: String
        var isArchived: Bool

        init(name: String, rule: String = "holiday") {
            self.id = UUID()
            self.name = name
            self.icon = "calendar.badge.clock"
            self.colorRaw = "purple"
            self.ruleRaw = rule
            self.isArchived = false
        }
    }
}

/// V5: a sync ID on projects, entries and absences, so each Mac can tell which rows are
/// the same (custom categories already had their `id`).
enum WorkTrackerSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Project.self, WorkSegment.self, VacationDay.self, AbsenceCategory.self]
    }
}

enum WorkTrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [WorkTrackerSchemaV1.self, WorkTrackerSchemaV2.self, WorkTrackerSchemaV3.self, WorkTrackerSchemaV4.self,
         WorkTrackerSchemaV5.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: WorkTrackerSchemaV1.self, toVersion: WorkTrackerSchemaV2.self),
         .lightweight(fromVersion: WorkTrackerSchemaV2.self, toVersion: WorkTrackerSchemaV3.self),
         .custom(fromVersion: WorkTrackerSchemaV3.self, toVersion: WorkTrackerSchemaV4.self,
                 willMigrate: nil, didMigrate: { try finishV4($0) }),
         .custom(fromVersion: WorkTrackerSchemaV4.self, toVersion: WorkTrackerSchemaV5.self,
                 willMigrate: nil, didMigrate: { try finishV5($0) })]
    }

    /// Fill in what V4 adds: keep each project's previous (name-derived) colour, move
    /// custom-category entries off the `.service` placeholder, and drop duplicate days.
    /// Uses V4's frozen models: the context holds the V4 schema at this point.
    @Sendable static func finishV4(_ context: ModelContext) throws {
        typealias V4 = WorkTrackerSchemaV4
        for project in try context.fetch(FetchDescriptor<V4.Project>()) where project.colorRaw == nil {
            project.colorRaw = Project.legacyColor(for: project.name).rawValue
        }
        let days = try context.fetch(FetchDescriptor<V4.VacationDay>(sortBy: [SortDescriptor(\.date)]))
        var seen = Set<Date>()
        for day in days {
            if day.category != nil { day.type = .custom }
            if !seen.insert(day.date.startOfDayZurich).inserted { context.delete(day) }
        }
        try context.save()
    }

    /// Give every existing project, entry and absence its sync ID.
    @Sendable static func finishV5(_ context: ModelContext) throws {
        for project in try context.fetch(FetchDescriptor<Project>()) where project.syncID == nil {
            project.syncID = UUID()
        }
        for segment in try context.fetch(FetchDescriptor<WorkSegment>()) where segment.syncID == nil {
            segment.syncID = UUID()
        }
        for absence in try context.fetch(FetchDescriptor<VacationDay>()) where absence.syncID == nil {
            absence.syncID = UUID()
        }
        try context.save()
    }
}

extension ModelContainer {
    /// The app's container for a store at `url`, migrated to the current schema.
    static func workTracker(url: URL) throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: WorkTrackerSchemaV5.self),
                           migrationPlan: WorkTrackerMigrationPlan.self,
                           configurations: ModelConfiguration(url: url))
    }
}
