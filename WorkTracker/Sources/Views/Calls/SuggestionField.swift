import SwiftUI
import AppKit

/// Text field that suggests names while typing (callers, topics): it completes the
/// first suggestion that starts with what's typed, ignoring case and accents, and lists
/// them all in its menu. Unlike `ComboBoxPicker`, any text is accepted, so a new name
/// is simply typed.
struct SuggestionField: NSViewRepresentable {
    @Binding var text: String
    let suggestions: [String]
    var placeholder = ""
    /// Grab keyboard focus when the field first appears.
    var autoFocus = false
    /// Changing this value moves keyboard focus to the field.
    var focusRequest = 0
    /// Return was pressed in the field (not called when an item is picked from the menu).
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = FocusingComboBox()
        comboBox.focusesWhenShown = autoFocus
        comboBox.usesDataSource = true
        comboBox.dataSource = context.coordinator
        comboBox.delegate = context.coordinator
        comboBox.completes = true
        comboBox.isEditable = true
        comboBox.hasVerticalScroller = true
        comboBox.numberOfVisibleItems = 8
        comboBox.placeholderString = placeholder
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.comboBoxAction(_:))
        comboBox.stringValue = text
        context.coordinator.lastValue = text
        context.coordinator.lastFocusRequest = focusRequest
        return comboBox
    }

    /// The offered width, not the text's: a combo box grows with its text, and a long name
    /// widened the whole call panel.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSComboBox, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 220
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        comboBox.reloadData()
        // Changed from outside (a suggestion button, a cleared draft): show it, also
        // while the field is being edited.
        if text != coordinator.lastValue {
            coordinator.lastValue = text
            comboBox.stringValue = text
            (comboBox.currentEditor() as? NSTextView)?.string = text
        }
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { comboBox.window?.makeFirstResponder(comboBox) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate, NSComboBoxDataSource {
        var parent: SuggestionField
        var lastValue = ""
        var lastFocusRequest = 0

        init(_ parent: SuggestionField) { self.parent = parent }

        private func push(_ value: String) {
            guard value != lastValue else { return }
            lastValue = value
            parent.text = value
        }

        // MARK: NSComboBoxDataSource

        func numberOfItems(in comboBox: NSComboBox) -> Int { parent.suggestions.count }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            parent.suggestions.indices.contains(index) ? parent.suggestions[index] : nil
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            guard !string.isEmpty else { return nil }
            return parent.suggestions.first {
                $0.range(of: string, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            parent.suggestions.firstIndex { CallNames.same($0, string) } ?? NSNotFound
        }

        // MARK: NSComboBoxDelegate

        func controlTextDidChange(_ obj: Notification) {
            guard let comboBox = obj.object as? NSComboBox else { return }
            push(comboBox.stringValue)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            let index = comboBox.indexOfSelectedItem
            if parent.suggestions.indices.contains(index) { push(parent.suggestions[index]) }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let comboBox = obj.object as? NSComboBox else { return }
            push(comboBox.stringValue)
        }

        @objc func comboBoxAction(_ sender: NSComboBox) {
            push(sender.stringValue)
            // The action also fires when an item is picked from the menu.
            guard let event = NSApp.currentEvent, event.type == .keyDown,
                  event.keyCode == 36 || event.keyCode == 76 else { return }  // Return / keypad Enter
            parent.onSubmit?()
        }
    }
}

/// Takes keyboard focus once it's in a window (a SwiftUI update may not follow then).
private final class FocusingComboBox: NSComboBox {
    var focusesWhenShown = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesWhenShown, let window else { return }
        focusesWhenShown = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }
}
