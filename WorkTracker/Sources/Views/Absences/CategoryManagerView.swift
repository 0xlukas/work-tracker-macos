import SwiftUI
import SwiftData

struct CategoryManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AbsenceCategory.name) private var categories: [AbsenceCategory]
    @State private var editing: CategoryDraft?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Built-in categories")) {
                    ForEach(AbsenceType.builtIns, id: \.rawValue) { type in
                        Label(type.details.name, systemImage: type.details.icon)
                            .foregroundStyle(type.details.color.color)
                    }
                }

                Section {
                    if categories.isEmpty {
                        Text(tr("No custom categories yet."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(categories) { category in
                        categoryRow(category)
                    }
                    // Sheets only surface cancel/confirm toolbar items on macOS, so the
                    // add action lives in the form where it is always visible.
                    Button {
                        editing = CategoryDraft()
                    } label: {
                        Label(tr("Add Category"), systemImage: "plus")
                    }
                    .accessibilityLabel(tr("Add Category"))
                } header: {
                    Text(tr("Custom categories"))
                } footer: {
                    Text(tr("Archive categories to hide them from the picker. Existing entries and reports are preserved."))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tr("Manage Categories"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 640, height: 480)
        .sheet(item: $editing) { draft in
            CategoryEditorView(draft: draft, categories: categories)
        }
        .alert(tr("Could not save changes"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button(tr("OK")) { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func categoryRow(_ category: AbsenceCategory) -> some View {
        HStack(spacing: 12) {
            Label(category.name, systemImage: category.icon)
                .foregroundStyle(category.isArchived ? AnyShapeStyle(.secondary) : AnyShapeStyle(category.color.color))

            VStack(alignment: .leading, spacing: 1) {
                Text(category.rule.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if category.isArchived {
                    Text(tr("Archived"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button(tr("Edit")) { editing = CategoryDraft(category: category) }
                Button(category.isArchived ? tr("Restore") : tr("Archive")) {
                    category.isArchived.toggle()
                    do { try modelContext.save() }
                    catch {
                        category.isArchived.toggle()
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

struct CategoryDraft: Identifiable {
    let id = UUID()
    var category: AbsenceCategory?
    var name = ""
    var icon = "calendar.badge.clock"
    var color: PaletteColor = .purple
    var rule: AbsenceCountingRule = .reduceHours

    init(category: AbsenceCategory? = nil) {
        self.category = category
        if let category {
            name = category.name
            icon = category.icon
            color = category.color
            rule = category.rule
        }
    }
}

struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State var draft: CategoryDraft
    let categories: [AbsenceCategory]
    @State private var errorMessage: String?

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicateName: Bool {
        AbsenceCategory.isDuplicate(name: trimmedName, in: categories, excluding: draft.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("Name"), text: $draft.name)
                    // Swatches instead of a menu: pop-up menus draw symbol images as
                    // monochrome templates, so a tinted circle in a menu shows up white.
                    LabeledContent(tr("Colour")) {
                        ColorSwatchPicker(selection: $draft.color)
                    }
                    Picker(tr("Icon"), selection: $draft.icon) {
                        ForEach(AbsenceCategory.iconChoices, id: \.symbol) { icon in
                            Label(tr(icon.name), systemImage: icon.symbol).tag(icon.symbol)
                        }
                    }
                } footer: {
                    if duplicateName {
                        Text(tr("A category with this name already exists."))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker(tr("Counting rule"), selection: $draft.rule) {
                        ForEach(AbsenceCountingRule.allCases, id: \.self) { rule in Text(rule.title).tag(rule) }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Reducing expected hours gives time off without using vacation. Vacation categories share your annual allowance. Unchanged hours give no time credit."))
                        Text(tr("Counting rule changes apply to new entries. Existing entries keep their original rule."))
                    }
                }

                Section(tr("Preview")) {
                    Label(trimmedName.isEmpty ? tr("Preview") : trimmedName, systemImage: draft.icon)
                        .foregroundStyle(draft.color.color)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.category == nil ? tr("Add Category") : tr("Edit Category"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty || trimmedName.count > 60 || duplicateName)
                }
            }
        }
        .frame(width: 500, height: 460)
    }

    private func save() {
        let category = draft.category ?? AbsenceCategory(name: trimmedName)
        let old = CategoryDraft(category: category)
        if draft.category == nil { modelContext.insert(category) }
        category.name = trimmedName
        category.icon = draft.icon
        category.colorRaw = draft.color.rawValue
        category.ruleRaw = draft.rule.rawValue
        do { try modelContext.save(); dismiss() }
        catch {
            if draft.category == nil { modelContext.delete(category) }
            else {
                category.name = old.name
                category.icon = old.icon
                category.colorRaw = old.color.rawValue
                category.ruleRaw = old.rule.rawValue
            }
            errorMessage = error.localizedDescription
        }
    }
}
