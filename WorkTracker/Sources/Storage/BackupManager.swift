import Foundation
import Observation
import SwiftData

struct BackupSnapshot: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
}

/// Runs the backup schedule for as long as the app is running (with or without a
/// window), mirrors snapshots to an optional second folder, and stages restores.
@MainActor
@Observable
final class BackupManager {
    let storeURL: URL
    let directory: URL
    var lastBackup: Date?
    var errorMessage: String?
    var mirrorErrorMessage: String?
    var isRunning = false
    var snapshots: [BackupSnapshot] = []

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var schedule: Task<Void, Never>?

    init(storeURL: URL) {
        self.storeURL = storeURL
        self.directory = DatabaseBackup.directory(for: storeURL)
        // Take a snapshot before SwiftData opens or migrates an existing store.
        do { lastBackup = try DatabaseBackup.create(store: storeURL, directory: directory) }
        catch { errorMessage = error.localizedDescription }
        refresh()
    }

    /// Start the hourly check. A snapshot is made at most once a day.
    func start(container: ModelContainer) {
        self.container = container
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.run()
                do { try await Task.sleep(for: .seconds(3600)) } catch { break }
            }
        }
    }

    func run(force: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            try container?.mainContext.save()
            let store = storeURL
            let folder = directory
            lastBackup = try await Task.detached(priority: .utility) {
                try DatabaseBackup.create(store: store, directory: folder, force: force)
            }.value
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await mirror()
        refresh()
    }

    /// A backup right now, on the main actor, for sync to make before it replaces or
    /// deletes data: nothing can change between the backup and what sync does next.
    /// Small databases take milliseconds. Returns whether it worked.
    func backUpNow() -> Bool {
        do {
            try container?.mainContext.save()
            lastBackup = try DatabaseBackup.create(store: storeURL, directory: directory, force: true)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        refresh()
        Task { await mirror() }
        return true
    }

    private func mirror() async {
        guard let mirror = Preferences.shared.backupMirrorDirectory else {
            mirrorErrorMessage = nil
            return
        }
        let folder = directory
        do {
            try await Task.detached(priority: .utility) {
                try DatabaseBackup.mirror(from: folder, to: mirror)
            }.value
            mirrorErrorMessage = nil
        } catch {
            mirrorErrorMessage = tr("Could not copy the backup to %@: %@", mirror.path, error.localizedDescription)
        }
    }

    func refresh() {
        let urls = (try? DatabaseBackup.snapshots(in: directory)) ?? []
        snapshots = urls.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return BackupSnapshot(url: url, date: values?.contentModificationDate ?? .distantPast,
                                  size: Int64(values?.fileSize ?? 0))
        }
        .sorted { $0.date > $1.date }
        if lastBackup == nil { lastBackup = snapshots.first?.date }
    }

    /// Replace the database with `snapshot` at the next launch and relaunch now. When
    /// syncing, the other Macs go back to the snapshot too.
    func restore(_ snapshot: BackupSnapshot) {
        try? container?.mainContext.save()
        StoreLocation.stageRestore(of: snapshot.url)
        DeviceSync.prepareForRestore()
        StoreLocation.relaunch()
    }

    /// Set the database aside at the next launch and fill a new one from sync (when the
    /// database can't be opened). Relaunches now.
    func replaceWithSyncedData() {
        StoreLocation.stageReset()
        DeviceSync.prepareForRecovery()
        StoreLocation.relaunch()
    }
}
