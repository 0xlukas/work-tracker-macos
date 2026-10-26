import SwiftUI
import SwiftData
import AppKit

/// Toolbar control: a Start menu (pick a project) or a Stop button showing elapsed time.
struct TimerControl: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkTimer.self) private var timer
    @Query(filter: #Predicate<Project> { !$0.isArchived }, sort: \Project.name) private var projects: [Project]

    var body: some View {
        if timer.isRunning {
            Button {
                timer.stop(context: modelContext)
            } label: {
                Label(tr("Stop %@", TimeFormatting.clock(timer.elapsed)), systemImage: "stop.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            }
            .tint(.red)
            .help(tr("Stop the timer and save the tracked time (%@)", timer.project(in: modelContext)?.name ?? ""))
        } else {
            Menu {
                ProjectStartButtons(projects: projects) { timer.start(project: $0) }
            } label: {
                Label(tr("Start Timer"), systemImage: "play.circle")
            }
            .disabled(projects.isEmpty)
            .help(tr("Start a timer for a project"))
        }
    }
}

/// Project buttons for starting a timer, with the last-used project first.
private struct ProjectStartButtons: View {
    @Environment(\.modelContext) private var modelContext
    let projects: [Project]
    let action: (Project) -> Void

    var body: some View {
        let last = EntryActions.lastUsedProject(in: modelContext)
        if let last {
            Button(last.name) { action(last) }
            Divider()
        }
        ForEach(projects.filter { $0 !== last }) { project in
            Button(project.name) { action(project) }
        }
    }
}

/// Menu bar icon; shows the elapsed time while a timer runs.
struct MenuBarLabel: View {
    @Environment(WorkTimer.self) private var timer

    var body: some View {
        if timer.isRunning {
            Label(TimeFormatting.clock(timer.elapsed), systemImage: "timer")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        } else {
            Image(systemName: "clock")
        }
    }
}

/// Menu bar window: today at a glance plus timer controls.
struct MenuBarContent: View {
    var body: some View {
        // Re-evaluate every minute so "today" rolls over at midnight.
        TimelineView(.everyMinute) { context in
            MenuBarToday(today: context.date.startOfDayZurich)
        }
        .frame(width: 300)
    }
}

private struct MenuBarToday: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(Preferences.self) private var preferences
    @Environment(WorkTimer.self) private var timer
    @Environment(DeviceSync.self) private var deviceSync
    @Query(sort: \VacationDay.date) private var absences: [VacationDay]
    @Query(filter: #Predicate<Project> { !$0.isArchived }, sort: \Project.name) private var projects: [Project]
    @Query private var weekSegments: [WorkSegment]
    @State private var selectedProject: Project?

    let today: Date

    init(today: Date) {
        self.today = today
        let start = today.startOfWeekZurich, end = start.addingDays(7)
        _weekSegments = Query(filter: #Predicate<WorkSegment> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let calculator = preferences.calculator(absences: VacationDay.lookup(absences))
        let hours = WorkSegment.hoursByDay(weekSegments)
        let running = timer.isRunning ? timer.elapsed / 3600 : 0
        let start = preferences.trackingStartDate
        let day = today >= start ? calculator.periodSummary(from: today, to: today, hours: hours) : .empty
        let weekStart = max(today.startOfWeekZurich, start)
        let week = weekStart <= today ? calculator.periodSummary(from: weekStart, to: today, hours: hours) : .empty

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Today")).font(.caption).foregroundStyle(.secondary)
                    Text(TimeFormatting.hours(day.actualHours + running))
                        .font(.title2.bold().monospacedDigit())
                    Text(tr("of %@ expected", TimeFormatting.hours(day.expectedHours)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(tr("This Week")).font(.caption).foregroundStyle(.secondary)
                    Text(TimeFormatting.signedHours(week.balance + running))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(week.balance + running >= 0 ? .green : .red)
                }
            }

            Divider()

            if timer.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Label(tr("%@ · since %@", timer.project(in: modelContext)?.name ?? "",
                             TimeField.format(timer.startedAt ?? Date())),
                          systemImage: "timer")
                        .font(.subheadline)
                    HStack {
                        Button(role: .destructive) { timer.stop(context: modelContext) } label: {
                            Label(tr("Stop %@", TimeFormatting.clock(timer.elapsed)), systemImage: "stop.fill")
                                .monospacedDigit()
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        Menu(tr("Switch Project")) {
                            ForEach(projects) { project in
                                Button(project.name) { timer.switchProject(to: project, context: modelContext) }
                            }
                        }
                        .fixedSize()
                    }
                    Button(tr("Discard Timer")) { timer.discard() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else {
                HStack {
                    Picker(tr("Project"), selection: $selectedProject) {
                        ForEach(projects) { project in
                            Text(project.name).tag(Optional(project))
                        }
                    }
                    .labelsHidden()
                    Button {
                        if let project = selectedProject { timer.start(project: project) }
                    } label: {
                        Label(tr("Start"), systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(selectedProject == nil)
                }
            }

            Divider()

            if let question = deviceSync.question {
                // The app may run from the menu bar for days; the question is in the window.
                Label(tr("%@ — open Work Tracker to decide.", question.title), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(tr("Open Work Tracker")) {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button(tr("Quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .onAppear {
            if selectedProject == nil {
                selectedProject = EntryActions.lastUsedProject(in: modelContext) ?? projects.first
            }
        }
    }
}
