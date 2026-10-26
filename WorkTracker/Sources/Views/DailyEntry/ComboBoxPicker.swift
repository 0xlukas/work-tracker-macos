import SwiftUI
import AppKit

/// Editable combo box for picking an existing project. Autocomplete and matching are
/// case-insensitive; typed text that matches no project reverts to the current
/// selection — projects can only be created in the Projects screen.
struct ComboBoxPicker: NSViewRepresentable {
    let projects: [Project]
    @Binding var selection: Project?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        // Data-source mode so the coordinator controls completion — the default
        // item-list completion is a case-sensitive prefix match.
        comboBox.usesDataSource = true
        comboBox.dataSource = context.coordinator
        comboBox.completes = true  // Auto-complete as you type
        comboBox.isEditable = true
        comboBox.hasVerticalScroller = true
        comboBox.numberOfVisibleItems = 8
        comboBox.delegate = context.coordinator
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.comboBoxAction(_:))
        comboBox.placeholderString = tr("Type to search…")
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
        comboBox.controlSize = .regular
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true

        comboBox.reloadData()

        if let selected = selection {
            if comboBox.stringValue != selected.name {
                comboBox.stringValue = selected.name
            }
        } else if comboBox.stringValue.isEmpty {
            comboBox.stringValue = ""
        }

        context.coordinator.updating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate, NSComboBoxDataSource {
        var parent: ComboBoxPicker
        var updating = false

        init(_ parent: ComboBoxPicker) {
            self.parent = parent
        }

        // MARK: NSComboBoxDataSource

        func numberOfItems(in comboBox: NSComboBox) -> Int {
            parent.projects.count
        }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard index >= 0 && index < parent.projects.count else { return nil }
            return parent.projects[index].name
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            parent.projects.first {
                $0.name.range(of: string,
                              options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }?.name
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            parent.projects.firstIndex {
                $0.name.localizedCaseInsensitiveCompare(string) == .orderedSame
            } ?? NSNotFound
        }

        // MARK: NSComboBoxDelegate

        @objc func comboBoxAction(_ sender: NSComboBox) {
            selectProject(in: sender)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let comboBox = notification.object as? NSComboBox else { return }
            let index = comboBox.indexOfSelectedItem
            if index >= 0 && index < parent.projects.count {
                parent.selection = parent.projects[index]
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let comboBox = obj.object as? NSComboBox else { return }
            selectProject(in: comboBox)
        }

        private func selectProject(in comboBox: NSComboBox) {
            guard !updating else { return }
            let trimmed = comboBox.stringValue.trimmingCharacters(in: .whitespaces)

            // Exact (case-insensitive) match wins; anything else keeps the current
            // selection and the field snaps back to its name.
            if let match = parent.projects.first(where: {
                $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                parent.selection = match
            }
            let selectedName = parent.selection?.name ?? ""
            if comboBox.stringValue != selectedName {
                comboBox.stringValue = selectedName
            }
        }
    }
}
