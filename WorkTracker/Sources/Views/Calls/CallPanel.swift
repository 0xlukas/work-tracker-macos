import SwiftUI
import SwiftData
import AppKit

/// Logging calls from anywhere: the call shortcut (from any app), the menu bar and the
/// Calls screen open a small floating panel; picking the call's length saves it.
@MainActor
@Observable
final class CallControl {
    /// Another app already uses the chosen shortcut.
    private(set) var shortcutUnavailable = false

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var panel: CallPanelWindow?
    @ObservationIgnored private var hotKey: GlobalHotKey?

    init(preferences: Preferences = .shared, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.defaults = defaults
    }

    func start(container: ModelContainer) {
        self.container = container
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        applySettings()
    }

    /// The shortcut: open the panel, or close it when it's already in front.
    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            close()
        } else {
            open()
        }
    }

    /// Show the panel with an empty form, or bring it to the front as it is.
    func open() {
        guard let container, preferences.callTrackingEnabled else { return }
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            let controller = NSHostingController(rootView: CallPanelView(
                shortcut: preferences.callShortcut,
                departments: preferences.callDepartments,
                commitEditing: { [weak panel] in _ = panel?.makeFirstResponder(nil) },
                onLog: { [weak self] draft in self?.log(draft) },
                onCancel: { [weak self] in self?.close() })
                .modelContainer(container)
                .environment(\.locale, Localization.locale))
            // The panel keeps the size measured here, once the form is in it (so the title
            // bar counts). Letting SwiftUI resize it while AppKit laid it out
            // (`.preferredContentSize`) looped until AppKit gave up and the app crashed; the
            // form keeps one height whatever is typed, so this size always fits.
            controller.sizingOptions = []
            panel.contentViewController = controller
            let size = controller.sizeThatFits(in: CGSize(width: CallPanelView.width, height: 2000))
            panel.setContentSize(NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up)))
            if let saved = defaults.string(forKey: Self.positionKey) {
                panel.setFrameTopLeftPoint(NSPointFromString(saved))
                panel.setFrame(panel.constrainFrameRect(panel.frame, to: panel.screen ?? NSScreen.main), display: false)
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        // Where the panel was, for the next call.
        if let panel, panel.isVisible {
            defaults.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: Self.positionKey)
        }
        panel?.orderOut(nil)
        // Drop the form, so the next call starts empty.
        panel?.contentViewController = nil
    }

    private func log(_ draft: CallDraft) {
        guard let context = container?.mainContext, !CallNames.trimmed(draft.caller).isEmpty else { return }
        CallLog.add(caller: draft.caller, topic: draft.topic, department: draft.department, note: draft.note,
                    length: draft.length, solvedByMe: draft.solvedByMe, at: Date(), context: context)
        try? context.save()
        close()
    }

    private static let positionKey = "callPanelTopLeft"

    private func makePanel() -> CallPanelWindow {
        let panel = CallPanelWindow()
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }

    // MARK: - Settings

    /// Register the shortcut for the current settings and keep it up to date.
    private func applySettings() {
        withObservationTracking {
            if let hotKey {
                let shortcut = preferences.callTrackingEnabled ? preferences.callShortcut : .none
                shortcutUnavailable = !hotKey.register(shortcut)
            }
            if !preferences.callTrackingEnabled { close() }
        } onChange: { [weak self] in
            Task { @MainActor in self?.applySettings() }
        }
    }
}

/// A floating panel that takes typing without bringing Work Tracker to the front, so
/// the call app stays where it was (like Spotlight).
final class CallPanelWindow: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// What the panel collected.
struct CallDraft {
    var caller: String
    var topic: String
    var department: String
    var note: String
    var solvedByMe: Bool
    var length: CallLength
}

/// The panel's form: caller, topic, department, note and who solved it, then one click
/// on the length saves the call.
struct CallPanelView: View {
    @Query private var recentCalls: [PhoneCall]
    @State private var caller = ""
    @State private var topic = ""
    @State private var department = ""
    /// Picked by hand; otherwise it follows the caller.
    @State private var departmentPicked = false
    @State private var note = ""
    @State private var solvedByMe = false
    /// Return in the caller field moves on to the topic, and from there to the note.
    @State private var topicFocusRequest = 0
    @FocusState private var noteFocused: Bool

    let shortcut: CallShortcut
    let departments: [String]
    /// Ends editing in the panel, so text typed and auto-completed is in the form.
    let commitEditing: () -> Void
    let onLog: (CallDraft) -> Void
    let onCancel: () -> Void

    init(shortcut: CallShortcut, departments: [String], commitEditing: @escaping () -> Void,
         onLog: @escaping (CallDraft) -> Void, onCancel: @escaping () -> Void) {
        self.shortcut = shortcut
        self.departments = departments
        self.commitEditing = commitEditing
        self.onLog = onLog
        self.onCancel = onCancel
        _recentCalls = Query(CallSuggestions.source)
    }

    private var hasCaller: Bool { !CallNames.trimmed(caller).isEmpty }

    static let width: CGFloat = 440
    /// The fields' column, so long names can't widen the form.
    private let fieldWidth: CGFloat = 300

    var body: some View {
        let suggestions = CallSuggestions(calls: recentCalls)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(tr("Log a Call"), systemImage: "phone.fill")
                    .font(.headline)
                Spacer()
                if shortcut != .none {
                    Text(shortcut.title)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .help(tr("Opens this panel from any app"))
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(tr("Caller"))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        SuggestionField(text: $caller, suggestions: suggestions.callers,
                                        placeholder: tr("Who called?"), autoFocus: true,
                                        onSubmit: { topicFocusRequest += 1 })
                        nameButtons(suggestions.recentCallers, selection: $caller)
                    }
                    .frame(width: fieldWidth, alignment: .leading)
                }
                GridRow {
                    Text(tr("Topic"))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        SuggestionField(text: $topic, suggestions: suggestions.topicList(for: caller),
                                        placeholder: tr("What about?"), focusRequest: topicFocusRequest,
                                        onSubmit: { noteFocused = true })
                        nameButtons(suggestions.topics(of: caller), selection: $topic)
                    }
                    .frame(width: fieldWidth, alignment: .leading)
                }
                GridRow {
                    Text(tr("Department"))
                        .foregroundStyle(.secondary)
                    departmentPicker
                        .frame(width: fieldWidth, alignment: .leading)
                }
                GridRow {
                    Text(tr("Note"))
                        .foregroundStyle(.secondary)
                    TextField(tr("Note"), text: $note, prompt: Text(tr("Optional")))
                        .labelsHidden()
                        .focused($noteFocused)
                        .frame(width: fieldWidth)
                }
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle(tr("Solved by me"), isOn: $solvedByMe)
                        .help(tr("Tick when you solved the issue; leave it unticked when the caller solved it."))
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text(tr("How long?"))
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(Array(CallLength.allCases.enumerated()), id: \.element) { index, length in
                    Button(length.title) { log(length) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .help(tr("%@ (⌘%lld)", length.detail, index + 1))
                        .disabled(!hasCaller)
                }
            }

            HStack {
                Text(hasCaller ? tr("Clicking the length saves the call.") : tr("Enter who called, then click how long it took."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Two lines either way (the German hint wraps), so the form keeps its height.
                    .lineLimit(2, reservesSpace: true)
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: Self.width)
        .onChange(of: caller) {
            // The department this caller's calls usually concern, until one is picked.
            guard !departmentPicked else { return }
            department = suggestions.department(of: caller, among: departments)
        }
    }

    @ViewBuilder
    private var departmentPicker: some View {
        if departments.isEmpty {
            SettingsLink {
                Text(tr("Add departments in Settings…"))
            }
            .buttonStyle(.link)
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
        } else {
            Picker(tr("Department"), selection: Binding(get: { department }, set: { department = $0; departmentPicked = true })) {
                Text(tr("None")).tag("")
                Divider()
                ForEach(departments, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
    }

    /// One row of one-click names; the one already chosen is highlighted. The row is always
    /// there and never wraps (long names are shortened), so the form keeps its height.
    private func nameButtons(_ names: [String], selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            ForEach(names.prefix(3), id: \.self) { name in
                let isSelected = CallNames.same(name, CallNames.trimmed(selection.wrappedValue))
                Button { selection.wrappedValue = name } label: {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isSelected ? .accentColor : nil)
                .help(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(width: fieldWidth, height: 22, alignment: .leading)
    }

    private func log(_ length: CallLength) {
        commitEditing()
        // Saving on the next turn sees what ending the edit put into the form.
        DispatchQueue.main.async {
            guard hasCaller else { return NSSound.beep() }
            onLog(CallDraft(caller: caller, topic: topic, department: department, note: note, solvedByMe: solvedByMe,
                            length: length))
        }
    }
}
