import Carbon.HIToolbox
import Foundation

/// Keyboard shortcuts that start and end a call from any app.
enum CallShortcut: String, CaseIterable, Identifiable {
    case controlOptionC
    case controlOptionCommandC
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOptionC: return "⌃⌥C"
        case .controlOptionCommandC: return "⌃⌥⌘C"
        case .none: return tr("None")
        }
    }

    fileprivate var keyCode: UInt32 { UInt32(kVK_ANSI_C) }

    fileprivate var modifiers: UInt32? {
        switch self {
        case .controlOptionC: return UInt32(controlKey | optionKey)
        case .controlOptionCommandC: return UInt32(controlKey | optionKey | cmdKey)
        case .none: return nil
        }
    }
}

/// A system-wide keyboard shortcut (Carbon hot key: works while other apps are in front
/// and needs no Accessibility permission).
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Register `shortcut` in place of the current one. Returns false when another app
    /// already uses it.
    @discardableResult
    func register(_ shortcut: CallShortcut) -> Bool {
        unregister()
        guard let modifiers = shortcut.modifiers else { return true }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &type,
                                Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5754_436C), id: 1)  // "WTCl"
        return RegisterEventHotKey(shortcut.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    fileprivate func fire() { action() }
}

/// Carbon delivers hot keys on the main thread.
private let hotKeyPressed: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}
