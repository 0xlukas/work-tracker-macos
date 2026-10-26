import Foundation
import AppKit

/// Which build is running. Only the installed app (bundle ID `com.worktracker.app`) uses
/// the real data and sync folder; test builds (`BUNDLE_ID=… scripts/build-app.sh`),
/// Xcode's Debug configuration and `swift run` each keep their own, so trying something
/// out on a Mac that syncs never touches the real data.
enum AppIdentity {
    static let installedBundleID = "com.worktracker.app"

    static var bundleID: String? { Bundle.main.bundleIdentifier }
    static var isInstalledApp: Bool { bundleID == installedBundleID }

    /// Suffix that sets other builds' folders apart, such as " (com.worktracker.app.test)".
    static var folderSuffix: String { isInstalledApp ? "" : " (\(bundleID ?? "dev"))" }
    static var dataFolderName: String { "WorkTracker" + folderSuffix }
}

/// Where the live database lives, and the file operations around it: moving it to
/// another folder, restoring a snapshot, and relaunching the app afterwards.
///
/// The store is only ever replaced while it is closed: a move copies it with SQLite's
/// backup API and relaunches; a restore is staged and applied at the next launch,
/// before SwiftData opens the file.
enum StoreLocation {
    static let fileName = "WorkTracker.store"
    static let siblingSuffixes = ["", "-wal", "-shm"]

    private static let customDirectoryKey = "customDataDirectory"
    private static let pendingRestoreKey = "pendingRestoreSnapshot"
    private static let pendingResetKey = "pendingStoreReset"
    private static let restoreResultKey = "lastRestoreResult"

    /// The app's folder in Application Support: "WorkTracker" for the installed app, a
    /// folder of their own for test and debug builds (see `AppIdentity`).
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true)
    }

    static var defaultDirectory: URL { applicationSupport }

    /// Custom folder for the database. nil = default (Application Support).
    static var customDirectory: URL? {
        get { UserDefaults.standard.string(forKey: customDirectoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            if let newValue { UserDefaults.standard.set(newValue.path, forKey: customDirectoryKey) }
            else { UserDefaults.standard.removeObject(forKey: customDirectoryKey) }
        }
    }

    static var currentDirectory: URL { customDirectory ?? defaultDirectory }

    static var storeURL: URL {
        try? FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        return currentDirectory.appendingPathComponent(fileName)
    }

    static func storeURL(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    static func hasStore(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: storeURL(in: directory).path)
    }

    /// Folders managed by a sync client. A live SQLite database there can be corrupted:
    /// the client uploads the store and its WAL separately and may create conflict copies.
    static func isCloudSynced(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let markers = ["\(home)/Library/CloudStorage/", "\(home)/Library/Mobile Documents/",
                       "\(home)/Dropbox/", "\(home)/Google Drive/", "\(home)/OneDrive"]
        return markers.contains { path.hasPrefix($0) } || path.contains("/Dropbox/")
    }

    // MARK: - Moving the store

    enum MoveError: LocalizedError {
        case destinationHasStore
        case sameFolder

        var errorDescription: String? {
            switch self {
            case .destinationHasStore: return tr("That folder already contains a Work Tracker database.")
            case .sameFolder: return tr("The database is already in that folder.")
            }
        }
    }

    /// How to treat a database that already exists in the destination folder.
    enum ExistingStorePolicy {
        /// Refuse (throws `destinationHasStore`).
        case refuse
        /// Keep the destination's database and switch to it without copying.
        case useExisting
        /// Move the destination's database aside (into Backups) and copy the current data.
        case replace
    }

    /// Copy the current database into `directory` as a consistent snapshot and make that
    /// folder the store location for the next launch. Nothing is written to the old
    /// location, and nothing in the destination is overwritten unless `.replace`.
    static func moveStore(to directory: URL, existing policy: ExistingStorePolicy = .refuse,
                          from source: URL = storeURL, backupsRoot: URL = applicationSupport) throws {
        let fm = FileManager.default
        let target = directory.standardizedFileURL
        guard source.deletingLastPathComponent().standardizedFileURL != target else { throw MoveError.sameFolder }

        if hasStore(in: target) {
            switch policy {
            case .refuse: throw MoveError.destinationHasStore
            case .useExisting:
                setDirectory(target)
                return
            case .replace:
                try setAside(storeIn: target, label: "replaced", root: backupsRoot)
            }
        } else {
            // A stray WAL/SHM without its store would be applied to the copied database.
            try setAside(storeIn: target, label: "orphaned", root: backupsRoot)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        if fm.fileExists(atPath: source.path) {
            try DatabaseBackup.copyDatabase(from: source, to: storeURL(in: target))
        }
        setDirectory(target)
    }

    private static func setDirectory(_ directory: URL) {
        customDirectory = directory.standardizedFileURL == defaultDirectory.standardizedFileURL ? nil : directory
    }

    /// Move the store and its WAL/SHM siblings in `directory` (whichever exist) into a
    /// timestamped folder under Backups. Returns that folder, or nil when nothing existed.
    @discardableResult
    static func setAside(storeIn directory: URL, label: String, root: URL = applicationSupport) throws -> URL? {
        let fm = FileManager.default
        let files = siblingSuffixes.map { directory.appendingPathComponent(fileName + $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = root.appendingPathComponent("Backups/\(label)-\(stamp)-\(UUID().uuidString.prefix(4))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try fm.moveItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        return folder
    }

    // MARK: - Restoring a snapshot

    /// Schedule `snapshot` to replace the database at the next launch.
    static func stageRestore(of snapshot: URL) {
        UserDefaults.standard.set(snapshot.path, forKey: pendingRestoreKey)
    }

    /// Schedule the database to be moved into Backups at the next launch, so the app
    /// starts with a new, empty one (which sync then fills).
    static func stageReset() {
        UserDefaults.standard.set(true, forKey: pendingResetKey)
    }

    /// Message about a restore performed at this launch, shown once in Settings.
    static func takeRestoreResult() -> String? {
        let message = UserDefaults.standard.string(forKey: restoreResultKey)
        UserDefaults.standard.removeObject(forKey: restoreResultKey)
        return message
    }

    /// Apply a staged restore. Call before anything opens the store. The replaced files
    /// are kept under Backups/replaced-…; if copying fails they are put back.
    static func applyPendingRestore(to store: URL, backupsRoot: URL = applicationSupport) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: pendingResetKey) {
            defaults.removeObject(forKey: pendingResetKey)
            do {
                try setAside(storeIn: store.deletingLastPathComponent(), label: "replaced", root: backupsRoot)
                defaults.set(tr("The database that couldn’t be opened is in the Backups folder. Work Tracker fills the new one from sync."),
                             forKey: restoreResultKey)
            } catch {
                defaults.set(tr("Restore failed: %@", error.localizedDescription), forKey: restoreResultKey)
            }
        }
        guard let path = defaults.string(forKey: pendingRestoreKey) else { return }
        defaults.removeObject(forKey: pendingRestoreKey)
        let snapshot = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let directory = store.deletingLastPathComponent()
        do {
            guard fm.fileExists(atPath: snapshot.path) else {
                throw NSError(domain: "WorkTracker.Restore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: tr("The backup file no longer exists.")])
            }
            let aside = try setAside(storeIn: directory, label: "replaced", root: backupsRoot)
            do {
                try fm.copyItem(at: snapshot, to: store)
            } catch {
                // A failed copy can leave a partial file, which would block moving the
                // original back (and be opened as a corrupt store at launch).
                DatabaseBackup.removeWithSidecars(store)
                if let aside {
                    for suffix in siblingSuffixes {
                        let file = aside.appendingPathComponent(fileName + suffix)
                        if fm.fileExists(atPath: file.path) { try? fm.moveItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent)) }
                    }
                }
                throw error
            }
            let date = DatabaseBackup.modificationDate(of: snapshot)?.formatted(.app.day().month().year().hour().minute()) ?? ""
            defaults.set(tr("Restored the backup from %@.", date), forKey: restoreResultKey)
        } catch {
            defaults.set(tr("Restore failed: %@", error.localizedDescription), forKey: restoreResultKey)
        }
    }

    // MARK: - Relaunch

    /// Quit and start the app again (used after moving or restoring the database).
    @MainActor
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let command: String
        if bundle.pathExtension == "app" {
            command = "/usr/bin/open -n \(shellQuoted(bundle.path))"
        } else if let executable = Bundle.main.executableURL {
            command = "\(shellQuoted(executable.path)) >/dev/null 2>&1 &"
        } else {
            NSApp.terminate(nil)
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; \(command)"]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
