import AppIntents
import Foundation
import SwiftData

/// The database, for intents run by Siri, Shortcuts or Spotlight. Set at launch; the
/// system launches the app to run an intent when it isn't running.
@MainActor
enum IntentStore {
    static var container: ModelContainer? {
        didSet { observeSaves() }
    }
    private static var saveObserver: (any NSObjectProtocol)?

    /// Siri learns project and caller names from `suggestedEntities()`; refresh them
    /// whenever the data changes so new and renamed ones work in phrases.
    private static func observeSaves() {
        WorkTrackerShortcuts.updateAppShortcutParameters()
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            WorkTrackerShortcuts.updateAppShortcutParameters()
        }
    }

    static var context: ModelContext {
        get throws {
            guard let container else { throw IntentMessage(tr("Work Tracker can’t open its database.")) }
            return container.mainContext
        }
    }
}

/// A message shown or spoken when an intent can't do what was asked.
struct IntentMessage: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    init(_ text: String) { self.text = text }
    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

// MARK: - Project entity

struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = ProjectQuery()

    /// The project's persistent identifier, JSON-encoded, so renaming keeps shortcuts working.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ project: Project) {
        id = (try? JSONEncoder().encode(project.persistentModelID)).flatMap { String(data: $0, encoding: .utf8) } ?? project.name
        name = project.name
    }

    @MainActor
    func project(in context: ModelContext) throws -> Project {
        let decoded = id.data(using: .utf8).flatMap { try? JSONDecoder().decode(PersistentIdentifier.self, from: $0) }
        // A fetch, not `model(for:)`: that returns a placeholder for a deleted project,
        // which traps when read.
        if let decoded {
            var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.persistentModelID == decoded })
            descriptor.fetchLimit = 1
            if let project = try context.fetch(descriptor).first { return project }
        }
        if let project = EntryActions.project(named: name, in: context) { return project }
        throw IntentMessage(tr("There’s no project called %@.", name))
    }
}

struct ProjectQuery: EntityStringQuery {
    @MainActor
    private func activeProjects() throws -> [Project] {
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived }, sortBy: [SortDescriptor(\.name)])
        return try IntentStore.context.fetch(descriptor)
    }

    @MainActor
    func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        try activeProjects().map(ProjectEntity.init).filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ProjectEntity] {
        try activeProjects()
            .filter { $0.name.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(ProjectEntity.init)
    }

    /// Also the values Siri learns for the project in App Shortcut phrases.
    @MainActor
    func suggestedEntities() async throws -> [ProjectEntity] {
        try activeProjects().map(ProjectEntity.init)
    }
}

// MARK: - Timer

struct StartWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Work"
    static let description = IntentDescription("Starts the timer for a project. A running timer is saved first.")

    @Parameter(title: "Project", description: "Leave empty for the last-used project.")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start work on \(\.$project)")
    }

    init() {}
    init(project: ProjectEntity?) { self.project = project }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try IntentStore.context
        guard let target = try project?.project(in: context) ?? EntryActions.lastUsedProject(in: context) else {
            throw IntentMessage(tr("Add a project first."))
        }
        let message = TimerActions.start(target, timer: .shared, context: context)
        return .result(dialog: "\(message)")
    }
}

struct StopWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Work"
    static let description = IntentDescription("Stops the timer and saves the tracked time as entries.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = TimerActions.stop(timer: .shared, context: try IntentStore.context)
        return .result(dialog: "\(message)")
    }
}

// MARK: - Logging time

struct LogWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Work"
    static let description = IntentDescription("Adds a time entry for a project.")

    @Parameter(title: "Project")
    var project: ProjectEntity

    @Parameter(title: "Start")
    var start: Date

    @Parameter(title: "End")
    var end: Date

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$project) from \(\.$start) to \(\.$end)") {
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try IntentStore.context
        let target = try project.project(in: context)
        let start = start.roundedToMinute, end = end.roundedToMinute
        let day = start.startOfDayZurich
        if let problem = EntryActions.problem(start: start, end: end, on: day,
                                              others: EntryActions.segments(on: day, in: context)) {
            throw IntentMessage(problem)
        }
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        context.insert(WorkSegment(date: day, startTime: start, endTime: end, project: target, note: note))
        try context.save()
        let hours = end.timeIntervalSince(start) / 3600
        let message = tr("Logged %@ on %@ (%@–%@).", TimeFormatting.hours(hours), target.name,
                         TimeField.format(start), TimeField.format(end, on: day))
        return .result(dialog: "\(message)")
    }
}

// MARK: - Calls

extension CallLength: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Call Length")
    static let caseDisplayRepresentations: [CallLength: DisplayRepresentation] = [
        .short: DisplayRepresentation(title: "Under 15 minutes", synonyms: ["Short", "Less than 15 minutes"]),
        .medium: DisplayRepresentation(title: "15 minutes to 1 hour", synonyms: ["Under an hour", "Less than an hour"]),
        .long: DisplayRepresentation(title: "Over 1 hour", synonyms: ["Long", "More than an hour"]),
    ]
}

/// Callers and topics are plain names, so their entities are the names themselves: a
/// name Siri hears that isn't known yet is simply a new one.
@MainActor
private enum CallIntentNames {
    static func suggestions() throws -> CallSuggestions {
        CallSuggestions(calls: try IntentStore.context.fetch(CallSuggestions.source))
    }
}

struct CallerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Caller")
    static let defaultQuery = CallerQuery()

    /// The caller's name.
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct CallerQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CallerEntity] {
        identifiers.map(CallerEntity.init(id:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [CallerEntity] {
        CallNames.matches(string, in: try CallIntentNames.suggestions().callers).map(CallerEntity.init(id:))
    }

    /// Also the names Siri learns for "Log a call from …".
    @MainActor
    func suggestedEntities() async throws -> [CallerEntity] {
        try CallIntentNames.suggestions().callers.prefix(200).map(CallerEntity.init(id:))
    }
}

struct CallTopicEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Topic")
    static let defaultQuery = CallTopicQuery()

    /// The topic's name.
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct CallTopicQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CallTopicEntity] {
        identifiers.map(CallTopicEntity.init(id:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [CallTopicEntity] {
        CallNames.matches(string, in: try CallIntentNames.suggestions().topics).map(CallTopicEntity.init(id:))
    }

    @MainActor
    func suggestedEntities() async throws -> [CallTopicEntity] {
        try CallIntentNames.suggestions().topics.prefix(200).map(CallTopicEntity.init(id:))
    }
}

/// One of the departments in Settings ▸ Calls.
struct CallDepartmentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Department")
    static let defaultQuery = CallDepartmentQuery()

    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct CallDepartmentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CallDepartmentEntity] {
        Preferences.shared.callDepartments.filter(identifiers.contains).map(CallDepartmentEntity.init(id:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [CallDepartmentEntity] {
        Preferences.shared.callDepartments
            .filter { $0.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map(CallDepartmentEntity.init(id:))
    }

    @MainActor
    func suggestedEntities() async throws -> [CallDepartmentEntity] {
        Preferences.shared.callDepartments.map(CallDepartmentEntity.init(id:))
    }
}

/// "Log a call in Work Tracker": Siri asks who called, what about, how long it took
/// and whether the user solved the issue. The department follows the caller, as in the
/// call panel, unless one is given in Shortcuts.
struct LogCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Call"
    static let description = IntentDescription("Logs a call: who called, what about, roughly how long it took and who solved the issue.")

    @Parameter(title: "Caller", requestValueDialog: "Who called?")
    var caller: CallerEntity

    @Parameter(title: "Topic", requestValueDialog: "What was the call about?")
    var topic: CallTopicEntity

    @Parameter(title: "Length", requestValueDialog: "How long was the call?")
    var length: CallLength

    @Parameter(title: "Solved by me", requestValueDialog: "Did you solve the issue yourself?")
    var solvedByMe: Bool

    @Parameter(title: "Department", description: "Leave empty for the department of the caller’s last call.")
    var department: CallDepartmentEntity?

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log a call from \(\.$caller) about \(\.$topic), \(\.$length)") {
            \.$solvedByMe
            \.$department
            \.$note
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let preferences = Preferences.shared
        guard preferences.callTrackingEnabled else {
            throw IntentMessage(tr("Turn on Track calls in Work Tracker’s settings first."))
        }
        let context = try IntentStore.context
        let suggestions = CallSuggestions(calls: try context.fetch(CallSuggestions.source))
        let call = CallLog.add(caller: caller.id, topic: topic.id,
                               department: department?.id ?? suggestions.department(of: caller.id, among: preferences.callDepartments),
                               note: note ?? "", length: length, solvedByMe: solvedByMe, at: Date(), context: context)
        try context.save()
        return .result(dialog: "\(CallLog.confirmation(call))")
    }
}

// MARK: - Siri phrases

struct WorkTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWorkIntent(), phrases: [
            "Start work on \(\.$project) in \(.applicationName)",
            "Starting work on \(\.$project) in \(.applicationName)",
            "Start \(\.$project) in \(.applicationName)",
            "Start working in \(.applicationName)",
            "Start the timer in \(.applicationName)",
        ], shortTitle: "Start Work", systemImageName: "play.circle")

        AppShortcut(intent: StopWorkIntent(), phrases: [
            "Stop work in \(.applicationName)",
            "Stopping work in \(.applicationName)",
            "Stop working in \(.applicationName)",
            "Stop the timer in \(.applicationName)",
        ], shortTitle: "Stop Work", systemImageName: "stop.circle")

        AppShortcut(intent: LogWorkIntent(), phrases: [
            "Log work in \(.applicationName)",
            "Log time on \(\.$project) in \(.applicationName)",
        ], shortTitle: "Log Work", systemImageName: "clock.badge.checkmark")

        AppShortcut(intent: LogCallIntent(), phrases: [
            "Log a call in \(.applicationName)",
            "Log a call from \(\.$caller) in \(.applicationName)",
            "Add a call in \(.applicationName)",
        ], shortTitle: "Log Call", systemImageName: "phone.badge.plus")
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
