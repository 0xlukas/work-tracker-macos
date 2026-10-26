import SwiftUI
import AppKit
import SwiftData

/// Keeps the app running when the main window closes: the menu bar item (today's hours,
/// the timer) and the hourly backup schedule live on without a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignal: DispatchSourceSignal?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Installers send SIGTERM before replacing the app: quit as with ⌘Q, so pending
    /// changes are saved, instead of dying on the spot.
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source
    }
}

@main
struct WorkTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var backups: BackupManager
    @State private var calendarSync: CalendarSync
    @State private var deviceSync: DeviceSync
    @State private var assistantServer: AssistantServer
    @State private var preferences = Preferences.shared
    @State private var timer = WorkTimer.shared
    private let container: ModelContainer?
    private let openError: String?

    init() {
        let storeURL = StoreLocation.storeURL
        // A restore chosen in Settings is applied here, before anything opens the store.
        StoreLocation.applyPendingRestore(to: storeURL)
        let backups = BackupManager(storeURL: storeURL)
        _backups = State(initialValue: backups)
        let calendarSync = CalendarSync()
        _calendarSync = State(initialValue: calendarSync)
        let deviceSync = DeviceSync()
        _deviceSync = State(initialValue: deviceSync)
        let assistantServer = AssistantServer()
        _assistantServer = State(initialValue: assistantServer)
        do {
            let container = try ModelContainer.workTracker(url: storeURL)
            if (try? VacationDay.removeDuplicates(in: container.mainContext)) ?? 0 > 0 {
                try? container.mainContext.save()
            }
            self.container = container
            IntentStore.container = container
            self.openError = nil
            backups.start(container: container)
            calendarSync.start(container: container)
            deviceSync.start(container: container, storeURL: storeURL, backupFolder: backups.directory) {
                backups.backUpNow()
            }
            assistantServer.start(handler: MCPHandler(tools: AssistantTools(
                context: container.mainContext, preferences: .shared, timer: .shared, deviceSync: deviceSync)))
        } catch {
            // Never wipe or recreate the store; offer recovery instead.
            self.container = nil
            self.openError = String(describing: error)
        }
    }

    var body: some Scene {
        Window("Work Tracker", id: "main") {
            Group {
                if let container {
                    ContentView()
                        .modelContainer(container)
                } else {
                    RecoveryView(error: openError ?? "")
                }
            }
            .appEnvironment(preferences: preferences, backups: backups, timer: timer, calendarSync: calendarSync, deviceSync: deviceSync,
                            assistantServer: assistantServer)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentSize)
        .commands {
            // Remove the default "New Window" Cmd+N
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            Group {
                if let container {
                    SettingsView()
                        .modelContainer(container)
                } else {
                    RecoveryView(error: openError ?? "")
                }
            }
            .appEnvironment(preferences: preferences, backups: backups, timer: timer, calendarSync: calendarSync, deviceSync: deviceSync,
                            assistantServer: assistantServer)
        }

        MenuBarExtra(isInserted: .constant(container != nil)) {
            if let container {
                MenuBarContent()
                    .modelContainer(container)
                    .appEnvironment(preferences: preferences, backups: backups, timer: timer, calendarSync: calendarSync, deviceSync: deviceSync,
                                    assistantServer: assistantServer)
            }
        } label: {
            MenuBarLabel()
                .environment(timer)
        }
        .menuBarExtraStyle(.window)
    }
}

extension View {
    /// Shared app state plus the UI language, Zurich time zone and calendar, so dates,
    /// times and pickers look the same on every screen and in every window.
    func appEnvironment(preferences: Preferences, backups: BackupManager, timer: WorkTimer,
                        calendarSync: CalendarSync, deviceSync: DeviceSync,
                        assistantServer: AssistantServer) -> some View {
        var calendar = Calendar.zurich
        calendar.locale = Localization.locale
        return self
            .environment(preferences)
            .environment(backups)
            .environment(timer)
            .environment(calendarSync)
            .environment(deviceSync)
            .environment(assistantServer)
            .environment(\.locale, Localization.locale)
            .environment(\.timeZone, .zurich)
            .environment(\.calendar, calendar)
            // Re-reads on change so switching language rebuilds the UI.
            .id(preferences.language)
    }
}
