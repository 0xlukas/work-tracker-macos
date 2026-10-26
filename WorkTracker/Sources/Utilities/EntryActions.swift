import Foundation
import SwiftData

/// The Absences grid's editing rules, independent of the view.
@MainActor
struct AbsenceEditor {
    let context: ModelContext
    /// Existing absences by Zurich day.
    let existing: [Date: VacationDay]

    init(context: ModelContext, absences: [VacationDay]) {
        self.context = context
        self.existing = Dictionary(absences.map { ($0.date.startOfDayZurich, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Click cycle: none → full day → half day → none. Clicking an absence of another
    /// category converts it to a full day of the selected one.
    func click(_ date: Date, selection: AbsenceSelection) {
        let day = date.startOfDayZurich
        guard let absence = existing[day] else {
            insert(on: day, selection: selection)
            return
        }
        if absence.selectionID != selection.id {
            absence.assign(selection)
            absence.isHalfDay = false
        } else if !absence.isHalfDay {
            absence.isHalfDay = true
        } else {
            context.delete(absence)
        }
    }

    /// Shift-click range: every day becomes the selected category. Days that already
    /// have it keep their full/half state.
    func fill(_ days: [Date], selection: AbsenceSelection) {
        for day in days.map(\.startOfDayZurich) {
            if let absence = existing[day] {
                if absence.selectionID != selection.id {
                    absence.assign(selection)
                    absence.isHalfDay = false
                }
            } else {
                insert(on: day, selection: selection)
            }
        }
    }

    private func insert(on day: Date, selection: AbsenceSelection) {
        let absence = VacationDay(date: day)
        absence.assign(selection)
        context.insert(absence)
    }
}

/// Queries and bulk actions for time entries.
@MainActor
enum EntryActions {
    static func segments(on day: Date, in context: ModelContext) -> [WorkSegment] {
        let start = day.startOfDayZurich, end = start.addingDays(1)
        let descriptor = FetchDescriptor<WorkSegment>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.startTime)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The most recent day before `day` that has entries.
    static func previousDayWithEntries(before day: Date, in context: ModelContext) -> Date? {
        let start = day.startOfDayZurich
        var descriptor = FetchDescriptor<WorkSegment>(
            predicate: #Predicate { $0.date < start },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.date.startOfDayZurich
    }

    /// Start time to pre-fill a new entry with: the end of the day's last segment,
    /// or 08:10 when the day has none.
    static func nextStart(on day: Date, in context: ModelContext) -> Date {
        if let lastEnd = segments(on: day, in: context).map(\.endTime).max() {
            return min(lastEnd, day.startOfDayZurich.addingDays(1).addingTimeInterval(-60))
        }
        return Calendar.zurich.date(bySettingHour: 8, minute: 10, second: 0, of: day.startOfDayZurich) ?? day
    }

    /// Why `start..<end` can't be saved on `day`, or nil when it can. `others` are the
    /// day's other entries (excluding the one being edited).
    static func problem(start: Date, end: Date, on day: Date, others: [WorkSegment]) -> String? {
        guard end > start else { return tr("End time must be after start time.") }
        let dayStart = day.startOfDayZurich
        guard start >= dayStart, end <= dayStart.addingDays(1) else {
            return tr("An entry can’t cross midnight — split it into two entries.")
        }
        if let clash = others.first(where: { start < $0.endTime && end > $0.startTime }) {
            return tr("Overlaps with %@–%@.", TimeField.format(clash.startTime, on: clash.date),
                      TimeField.format(clash.endTime, on: clash.date))
        }
        return nil
    }

    /// The active project whose name matches `name`, ignoring case and diacritics.
    static func project(named name: String, in context: ModelContext) -> Project? {
        let projects = (try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived }))) ?? []
        return projects.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// The project of the most recently logged entry that isn't archived.
    static func lastUsedProject(in context: ModelContext) -> Project? {
        var descriptor = FetchDescriptor<WorkSegment>(sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        descriptor.fetchLimit = 20
        return (try? context.fetch(descriptor))?.lazy.compactMap(\.project).first { !$0.isArchived }
    }

    /// Copy every entry from `source` to `target` at the same times. Entries that would
    /// overlap something already on `target` are skipped. Returns (copied, skipped).
    @discardableResult
    static func copyEntries(from source: Date, to target: Date, in context: ModelContext) -> (copied: Int, skipped: Int) {
        let existing = segments(on: target, in: context)
        var copied = 0, skipped = 0
        var busy = existing.map { (start: $0.startTime, end: $0.endTime) }
        for segment in segments(on: source, in: context) {
            guard let project = segment.project else { skipped += 1; continue }
            let start = moved(segment.startTime, from: segment.date, to: target)
            let end = moved(segment.endTime, from: segment.date, to: target)
            if busy.contains(where: { start < $0.end && end > $0.start }) {
                skipped += 1
                continue
            }
            context.insert(WorkSegment(date: target, startTime: start, endTime: end, project: project, note: segment.note))
            busy.append((start, end))
            copied += 1
        }
        return (copied, skipped)
    }

    /// Same wall-clock offset from midnight on another day (24:00 stays 24:00).
    static func moved(_ time: Date, from day: Date, to target: Date) -> Date {
        let offset = Calendar.zurich.dateComponents([.minute], from: day.startOfDayZurich, to: time).minute ?? 0
        return Calendar.zurich.date(byAdding: .minute, value: offset, to: target.startOfDayZurich)!
    }
}

/// Timer actions shared by the voice panel and Siri. Each returns a confirmation to show
/// or speak.
@MainActor
enum TimerActions {
    /// Start the timer; a running timer is stopped and saved first.
    static func start(_ project: Project, at date: Date = Date(), timer: WorkTimer, context: ModelContext) -> String {
        if timer.isRunning {
            let previous = timer.project(in: context)?.name ?? ""
            timer.switchProject(to: project, context: context, at: date)
            return tr("Saved the time on %@ and started the timer for %@.", previous, project.name)
        }
        timer.start(project: project, at: date)
        return tr("Started the timer for %@.", project.name)
    }

    static func stop(at date: Date = Date(), timer: WorkTimer, context: ModelContext) -> String {
        guard timer.isRunning else { return tr("No timer is running.") }
        let name = timer.project(in: context)?.name ?? ""
        let hours = timer.stop(context: context, at: date).reduce(0) { $0 + $1.durationHours }
        guard hours > 0 else { return tr("Stopped the timer; nothing to save.") }
        return tr("Saved %@ on %@.", TimeFormatting.hours(hours), name)
    }
}
