import SwiftUI
import SwiftData
import AppKit

/// Change a call, or log one that happened earlier (the panel logs calls as of now).
struct CallEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(Preferences.self) private var preferences
    @Query private var recentCalls: [PhoneCall]

    let call: PhoneCall?

    @State private var caller: String
    @State private var topic: String
    @State private var department: String
    @State private var length: CallLength
    @State private var solvedByMe: Bool
    @State private var note: String
    @State private var date: Date

    init(call: PhoneCall?) {
        self.call = call
        _recentCalls = Query(CallSuggestions.source)
        _caller = State(initialValue: call?.caller ?? "")
        _topic = State(initialValue: call?.topic ?? "")
        _department = State(initialValue: call?.department ?? "")
        _length = State(initialValue: call?.length ?? .short)
        _solvedByMe = State(initialValue: call?.solvedByMe ?? false)
        _note = State(initialValue: call?.note ?? "")
        _date = State(initialValue: call?.date ?? Date().roundedToMinute)
    }

    /// The departments in Settings, plus this call's if it has since been removed there.
    private var departments: [String] {
        let list = preferences.callDepartments
        return department.isEmpty || list.contains(department) ? list : list + [department]
    }

    var body: some View {
        let suggestions = CallSuggestions(calls: recentCalls)
        NavigationStack {
            Form {
                Section {
                    LabeledContent(tr("Caller")) {
                        SuggestionField(text: $caller, suggestions: suggestions.callers, placeholder: tr("Who called?"),
                                        autoFocus: call == nil)
                            .frame(width: 220)
                    }
                    LabeledContent(tr("Topic")) {
                        SuggestionField(text: $topic, suggestions: suggestions.topicList(for: caller),
                                        placeholder: tr("What about?"))
                            .frame(width: 220)
                    }
                    Picker(tr("Department"), selection: $department) {
                        Text(tr("None")).tag("")
                        if !departments.isEmpty { Divider() }
                        ForEach(departments, id: \.self) { Text($0).tag($0) }
                    }
                    Picker(tr("Length"), selection: $length) {
                        ForEach(CallLength.allCases) { Text($0.title).tag($0).help($0.detail) }
                    }
                    .pickerStyle(.segmented)
                    Toggle(tr("Solved by me"), isOn: $solvedByMe)
                    TextField(tr("Note"), text: $note, prompt: Text(tr("Optional")), axis: .vertical)
                        .lineLimit(1...3)
                    DatePicker(tr("When"), selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .formStyle(.grouped)
            .navigationTitle(call == nil ? tr("Log Earlier Call") : tr("Edit Call"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(call == nil ? tr("Add") : tr("Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(CallNames.trimmed(caller).isEmpty)
                }
            }
        }
        .frame(width: 460, height: 420)
    }

    /// End the edit in progress first, so typed and completed names are in the form.
    private func save() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { commit() }
    }

    private func commit() {
        guard !CallNames.trimmed(caller).isEmpty else { return NSSound.beep() }
        // Sync may have deleted the call on another Mac meanwhile; then it's added anew.
        if let call, call.modelContext != nil, !call.isDeleted {
            let others = recentCalls.filter { $0.persistentModelID != call.persistentModelID }
            call.caller = CallNames.canonical(caller, in: others.map(\.caller))
            call.topic = CallNames.canonical(topic, in: others.map(\.topic))
            call.department = department
            call.length = length
            call.solvedByMe = solvedByMe
            call.note = CallNames.trimmed(note)
            call.date = date
        } else {
            CallLog.add(caller: caller, topic: topic, department: department, note: note, length: length,
                        solvedByMe: solvedByMe, at: date, context: modelContext)
        }
        dismiss()
    }
}
