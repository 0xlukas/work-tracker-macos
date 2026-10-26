import SwiftUI
import SwiftData

/// Past working days since tracking started with nothing logged, most recent first.
/// Today doesn't count until it's over. Owns its queries so screens that only show a
/// week (Daily Entry) or no entries at all (the sidebar) don't fetch every entry.
struct MissingEntriesReader<Content: View>: View {
    @Environment(Preferences.self) private var preferences
    @Query private var segments: [WorkSegment]
    @Query private var absences: [VacationDay]
    /// Changes at midnight, so yesterday joins the list without other edits.
    @State private var today = Date().startOfDayZurich
    private let content: ([Date]) -> Content

    init(trackingStart: Date, @ViewBuilder content: @escaping ([Date]) -> Content) {
        let start = trackingStart.startOfDayZurich
        _segments = Query(filter: #Predicate<WorkSegment> { $0.date >= start })
        _absences = Query(filter: #Predicate<VacationDay> { $0.date >= start })
        self.content = content
    }

    var body: some View {
        let calculator = preferences.calculator(absences: VacationDay.lookup(absences))
        content(calculator.missingEntryDays(from: preferences.trackingStartDate, to: today.addingDays(-1),
                                            hours: WorkSegment.hoursByDay(segments)))
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                today = Date().startOfDayZurich
            }
    }
}

/// "3 days without entries" button in Daily Entry; the menu jumps to one of them.
struct MissingEntriesMenu: View {
    let days: [Date]
    let onSelect: (Date) -> Void

    /// Enough to catch up on; older gaps are reached from the last one listed.
    private let limit = 20

    var body: some View {
        Menu {
            Section(tr("Days Without Entries")) {
                ForEach(days.prefix(limit), id: \.self) { day in
                    Button(day.formatted(.app.weekday(.abbreviated).day().month(.abbreviated).year())) {
                        onSelect(day)
                    }
                }
            }
            if days.count > limit {
                Text(tr("%lld more", days.count - limit))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .accessibilityHidden(true)
                Text(tr("%lld days without entries", days.count))
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .cardSurface(tint: .orange, radius: Surface.rowRadius)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(tr("%lld days without entries", days.count))
        .help(tr("Working days since tracking started with no time entries or full-day absence"))
    }
}
