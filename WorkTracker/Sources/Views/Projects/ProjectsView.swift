import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkTimer.self) private var timer
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var newProjectName = ""
    @State private var newProjectError: String?
    @State private var editingProject: Project?
    @State private var editName = ""
    @State private var editError: String?
    @State private var deleteErrorMessage: String?
    @State private var hoveredProject: Project?
    @State private var projectPendingDelete: Project?
    @State private var colorPickerProject: Project?
    @State private var showArchived = false
    @FocusState private var newProjectFieldFocused: Bool

    @State private var reportFrom = Calendar.zurich.zurichDate(year: Date().zurichYear, month: 1, day: 1)
    @State private var reportTo = Date().startOfDayZurich

    private var activeProjects: [Project] { projects.filter { !$0.isArchived } }
    private var archivedProjects: [Project] { projects.filter(\.isArchived) }

    var body: some View {
        HStack(spacing: 0) {
            projectsPane
                .frame(minWidth: 300, idealWidth: 320)

            Divider()

            reportPane
                .frame(minWidth: 360)
        }
        .navigationTitle(tr("Projects"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newProjectFieldFocused = true
                } label: {
                    Label(tr("New Project"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help(tr("New Project (⌘N)"))
            }
        }
        .alert(tr("Cannot Delete"), isPresented: Binding(
            get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button(tr("OK")) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .confirmationDialog(
            tr("Delete this project?"),
            isPresented: Binding(
                get: { projectPendingDelete != nil },
                set: { if !$0 { projectPendingDelete = nil } }
            ),
            presenting: projectPendingDelete
        ) { project in
            Button(tr("Delete"), role: .destructive) {
                modelContext.delete(project)
                projectPendingDelete = nil
            }
            Button(tr("Cancel"), role: .cancel) { projectPendingDelete = nil }
        } message: { project in
            Text(tr("'%@' will be removed. You can undo this with ⌘Z.", project.name))
        }
    }

    // MARK: - Left: Projects

    private var projectsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Projects"))
                    .font(.title3.bold())
                Text(tr("%lld projects", activeProjects.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(activeProjects) { project in
                        projectRow(project)
                    }

                    if !archivedProjects.isEmpty {
                        DisclosureGroup(isExpanded: $showArchived) {
                            ForEach(archivedProjects) { project in
                                projectRow(project)
                            }
                        } label: {
                            Text(tr("Archived (%lld)", archivedProjects.count))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider()
                .padding(.horizontal, 12)

            // Add project
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                    TextField(tr("Add new project..."), text: $newProjectName)
                        .textFieldStyle(.plain)
                        .focused($newProjectFieldFocused)
                        .onSubmit { addProject() }
                        .onChange(of: newProjectName) { newProjectError = nil }
                }
                if let newProjectError {
                    Text(newProjectError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Right: Time Report

    private var reportPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Time Report"))
                    .font(.title3.bold())
                Text(tr("Hours per project"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text(tr("From"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    DatePicker(tr("From"), selection: $reportFrom, in: ...reportTo, displayedComponents: .date)
                        .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text(tr("To"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    DatePicker(tr("To"), selection: $reportTo, in: reportFrom..., displayedComponents: .date)
                        .labelsHidden()
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 24)

            ProjectReport(from: reportFrom, to: reportTo)
        }
    }

    // MARK: - Project Row

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        if editingProject === project {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField(tr("Project name"), text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveEdit(project) }
                        .onChange(of: editName) { editError = nil }
                    Button(tr("Save")) { saveEdit(project) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(tr("Cancel")) { editingProject = nil }
                        .controlSize(.small)
                }
                if let editError {
                    Text(editError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        } else {
            let isHovered = hoveredProject === project
            HStack(spacing: 12) {
                Button {
                    colorPickerProject = project
                } label: {
                    Circle()
                        .fill(project.color.color.opacity(project.isArchived ? 0.08 : 0.15))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Text(String(project.name.prefix(1)).uppercased())
                                .font(.subheadline.bold())
                                .foregroundStyle(project.color.color)
                        }
                }
                .buttonStyle(.plain)
                .help(tr("Change colour"))
                .accessibilityLabel(tr("Change colour of %@", project.name))
                .popover(isPresented: Binding(
                    get: { colorPickerProject === project },
                    set: { if !$0 { colorPickerProject = nil } }
                )) {
                    ColorSwatchPicker(selection: Binding(get: { project.color }, set: { project.color = $0 }))
                        .padding(12)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.body)
                        .foregroundStyle(project.isArchived ? .secondary : .primary)
                    Text(tr("%lld entries", project.segments.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isHovered {
                    HStack(spacing: 4) {
                        Button { startEditing(project) } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(tr("Rename project"))
                        .accessibilityLabel(tr("Rename project"))

                        Button { project.isArchived.toggle() } label: {
                            Image(systemName: project.isArchived ? "tray.and.arrow.up" : "archivebox")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(project.isArchived ? tr("Restore project") : tr("Archive project"))
                        .accessibilityLabel(project.isArchived ? tr("Restore project") : tr("Archive project"))

                        Button { requestDelete(project) } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help(tr("Delete project"))
                        .accessibilityLabel(tr("Delete project"))
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .rowHighlight(isHovered)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    hoveredProject = hovering ? project : nil
                }
            }
            .onTapGesture(count: 2) { startEditing(project) }
            // One VoiceOver element per project; the hover buttons are unreachable for
            // VoiceOver, so offer the same actions on the row.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.isArchived ? tr("%@, archived", project.name) : project.name)
            .accessibilityValue(tr("%lld entries", project.segments.count))
            .accessibilityAction(named: tr("Rename")) { startEditing(project) }
            .accessibilityAction(named: project.isArchived ? tr("Restore") : tr("Archive")) { project.isArchived.toggle() }
            .accessibilityAction(named: tr("Delete")) { requestDelete(project) }
            .contextMenu {
                Button { startEditing(project) } label: { Label(tr("Rename"), systemImage: "pencil") }
                Button { colorPickerProject = project } label: { Label(tr("Change Colour…"), systemImage: "paintpalette") }
                Button { project.isArchived.toggle() } label: {
                    project.isArchived
                        ? Label(tr("Restore"), systemImage: "tray.and.arrow.up")
                        : Label(tr("Archive"), systemImage: "archivebox")
                }
                Divider()
                Button(role: .destructive) { requestDelete(project) } label: {
                    Label(tr("Delete"), systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Actions

    private func addProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !Project.isDuplicate(name: name, in: projects) else {
            newProjectError = tr("A project with this name already exists.")
            return
        }
        modelContext.insert(Project(name: name, color: Project.suggestedColor(existing: projects)))
        newProjectName = ""
    }

    private func startEditing(_ project: Project) {
        editingProject = project
        editName = project.name
        editError = nil
    }

    private func saveEdit(_ project: Project) {
        // Deleted on another Mac while being renamed here.
        guard project.modelContext != nil, !project.isDeleted else {
            editingProject = nil
            return
        }
        let name = editName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            editError = tr("Enter a name.")
            return
        }
        guard !Project.isDuplicate(name: name, in: projects, excluding: project) else {
            editError = tr("A project with this name already exists.")
            return
        }
        project.name = name
        editingProject = nil
    }

    private func requestDelete(_ project: Project) {
        if timer.isRunning && timer.projectID == project.persistentModelID {
            // Stopping the timer needs the project, or the tracked time is lost.
            deleteErrorMessage = tr("A timer is running for '%@'. Stop it first.", project.name)
        } else if project.segments.isEmpty {
            projectPendingDelete = project
        } else {
            deleteErrorMessage = tr("'%@' has %lld time entries. Delete or reassign them first, or archive the project.",
                                    project.name, project.segments.count)
        }
    }
}

/// Hours per project for a date range; fetches only that range.
private struct ProjectReport: View {
    @Query private var segments: [WorkSegment]
    private let from: Date
    private let to: Date

    init(from: Date, to: Date) {
        self.from = from
        self.to = to
        let start = from.startOfDayZurich, end = to.startOfDayZurich.addingDays(1)
        _segments = Query(filter: #Predicate<WorkSegment> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let breakdown = WorkHoursCalculator.projectBreakdown(from: from, to: to, segments: segments)
        if breakdown.isEmpty {
            ContentUnavailableView {
                Label(tr("No work logged in this period"), systemImage: "chart.bar")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let maxHours = breakdown.map(\.hours).max() ?? 1
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(breakdown) { item in
                        row(item, maxHours: maxHours)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                HStack {
                    Text(tr("Total"))
                        .font(.subheadline.bold())
                    Spacer()
                    Text(TimeFormatting.hours(breakdown.reduce(0) { $0 + $1.hours }))
                        .font(.body.bold().monospacedDigit())
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }

    private func row(_ item: ProjectHours, maxHours: Double) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(item.project.name)
                    .font(.subheadline)
                if item.project.isArchived {
                    Text(tr("Archived"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(TimeFormatting.hours(item.hours))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            MeterBar(progress: maxHours > 0 ? item.hours / maxHours : 0,
                     color: item.project.color.color,
                     height: 6)
        }
        .padding(.vertical, 8)
    }
}
