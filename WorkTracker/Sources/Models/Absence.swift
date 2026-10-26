import Foundation
import SwiftData

/// One absence (vacation, sick, service or a custom category) on one day.
///
/// The class keeps its original `VacationDay` name because SwiftData derives the stored
/// entity name from it; renaming would force a copy migration of every absence.
@Model
final class VacationDay {
    var date: Date
    var isHalfDay: Bool
    /// Optional because V1 rows had no type; nil means vacation. Custom-category entries
    /// use `.custom`. Read through `resolvedType`.
    var type: AbsenceType?
    var category: AbsenceCategory?
    /// Snapshot of the category's rule when assigned, so later edits can't rewrite past balances.
    var categoryRuleRaw: String?
    /// The same absence on every Mac (see `DeviceSync`).
    var syncID: UUID?

    init(date: Date, isHalfDay: Bool = false, type: AbsenceType = .vacation) {
        self.date = Calendar.zurich.startOfDay(for: date)
        self.isHalfDay = isHalfDay
        self.type = type
        self.syncID = UUID()
    }

    var resolvedType: AbsenceType { type ?? .vacation }

    /// Current name/colour/icon of the category (for display).
    var categoryDetails: CategoryDetails { category?.details ?? resolvedType.details }

    /// Identifier of the selected category: a built-in type's raw value or a custom category's UUID.
    var selectionID: String { categoryDetails.id }

    /// The entry used for counting: current display details with the snapshotted rule.
    var entry: AbsenceEntry {
        guard let category else { return AbsenceEntry(category: resolvedType.details, isHalfDay: isHalfDay) }
        let rule = categoryRuleRaw.flatMap(AbsenceCountingRule.init(rawValue:)) ?? category.rule
        let details = CategoryDetails(id: category.id.uuidString, name: category.name,
                                      icon: category.icon, color: category.color, rule: rule)
        return AbsenceEntry(category: details, isHalfDay: isHalfDay)
    }

    func assign(_ selection: AbsenceSelection) {
        switch selection {
        case .builtIn(let type):
            self.type = type
            self.category = nil
            self.categoryRuleRaw = nil
        case .custom(let category):
            self.type = .custom
            self.category = category
            self.categoryRuleRaw = category.ruleRaw
        }
    }

    /// Absence entries keyed by Zurich day. Duplicate days (which the UI never creates,
    /// but a restore or sync could) keep the last row instead of trapping.
    static func lookup(_ days: [VacationDay]) -> [Date: AbsenceEntry] {
        Dictionary(days.map { ($0.date.startOfDayZurich, $0.entry) }, uniquingKeysWith: { _, last in last })
    }

    /// Delete extra rows that share a day, keeping the first. Returns how many were removed.
    @discardableResult
    static func removeDuplicates(in context: ModelContext) throws -> Int {
        let all = try context.fetch(FetchDescriptor<VacationDay>(sortBy: [SortDescriptor(\.date)]))
        var seen = Set<Date>()
        var removed = 0
        for day in all where !seen.insert(day.date.startOfDayZurich).inserted {
            context.delete(day)
            removed += 1
        }
        return removed
    }
}

/// What the absence grid is currently painting.
enum AbsenceSelection: Equatable {
    case builtIn(AbsenceType)
    case custom(AbsenceCategory)

    var id: String {
        switch self {
        case .builtIn(let type): return type.rawValue
        case .custom(let category): return category.id.uuidString
        }
    }

    var details: CategoryDetails {
        switch self {
        case .builtIn(let type): return type.details
        case .custom(let category): return category.details
        }
    }
}
