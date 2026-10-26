import Foundation
import CryptoKit
import SQLite3

/// SQLite's online backup API includes committed WAL transactions in one consistent file.
/// The current schema has no external binary storage.
enum DatabaseBackup {
    /// Snapshots kept per database location (and in the mirror folder).
    static let retention = 30

    static func directory(for store: URL) -> URL {
        let fingerprint = SHA256.hash(data: Data(store.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return StoreLocation.applicationSupport
            .appendingPathComponent("Backups/\(fingerprint)", isDirectory: true)
    }

    static func snapshots(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("backup-") && $0.pathExtension == "store" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WorkTracker.Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Write a consistent, integrity-checked, standalone copy of the SQLite database at
    /// `source` to `destination`, which must not exist yet. Safe while the app has the
    /// source open.
    static func copyDatabase(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw failure(tr("There is no database to copy.")) }
        guard !fm.fileExists(atPath: destination.path) else { throw failure(tr("The destination already exists.")) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let pending = destination.deletingLastPathComponent()
            .appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { removeWithSidecars(pending) }
        var from: OpaquePointer?
        var to: OpaquePointer?
        defer { sqlite3_close(from); sqlite3_close(to) }

        guard sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw failure(tr("Could not open the database for backup."))
        }
        guard sqlite3_open(pending.path, &to) == SQLITE_OK else {
            throw failure(tr("Could not create the backup file."))
        }
        sqlite3_busy_timeout(from, 2000)
        guard let backup = sqlite3_backup_init(to, "main", from, "main") else {
            throw failure(tr("Could not start the database backup."))
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw failure(tr("Database backup could not finish. It will be retried automatically."))
        }
        var check: OpaquePointer?
        defer { sqlite3_finalize(check) }
        guard sqlite3_prepare_v2(to, "PRAGMA integrity_check", -1, &check, nil) == SQLITE_OK,
              sqlite3_step(check) == SQLITE_ROW,
              let value = sqlite3_column_text(check, 0), String(cString: value) == "ok" else {
            throw failure(tr("Backup integrity check failed."))
        }
        sqlite3_finalize(check)
        check = nil
        // The copy inherits WAL mode from the source; switch it back so the snapshot is
        // one self-contained file with no -wal/-shm siblings.
        guard sqlite3_exec(to, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw failure(tr("Could not create the backup file."))
        }
        sqlite3_close(to)
        to = nil
        try fm.moveItem(at: pending, to: destination)
    }

    /// Delete a database file together with any `-wal`/`-shm`/`-journal` siblings.
    static func removeWithSidecars(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// Remove temporary files an interrupted backup left behind (older than an hour).
    static func removeStaleTemporaryFiles(in directory: URL, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix(".pending-") || file.lastPathComponent.hasPrefix(".candidate-") {
            if let date = modificationDate(of: file), now.timeIntervalSince(date) > 3600 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func sha256(of url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    /// Create a snapshot of `store` in `directory` unless one was made in the last 24 hours
    /// (`force` skips that check). If nothing changed since the latest snapshot, that
    /// snapshot is re-dated instead of adding an identical copy, so the retained 30 files
    /// cover as much history as possible. Returns the latest backup date, or nil when
    /// there is no store yet.
    /// One snapshot at a time: the hourly check runs in the background, sync's backups
    /// on the main actor.
    private static let lock = NSLock()

    @discardableResult
    static func create(store: URL, directory: URL, now: Date = Date(), force: Bool = false) throws -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { return nil }
        let existing = try snapshots(in: directory)
        if !force, let latest = existing.first, let modified = modificationDate(of: latest),
           now.timeIntervalSince(modified) < 24 * 60 * 60 {
            return modified
        }
        removeStaleTemporaryFiles(in: directory, now: max(now, Date()))
        let candidate = directory.appendingPathComponent(".candidate-\(UUID().uuidString).store")
        defer { removeWithSidecars(candidate) }
        try copyDatabase(from: store, to: candidate)

        if let latest = existing.first, try sha256(of: latest) == sha256(of: candidate) {
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: latest.path)
            return now
        }
        let final = directory.appendingPathComponent(snapshotName(at: now))
        try fm.moveItem(at: candidate, to: final)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: final.path)
        // Only rotate after publishing a verified snapshot. Other files are never touched.
        try rotate(in: directory)
        return now
    }

    static func snapshotName(at date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return "backup-\(stamp)-\(UUID().uuidString.prefix(8)).store"
    }

    static func rotate(in directory: URL) throws {
        for old in try snapshots(in: directory).dropFirst(retention) {
            try FileManager.default.removeItem(at: old)
        }
    }

    /// Copy the newest snapshot into `mirror` (e.g. a cloud folder) if it isn't there yet,
    /// and apply the same retention there.
    static func mirror(from directory: URL, to mirror: URL) throws {
        guard let latest = try snapshots(in: directory).first else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        let target = mirror.appendingPathComponent(latest.lastPathComponent)
        if fm.fileExists(atPath: target.path) {
            if let date = modificationDate(of: latest) {
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
            }
            return
        }
        let pending = mirror.appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { removeWithSidecars(pending) }
        try fm.copyItem(at: latest, to: pending)
        try fm.moveItem(at: pending, to: target)
        try rotate(in: mirror)
    }
}
