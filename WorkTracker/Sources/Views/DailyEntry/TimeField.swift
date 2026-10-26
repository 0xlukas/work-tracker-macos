import SwiftUI
import AppKit

/// A single text field for entering a time of day. Type it in one go as `HHMM`
/// (e.g. `0930`), as `HMM` (`930`), as one/two digits for the hour (`9`, `09`), or
/// with a separator (`9:30`, `9.30`, `9 30`). The hour and minute can still be edited
/// individually by selecting that part of the text, and ↑/↓ nudge the value (⇧ for
/// whole hours). The bound `Date` keeps the day from `date` and only changes its
/// time-of-day.
///
/// Backed by `NSTextField` so that focusing the field (via Tab or click) selects all
/// its text — typing then replaces the pre-filled default instead of appending to it.
struct TimeField: NSViewRepresentable {
    @Binding var time: Date
    /// The day the time belongs to — used to re-anchor the parsed time-of-day.
    let date: Date
    /// Grab keyboard focus when the field first appears (used for the Start field).
    var autoFocus: Bool = false
    /// Accept `24:00` (midnight at the end of `date`) — used for the End field.
    var allowsEndOfDay: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = SelectAllTextField()
        field.delegate = context.coordinator
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.controlSize = .regular
        field.stringValue = Self.format(time, on: date)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if autoFocus { context.coordinator.wantsInitialFocus = true }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Don't clobber what the user is typing; only refresh the display when the
        // field isn't being edited (e.g. an externally auto-filled default).
        if field.currentEditor() == nil {
            let formatted = Self.format(time, on: date)
            if field.stringValue != formatted { field.stringValue = formatted }
        }
        if context.coordinator.wantsInitialFocus, let window = field.window {
            context.coordinator.wantsInitialFocus = false
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeField
        var wantsInitialFocus = false

        init(_ parent: TimeField) { self.parent = parent }

        /// Commit on Tab, Return, or click-away.
        func controlTextDidEndEditing(_ obj: Notification) {
            commit(obj.object as? NSTextField)
        }

        /// ↑/↓ nudge the time without leaving the field (⇧ = whole hours).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            let shift = NSEvent.modifierFlags.contains(.shift)
            let step = shift ? 60 : 1
            if selector == #selector(NSResponder.moveUp(_:)) { nudge(field, +step); return true }
            if selector == #selector(NSResponder.moveDown(_:)) { nudge(field, -step); return true }
            return false
        }

        /// Parse and write back to the binding; revert + beep on invalid input.
        func commit(_ field: NSTextField?) {
            guard let field else { return }
            if let parsed = TimeField.parse(field.stringValue, on: parent.date, allowsEndOfDay: parent.allowsEndOfDay) {
                parent.time = parsed
                field.stringValue = TimeField.format(parsed, on: parent.date)
            } else {
                field.stringValue = TimeField.format(parent.time, on: parent.date)
                NSSound.beep()
            }
        }

        private func nudge(_ field: NSTextField, _ minutes: Int) {
            let day = parent.date.startOfDayZurich
            let base = TimeField.parse(field.stringValue, on: day, allowsEndOfDay: parent.allowsEndOfDay) ?? parent.time
            let current = Calendar.zurich.dateComponents([.minute], from: day, to: base).minute ?? 0
            // Wrap within the day; the End field also reaches 24:00.
            let span = parent.allowsEndOfDay ? 1441 : 1440
            let total = (((current + minutes) % span) + span) % span
            let newTime = Calendar.zurich.date(byAdding: .minute, value: total, to: day)!
            parent.time = newTime
            field.stringValue = TimeField.format(newTime, on: day)
        }
    }

    // MARK: - Parsing & formatting

    nonisolated static func format(_ time: Date) -> String {
        let comps = Calendar.zurich.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    /// Like `format(_:)`, but midnight at the end of `day` reads `24:00`.
    nonisolated static func format(_ time: Date, on day: Date) -> String {
        time == day.startOfDayZurich.addingDays(1) ? "24:00" : format(time)
    }

    /// Parse compact (`0930`, `930`, `9`) or separated (`9:30`) input into a `Date`
    /// on `day`. Returns nil for anything that isn't a valid 24h time. With
    /// `allowsEndOfDay`, `24`/`24:00`/`2400` mean midnight at the end of `day`.
    nonisolated static func parse(_ input: String, on day: Date, allowsEndOfDay: Bool = false) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let hour: Int
        let minute: Int

        if let separator = trimmed.first(where: { !$0.isNumber }) {
            // Explicit separator: "9:30", "9.30", "9 30"
            let parts = trimmed.split(separator: separator, omittingEmptySubsequences: false)
            guard let h = Int(parts.first ?? "") else { return nil }
            hour = h
            minute = parts.count > 1 ? (Int(parts[1]) ?? -1) : 0
        } else {
            let digits = trimmed.filter(\.isNumber)
            switch digits.count {
            case 1, 2:                       // "9" / "09" → hour only
                hour = Int(digits) ?? -1
                minute = 0
            case 3:                          // "930" → H:MM
                hour = Int(digits.prefix(1)) ?? -1
                minute = Int(digits.suffix(2)) ?? -1
            case 4...:                       // "0930" (or longer) → last 4 as HHMM
                let last4 = digits.suffix(4)
                hour = Int(last4.prefix(2)) ?? -1
                minute = Int(last4.suffix(2)) ?? -1
            default:
                return nil
            }
        }

        if allowsEndOfDay && hour == 24 && minute == 0 {
            return day.startOfDayZurich.addingDays(1)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return Calendar.zurich.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}

/// NSTextField that selects all of its text whenever it gains focus, so the pre-filled
/// default is replaced (not appended to) when the user starts typing. It also lets
/// ⌘Return pass through — committing the current edit first — so the sheet's ⌘↩ "save"
/// shortcut works even while this field is focused.
final class SelectAllTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return became
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return / keypad Enter
        if event.modifierFlags.contains(.command) && isReturn {
            // End editing so the delegate commits the typed value, then let the event
            // continue to the window's ⌘↩ key equivalent (the sheet's Save button).
            window?.makeFirstResponder(nil)
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
