import Foundation
import SwiftData

@Model
final class Project {
    var name: String
    var createdAt: Date
    /// User-chosen colour. Assigned on creation and, for projects from before V4, by
    /// the migration — so renaming a project never changes its colour.
    var colorRaw: String?
    /// Archived projects disappear from pickers but keep their entries and reports.
    var isArchived: Bool = false
    /// The same project on every Mac (see `DeviceSync`). Set on creation and, for
    /// projects from before V5, by the migration.
    var syncID: UUID?

    @Relationship(deleteRule: .deny, inverse: \WorkSegment.project)
    var segments: [WorkSegment] = []

    init(name: String, color: PaletteColor = .blue) {
        self.name = name
        self.createdAt = Date()
        self.colorRaw = color.rawValue
        self.isArchived = false
        self.syncID = UUID()
    }

    var color: PaletteColor {
        get { colorRaw.flatMap(PaletteColor.init(rawValue:)) ?? Self.legacyColor(for: name) }
        set { colorRaw = newValue.rawValue }
    }

    /// The colour a project had before colours were stored: a hash of its name.
    static func legacyColor(for name: String) -> PaletteColor {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return PaletteColor.allCases[sum % PaletteColor.allCases.count]
    }

    /// The least-used palette colour, so new projects are easy to tell apart.
    static func suggestedColor(existing: [Project]) -> PaletteColor {
        let counts = Dictionary(grouping: existing.filter { !$0.isArchived }, by: \.color).mapValues(\.count)
        return PaletteColor.allCases.min { counts[$0, default: 0] < counts[$1, default: 0] } ?? .blue
    }

    /// True when `name` matches another project's name, ignoring case and diacritics.
    static func isDuplicate(name: String, in projects: [Project], excluding: Project? = nil) -> Bool {
        projects.contains {
            $0 !== excluding && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}
