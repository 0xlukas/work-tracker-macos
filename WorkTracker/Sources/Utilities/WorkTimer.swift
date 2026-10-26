import Foundation
import Observation
import SwiftData

typealias TimeSlice = (start: Date, end: Date)

enum TimeSlicer {
    /// Split `start..<end` at Zurich midnights and cut out every `busy` interval, so the
    /// result never crosses a day or overlaps an existing entry. Pieces shorter than a
    /// minute are dropped.
    static func slices(start: Date, end: Date, excluding busy: [TimeSlice]) -> [TimeSlice] {
        guard end > start else { return [] }
        var pieces: [TimeSlice] = []
        var cursor = start
        while cursor < end {
            let midnight = cursor.startOfDayZurich.addingDays(1)
            pieces.append((cursor, min(end, midnight)))
            cursor = midnight
        }
        for block in busy.sorted(by: { $0.start < $1.start }) {
            pieces = pieces.flatMap { piece -> [TimeSlice] in
                guard block.start < piece.end && block.end > piece.start else { return [piece] }
                var rest: [TimeSlice] = []
                if block.start > piece.start { rest.append((piece.start, block.start)) }
                if block.end < piece.end { rest.append((block.end, piece.end)) }
                return rest
            }
        }
        return pieces.filter { $0.end.timeIntervalSince($0.start) >= 60 }
    }
}

/// A start/stop timer that turns tracked time into entries. Its state survives quitting
/// the app, so a running timer keeps counting until stopped.
@MainActor
@Observable
final class WorkTimer {
    static let shared = WorkTimer()

    private(set) var startedAt: Date?
    private(set) var projectID: PersistentIdentifier?
    /// Refreshed while running so elapsed-time labels update.
    private(set) var now = Date()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var ticker: Task<Void, Never>?
    private static let startKey = "timerStartedAt"
    private static let projectKey = "timerProject"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startedAt = defaults.object(forKey: Self.startKey) as? Date
        projectID = defaults.data(forKey: Self.projectKey)
            .flatMap { try? JSONDecoder().decode(PersistentIdentifier.self, from: $0) }
        if startedAt != nil { startTicking() }
    }

    var isRunning: Bool { startedAt != nil }
    var elapsed: TimeInterval { startedAt.map { now.timeIntervalSince($0) } ?? 0 }

    func project(in context: ModelContext) -> Project? {
        guard let id = projectID else { return nil }
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func start(project: Project, at date: Date = Date()) {
        startedAt = date.roundedToMinute
        projectID = project.persistentModelID
        now = Date()
        persist()
        startTicking()
    }

    /// Stop the timer and switch to another project at the same moment.
    @discardableResult
    func switchProject(to project: Project, context: ModelContext, at date: Date = Date()) -> [WorkSegment] {
        let created = stop(context: context, at: date)
        start(project: project, at: date)
        return created
    }

    /// Stop the timer and record the tracked time as entries. Returns what was created
    /// (nothing when under a minute, or when the time is already covered by entries).
    @discardableResult
    func stop(context: ModelContext, at date: Date = Date()) -> [WorkSegment] {
        defer { reset() }
        guard let start = startedAt, let project = project(in: context) else { return [] }
        let end = date.roundedToMinute
        guard end > start else { return [] }

        let overlapping = FetchDescriptor<WorkSegment>(
            predicate: #Predicate { $0.startTime < end && $0.endTime > start })
        let busy = ((try? context.fetch(overlapping)) ?? []).map { (start: $0.startTime, end: $0.endTime) }
        let created = TimeSlicer.slices(start: start, end: end, excluding: busy).map {
            WorkSegment(date: $0.start, startTime: $0.start, endTime: $0.end, project: project)
        }
        created.forEach(context.insert)
        try? context.save()
        return created
    }

    func discard() { reset() }

    /// Keep timing on `project` instead (sync merged the timer's project into another one
    /// with the same name).
    func reassign(to project: Project) {
        guard isRunning else { return }
        projectID = project.persistentModelID
        persist()
    }

    private func reset() {
        startedAt = nil
        projectID = nil
        persist()
        ticker?.cancel()
        ticker = nil
    }

    private func persist() {
        defaults.set(startedAt, forKey: Self.startKey)
        defaults.set(projectID.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.projectKey)
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}
