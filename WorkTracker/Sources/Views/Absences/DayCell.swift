import SwiftUI
import AppKit

/// One clickable day in the Absences grid (AppKit-backed for reliable Shift-clicks).
struct DayCell: NSViewRepresentable {
    let date: Date
    let absence: VacationDay?
    let isHalfDayHoliday: Bool
    let isOverAllowance: Bool
    let isLastClicked: Bool
    let action: (Bool) -> Void  // Bool = isShiftHeld

    func makeNSView(context: Context) -> DayCellNSView {
        let view = DayCellNSView()
        view.action = action
        updateAppearance(view)
        return view
    }

    func updateNSView(_ nsView: DayCellNSView, context: Context) {
        nsView.action = action
        updateAppearance(nsView)
    }

    private func updateAppearance(_ view: DayCellNSView) {
        view.configure(
            dayText: date.formatted(.app.day()),
            weekdayText: date.formatted(.app.weekday(.abbreviated)),
            category: absence?.categoryDetails,
            isHalfDayAbsence: absence?.isHalfDay == true,
            isHalfDayHoliday: isHalfDayHoliday,
            isOverAllowance: isOverAllowance,
            isLastClicked: isLastClicked
        )
    }
}

final class DayCellNSView: NSView {
    var action: ((Bool) -> Void)?

    private let weekdayLabel = NSTextField(labelWithString: "")
    private let dayLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var category: CategoryDetails?
    private var isHalfDayAbsence = false
    private var isHalfDayHoliday = false
    private var isOverAllowance = false
    private var isLastClicked = false
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        wantsLayer = true
        layer?.cornerRadius = 8

        // Dynamic Type: size tracks the user's text-size setting.
        weekdayLabel.font = .preferredFont(forTextStyle: .caption2)
        weekdayLabel.alignment = .center
        weekdayLabel.isBezeled = false
        weekdayLabel.drawsBackground = false
        weekdayLabel.isEditable = false

        dayLabel.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .bold)
        dayLabel.alignment = .center
        dayLabel.isBezeled = false
        dayLabel.drawsBackground = false
        dayLabel.isEditable = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.isHidden = true

        addSubview(weekdayLabel)
        addSubview(dayLabel)
        addSubview(iconView)
        // The cell's own label already reads "Mon 5, Vacation"; don't repeat its parts.
        for view in [weekdayLabel, dayLabel, iconView] as [NSView] { view.setAccessibilityElement(false) }

        setAccessibilityRole(.button)
        setAccessibilityElement(true)

        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 40) }

    override func layout() {
        super.layout()
        weekdayLabel.frame = NSRect(x: 0, y: 20, width: bounds.width, height: 14)
        dayLabel.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 16)
        // Bottom-right corner: the weekday label spans the full width at the top.
        iconView.frame = NSRect(x: bounds.width - 12, y: 3, width: 9, height: 9)
    }

    func configure(dayText: String, weekdayText: String, category: CategoryDetails?,
                   isHalfDayAbsence: Bool, isHalfDayHoliday: Bool, isOverAllowance: Bool, isLastClicked: Bool) {
        dayLabel.stringValue = dayText
        weekdayLabel.stringValue = weekdayText
        self.category = category
        self.isHalfDayAbsence = isHalfDayAbsence
        self.isHalfDayHoliday = isHalfDayHoliday
        self.isOverAllowance = isOverAllowance
        self.isLastClicked = isLastClicked

        let icon = isOverAllowance ? "exclamationmark.triangle.fill" : category?.icon
        iconView.image = icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: category?.name) }
        iconView.isHidden = category == nil
        var stateText: String
        if let category {
            stateText = isHalfDayAbsence ? tr("%@ (half day)", category.name) : category.name
            if isOverAllowance { stateText += " " + tr("(over allowance)") }
        } else {
            stateText = isHalfDayHoliday ? tr("half-day holiday") : tr("no absence")
        }
        toolTip = stateText
        setAccessibilityLabel(tr("%@ %@, %@", weekdayText, dayText, stateText))

        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    private func applyColors() {
        let baseColor = category?.color.nsColor

        iconView.contentTintColor = .white

        if let baseColor {
            if isHalfDayAbsence {
                // Half-day: lighter fill, colored border. The fill is translucent, so the
                // text uses label colours (white text on it was unreadable in light mode).
                layer?.backgroundColor = baseColor.withAlphaComponent(0.4).cgColor
                dayLabel.textColor = .labelColor
                weekdayLabel.textColor = .secondaryLabelColor
                iconView.contentTintColor = .labelColor
                layer?.borderWidth = 2
                layer?.borderColor = baseColor.cgColor
            } else {
                // Full day
                layer?.backgroundColor = baseColor.cgColor
                dayLabel.textColor = .white
                weekdayLabel.textColor = .white.withAlphaComponent(0.85)
                layer?.borderWidth = isLastClicked ? 2 : 0
                layer?.borderColor = NSColor.white.cgColor
            }
            if isOverAllowance {
                layer?.borderWidth = 2
                layer?.borderColor = NSColor.systemRed.cgColor
            }
        } else if isHovered {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            dayLabel.textColor = .labelColor
            weekdayLabel.textColor = .secondaryLabelColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        } else if isHalfDayHoliday {
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
            dayLabel.textColor = .labelColor
            weekdayLabel.textColor = .secondaryLabelColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            dayLabel.textColor = .labelColor
            weekdayLabel.textColor = .secondaryLabelColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Visual press feedback
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.05
            self.animator().alphaValue = 0.6
        }
    }

    override func mouseUp(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 1.0
        }
        // Releasing outside the cell cancels the click, like a standard button.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?(event.modifierFlags.contains(.shift))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateColors()
    }

    // MARK: Keyboard & VoiceOver

    /// Reachable with Tab when Full Keyboard Access is on; Space/Return toggle the day
    /// (Shift for a range), matching a click.
    /// Only with keyboard navigation on, so plain clicks don't leave a focus ring behind.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r": action?(event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { noteFocusRingMaskChanged() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { noteFocusRingMaskChanged() }
        return resigned
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func accessibilityPerformPress() -> Bool {
        action?(false)
        return true
    }

    // MARK: Appearance

    /// Layer colours are static CGColors; re-resolve them when light/dark or the
    /// accent colour changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}
