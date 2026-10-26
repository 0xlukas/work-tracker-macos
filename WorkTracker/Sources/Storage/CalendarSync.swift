import AppKit
import EventKit
import Observation
import SwiftData

/// Keeps a "Work Tracker" calendar — in iCloud when the Mac is signed in — in step with
/// the absences: after launch, shortly after every change and whenever the app becomes
/// active. The app owns that calendar and replaces whatever else is in it.
@MainActor
@Observable
final class CalendarSync {
    static let calendarTitle = "Work Tracker"

    var lastSync: Date?
    var errorMessage: String?
    /// macOS denied calendar access, so Settings offers the privacy pane.
    var needsAccess = false
    /// Account the calendar lives in, such as "iCloud".
    var accountName: String?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var store = EKEventStore()
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    func start(container: ModelContainer) {
        self.container = container
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSync() }
            },
            // Also picks up schedule and language changes, which change the events.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSync(after: .zero) }
            },
        ]
        scheduleSync(after: .zero)
    }

    /// Sync once a burst of changes (a Shift-click range, an undo) has settled.
    func scheduleSync(after delay: Duration = .seconds(2)) {
        guard preferences.calendarSyncEnabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.sync()
        }
    }

    /// Turning syncing on asks for calendar access, then fills the calendar. Turning it
    /// off leaves the calendar and its events as they are.
    func setEnabled(_ enabled: Bool) async {
        preferences.calendarSyncEnabled = enabled
        errorMessage = nil
        needsAccess = false
        if enabled { await sync() } else { pending?.cancel() }
    }

    func sync() async {
        guard preferences.calendarSyncEnabled, let container, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard await hasAccess() else {
            needsAccess = true
            errorMessage = tr("Work Tracker isn’t allowed to use your calendars. Allow it in System Settings ▸ Privacy & Security ▸ Calendars.")
            return
        }
        needsAccess = false
        do {
            let absences = VacationDay.lookup(try container.mainContext.fetch(FetchDescriptor<VacationDay>()))
            let events = AbsenceCalendarPlan.events(absences: absences, calculator: preferences.calculator(absences: absences))
            let calendar = try absenceCalendar()
            try AbsenceCalendarPlan.reconcile(events, with: EventKitCalendar(store: store, calendar: calendar),
                                              today: CalendarDay(Date(), in: .current))
            accountName = calendar.source.title
            lastSync = Date()
            errorMessage = nil
        } catch {
            // Drop uncommitted changes so the next sync starts from what is saved.
            store.reset()
            errorMessage = tr("Could not update the calendar: %@", error.localizedDescription)
        }
    }

    private func hasAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
            }
            // A store made before access was granted doesn't see any calendars.
            if granted { store = EKEventStore() }
            return granted
        default:
            return false
        }
    }

    /// The saved calendar, else one with the app's title in the preferred account (after
    /// a reinstall), else a new one.
    private func absenceCalendar() throws -> EKCalendar {
        if let id = preferences.absenceCalendarID, let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        let source = try preferredSource()
        let calendar: EKCalendar
        if let existing = store.calendars(for: .event).first(where: {
            $0.title == Self.calendarTitle && $0.source.sourceIdentifier == source.sourceIdentifier
        }) {
            calendar = existing
        } else {
            calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = Self.calendarTitle
            calendar.source = source
            calendar.cgColor = PaletteColor.blue.nsColor.cgColor
            try store.saveCalendar(calendar, commit: true)
        }
        preferences.absenceCalendarID = calendar.calendarIdentifier
        return calendar
    }

    /// iCloud when signed in, else the account new events go to, else On My Mac.
    private func preferredSource() throws -> EKSource {
        let sources = store.sources
        if let iCloud = sources.first(where: { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("iCloud") }) {
            return iCloud
        }
        if let source = store.defaultCalendarForNewEvents?.source { return source }
        if let local = sources.first(where: { $0.sourceType == .local }) { return local }
        throw CalendarSyncError(tr("There’s no calendar account to add the Work Tracker calendar to."))
    }
}

private struct CalendarSyncError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The Work Tracker calendar through EventKit. All-day events are floating, so days are
/// read and written in the Mac's own calendar.
@MainActor
private struct EventKitCalendar: AbsenceCalendarTarget {
    let store: EKEventStore
    let calendar: EKCalendar
    private var local: Calendar { .current }

    func events(from: CalendarDay, to: CalendarDay) throws -> [StoredAbsenceEvent] {
        var found: [StoredAbsenceEvent] = []
        var seen = Set<String>()
        var start = from.date(in: local)
        let end = local.date(byAdding: .day, value: 1, to: to.date(in: local))!
        // EventKit searches at most four years per query.
        while start < end {
            let next = min(local.date(byAdding: .year, value: 3, to: start)!, end)
            let predicate = store.predicateForEvents(withStart: start, end: next, calendars: [calendar])
            for event in store.events(matching: predicate) where seen.insert(event.calendarItemIdentifier).inserted {
                // EventKit reports an all-day event's end as 23:59:59 on its last day.
                found.append(StoredAbsenceEvent(id: event.calendarItemIdentifier, event: AbsenceEvent(
                    title: event.title ?? "", first: CalendarDay(event.startDate, in: local),
                    last: CalendarDay(event.endDate, in: local))))
            }
            start = next
        }
        return found
    }

    func add(_ event: AbsenceEvent) throws {
        let item = EKEvent(eventStore: store)
        item.calendar = calendar
        item.title = event.title
        item.isAllDay = true
        item.startDate = event.first.date(in: local)
        // Midnight of the last day; EventKit extends it to the end of that day.
        item.endDate = event.last.date(in: local)
        try store.save(item, span: .thisEvent, commit: false)
    }

    func remove(id: String) throws {
        guard let item = store.calendarItem(withIdentifier: id) as? EKEvent else { return }
        try store.remove(item, span: .thisEvent, commit: false)
    }

    func commit() throws {
        try store.commit()
    }
}
