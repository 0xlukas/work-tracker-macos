import SwiftUI
import AppKit

/// Shown instead of the app when the database can't be opened. Nothing is deleted or
/// recreated; the user can restore a backup, inspect the files, or quit.
struct RecoveryView: View {
    @Environment(BackupManager.self) private var backups
    let error: String
    @State private var confirmRestore = false
    @State private var confirmSyncedData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(tr("Work Tracker can’t open its database"), systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)

            Text(tr("Your data has not been changed. You can restore the latest backup (the current file is kept), or quit and investigate the files first."))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(error)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .cardSurface()

            if let latest = backups.snapshots.first {
                Text(tr("Latest backup: %@", latest.date.formatted(.app.day().month().year().hour().minute())))
                    .font(.callout)
            } else {
                Text(tr("No backups yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if DeviceSync.isTurnedOn() {
                    // Sync has everything up to the last sync, which is usually newer
                    // than the latest backup.
                    Button(tr("Replace with Synced Data…")) { confirmSyncedData = true }
                        .buttonStyle(.borderedProminent)
                    Button(tr("Restore Latest Backup…")) { confirmRestore = true }
                        .disabled(backups.snapshots.isEmpty)
                } else {
                    Button(tr("Restore Latest Backup…")) { confirmRestore = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(backups.snapshots.isEmpty)
                }
                Button(tr("Show Database in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([backups.storeURL])
                }
                Button(tr("Show Backups")) { NSWorkspace.shared.open(backups.directory) }
                Spacer()
                Button(tr("Quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 380)
        .confirmationDialog(tr("Restore the latest backup?"), isPresented: $confirmRestore) {
            Button(tr("Restore and Restart"), role: .destructive) {
                if let latest = backups.snapshots.first { backups.restore(latest) }
            }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(DeviceSync.isTurnedOn()
                 ? tr("The current database is moved into the Backups folder, not deleted.") + " " + tr("Your other Macs also go back to this backup.")
                 : tr("The current database is moved into the Backups folder, not deleted."))
        }
        .confirmationDialog(tr("Replace the database with the synced data?"), isPresented: $confirmSyncedData) {
            Button(tr("Replace and Restart"), role: .destructive) { backups.replaceWithSyncedData() }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Work Tracker moves the current database into the Backups folder, restarts with an empty one and fills it with the data from sync."))
        }
    }
}
