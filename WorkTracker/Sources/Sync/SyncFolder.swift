import Foundation
import IOKit
import SystemConfiguration

/// The folder Macs exchange their ledgers through — "Work Tracker Sync" in iCloud
/// Drive — and the files in it. Each Mac writes only its own file
/// (`device-<id>.json`) and reads the others, so iCloud never sees two Macs writing
/// one file. Reads and writes are coordinated, which also downloads files macOS has
/// offloaded to iCloud ("Optimize Mac Storage"). They block, so call them off the main
/// thread.
enum SyncFolder {
    static let folderName = "Work Tracker Sync"
    private static let prefix = "device-"
    private static let customFolderKey = "syncFolder"

    /// iCloud Drive's folder for the installed app, a separate one for test builds, or
    /// the folder in the `syncFolder` default (used to test syncing on one Mac). Only a
    /// path: touching iCloud Drive can wait for a permission prompt, so nothing here
    /// checks the disk (see `prepare`).
    static func defaultURL(defaults: UserDefaults = .standard) -> URL {
        if let custom = defaults.string(forKey: customFolderKey) {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent(folderName + AppIdentity.folderSuffix, isDirectory: true)
    }

    /// The folder's parent (iCloud Drive) doesn't exist: iCloud Drive is off.
    struct Unavailable: Error {}

    /// Create the folder if needed. Throws `Unavailable` rather than creating a local
    /// stand-in for iCloud Drive.
    static func prepare(_ folder: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        guard fm.fileExists(atPath: folder.deletingLastPathComponent().path) else { throw Unavailable() }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    /// macOS refused access to the folder (the iCloud Drive permission was declined).
    static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
            if error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func fileURL(device: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(prefix)\(device).json")
    }

    /// Another Mac's file as last read.
    struct RemoteFile: Sendable {
        enum Content: Sendable {
            case snapshot(DeviceSnapshot)
            /// Written by a newer version of the app, in a format this one can't read.
            case newerFormat
            case unreadable(String)
        }

        var modified: Date?
        var size: Int?
        var content: Content

        var snapshot: DeviceSnapshot? {
            if case .snapshot(let snapshot) = content { return snapshot }
            return nil
        }

        var isUnreadable: Bool {
            if case .unreadable = content { return true }
            return false
        }
    }

    struct Listing: Sendable {
        var others: [URL: RemoteFile]
        var ownFileExists: Bool
    }

    /// The other Macs' files. Files whose date and size match `cache` are not read again.
    static func read(_ folder: URL, ownDevice: String, cache: [URL: RemoteFile]) throws -> Listing {
        let own = fileURL(device: ownDevice, in: folder).lastPathComponent
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        var listing = Listing(others: [:], ownFileExists: false)
        for url in urls where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            if url.lastPathComponent == own {
                listing.ownFileExists = true
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate, size = values?.fileSize
            // Files that couldn't be read are tried again every time.
            if let cached = cache[url], cached.modified == modified, cached.size == size, !cached.isUnreadable {
                listing.others[url] = cached
                continue
            }
            listing.others[url] = RemoteFile(modified: modified, size: size, content: decode(readCoordinated(url)))
        }
        return listing
    }

    /// Whether any other Mac's file changed since `cache` was made (date and size only).
    static func hasChanges(_ folder: URL, ownDevice: String, cache: [URL: RemoteFile]) -> Bool {
        guard let listing = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: []) else { return false }
        let own = fileURL(device: ownDevice, in: folder).lastPathComponent
        let files = listing.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" && $0.lastPathComponent != own }
        guard Set(files) == Set(cache.keys) else { return true }
        if cache.values.contains(where: \.isUnreadable) { return true }
        return files.contains { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return values?.contentModificationDate != cache[url]?.modified || values?.fileSize != cache[url]?.size
        }
    }

    private static func decode(_ result: Result<Data, Error>) -> RemoteFile.Content {
        switch result {
        case .failure(let error):
            return .unreadable(error.localizedDescription)
        case .success(let data):
            do {
                let header = try JSONDecoder().decode(DeviceSnapshot.Header.self, from: data)
                guard header.format <= DeviceSnapshot.currentFormat else { return .newerFormat }
                return .snapshot(try JSONDecoder().decode(DeviceSnapshot.self, from: data))
            } catch {
                return .unreadable(error.localizedDescription)
            }
        }
    }

    static func readCoordinated(_ url: URL) -> Result<Data, Error> {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { return .failure(coordinationError) }
        return result
    }

    /// Replace `url` with `data` in one step, so readers never see half a file.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    static func remove(_ url: URL) throws {
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { removeError = error }
        }
        if let error = coordinationError ?? removeError { throw error }
    }
}

/// This Mac as other Macs see it.
enum SyncDevice {
    private static let idKey = "syncDeviceID"
    private static let hardwareKey = "syncDeviceHardware"

    /// A random ID kept in this build's preferences. A new one is made when the
    /// preferences move to another Mac (Migration Assistant), so two Macs never share one.
    static func current(defaults: UserDefaults = .standard) -> DeviceSnapshot.Device {
        let hardware = hardwareUUID()
        var id = defaults.string(forKey: idKey)
        if id == nil || defaults.string(forKey: hardwareKey) != hardware {
            id = UUID().uuidString
            defaults.set(id, forKey: idKey)
            defaults.set(hardware, forKey: hardwareKey)
        }
        return DeviceSnapshot.Device(id: id!, name: computerName, appVersion: appVersion)
    }

    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
