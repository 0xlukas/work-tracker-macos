import SwiftUI
import SwiftData
import AppKit

struct SegmentEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]

    let segment: WorkSegment?

    @State private var entryDate: Date
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var selectedProject: Project?
    @State private var note: String
    /// Other entries on `entryDate`, refetched when the date changes.
    @State private var sameDayEntries: [WorkSegment] = []

    var isEditing: Bool { segment != nil }

    /// `suggestedStart` is the auto-filled start for a NEW entry — the end of the day's
    /// last segment, or 08:10 when the day is empty (computed by the caller). A
    /// `template` pre-fills project, note and duration (Duplicate). Both are ignored when
    /// editing an existing segment.
    init(date: Date, segment: WorkSegment?, suggestedStart: Date? = nil, template: WorkSegment? = nil) {
        self.segment = segment

        let cal = Calendar.zurich
        if let segment {
            _entryDate = State(initialValue: segment.date)
            _startTime = State(initialValue: segment.startTime)
            _endTime = State(initialValue: segment.endTime)
            _selectedProject = State(initialValue: segment.project)
            _note = State(initialValue: segment.note)
        } else {
            let day = date.startOfDayZurich
            let start = suggestedStart
                ?? cal.date(bySettingHour: 8, minute: 10, second: 0, of: day)
                ?? day
            let duration = template.map { $0.endTime.timeIntervalSince($0.startTime) } ?? 3600
            _entryDate = State(initialValue: day)
            _startTime = State(initialValue: start)
            _endTime = State(initialValue: min(start.addingTimeInterval(duration), day.addingDays(1)))
            _selectedProject = State(initialValue: template?.project)
            _note = State(initialValue: template?.note ?? "")
        }
    }

    /// A new entry pre-filled from a voice command, for the user to confirm.
    init(draft: EntryDraft, project: Project?) {
        self.segment = nil
        _entryDate = State(initialValue: draft.date.startOfDayZurich)
        _startTime = State(initialValue: draft.start)
        _endTime = State(initialValue: draft.end)
        _selectedProject = State(initialValue: project)
        _note = State(initialValue: draft.note)
    }

    /// Active projects, plus the selected one if it has been archived since.
    private var pickerProjects: [Project] {
        projects.filter { !$0.isArchived || $0 === selectedProject }
    }

    private var conflicts: [WorkSegment] {
        let editingID = segment?.persistentModelID
        return sameDayEntries.filter { $0.persistentModelID != editingID }
    }

    /// First blocking problem with the current input, or nil when it's valid.
    private var validationError: String? {
        if let problem = EntryActions.problem(start: startTime, end: endTime, on: entryDate, others: conflicts) {
            return problem
        }
        guard selectedProject != nil else { return tr("Select a project.") }
        return nil
    }

    var body: some View {
        // A NavigationStack gives the sheet the standard glass title bar with
        // Cancel/Save in the toolbar, so the form itself stays free of chrome.
        NavigationStack {
            Form {
                Section {
                    LabeledContent(tr("Start")) {
                        TimeField(time: $startTime, date: entryDate, autoFocus: true)
                            .frame(width: 72)
                    }
                    LabeledContent(tr("End")) {
                        TimeField(time: $endTime, date: entryDate, allowsEndOfDay: true)
                            .frame(width: 72)
                    }
                    LabeledContent(tr("Project")) {
                        ComboBoxPicker(projects: pickerProjects, selection: $selectedProject)
                            .frame(width: 180)
                    }
                    TextField(tr("Note"), text: $note, prompt: Text(tr("Optional")), axis: .vertical)
                        .lineLimit(1...3)

                    // Date lives below the entry fields so it doesn't interrupt the
                    // Start → End → Project flow (it's usually already the selected day).
                    DatePicker(tr("Date"), selection: $entryDate, displayedComponents: .date)
                        .onChange(of: entryDate) { oldDay, newDay in
                            startTime = EntryActions.moved(startTime, from: oldDay, to: newDay)
                            endTime = EntryActions.moved(endTime, from: oldDay, to: newDay)
                        }
                }

                Section {
                    if let error = validationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    } else {
                        LabeledContent(tr("Duration")) {
                            Text(TimeFormatting.hours(endTime.timeIntervalSince(startTime) / 3600))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? tr("Edit Time Entry") : tr("New Time Entry"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? tr("Save") : tr("Add")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(validationError != nil)
                }
            }
        }
        .frame(width: 440, height: 390)
        .background {
            // Save from anywhere in the sheet (⌘↩), even while a text field or the
            // project picker has focus. Hidden — the toolbar button handles plain Return.
            Button("") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: entryDate) {
            sameDayEntries = EntryActions.segments(on: entryDate, in: modelContext)
        }
        .onAppear {
            if selectedProject == nil {
                selectedProject = EntryActions.lastUsedProject(in: modelContext) ?? fallbackProject
            }
        }
    }

    // MARK: - Helpers

    /// A project called "Other" (in any UI language), else the first active project.
    private var fallbackProject: Project? {
        let names = Localization.allTranslations(of: "Other")
        let active = projects.filter { !$0.isArchived }
        return active.first { project in
            names.contains { $0.compare(project.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        } ?? active.first
    }

    /// End any in-progress edit first, so a time typed and confirmed with Return is
    /// committed before saving; then save on the next run-loop turn.
    private func save() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { commit() }
    }

    private func commit() {
        guard validationError == nil, let project = selectedProject else {
            NSSound.beep()
            return
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sync may have deleted the entry on another Mac meanwhile; then save it anew.
        if let segment, segment.modelContext != nil, !segment.isDeleted {
            segment.date = entryDate.startOfDayZurich
            segment.startTime = startTime
            segment.endTime = endTime
            segment.project = project
            segment.note = trimmedNote
            segment.recalculateDuration()
        } else {
            modelContext.insert(WorkSegment(date: entryDate, startTime: startTime, endTime: endTime,
                                            project: project, note: trimmedNote))
        }
        dismiss()
    }
}
