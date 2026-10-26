import AppKit
import Observation
import SwiftData

/// Syncs the data between the user's Macs through iCloud Drive. The database stays on
/// each Mac; a sync compares it with this Mac's ledger (`SyncState`), merges the ledgers
/// the other Macs published (`SyncMerge`), writes the result into the database and
/// publishes this Mac's ledger (`SyncFolder`).
///
/// Syncs run after launch, shortly after every save or change to a synced preference,
/// when the app becomes active, when another Mac's file changes, and every ten minutes.
/// Quitting publishes pending changes. Whenever a sync would remove many items, or the
/// database file was swapped, it waits for the user (`question`) and checks the answer
/// against the situation again before acting on it.
@MainActor
@Observable
final class DeviceSync {
    /// What to do with this Mac's data when it joins Macs that already sync.
    enum JoinDecision {
        /// Add this Mac's items to theirs; preferences come from the other Macs.
        case combine
        /// Replace this Mac's data with theirs.
        case useOtherMacs
        /// Replace the other Macs' data with this Mac's.
        case useThisMac
    }

    /// Sync waits for the user: going ahead would remove data here or on the other Macs.
    enum Question: Equatable {
        /// `count` items that were there at the last sync are gone from this Mac.
        case missingItems(count: Int)
        /// This Mac's database file was swapped (another folder's database chosen in
        /// Settings ▸ Storage, or restored outside the app), and `changes` items differ
        /// from the last sync.
        case otherDatabase(changes: Int)
        /// `mac` deleted `count` items, which syncing would delete here too.
        case deletedElsewhere(mac: String, count: Int)

        enum Kind { case missingItems, otherDatabase, deletedElsewhere }

        var kind: Kind {
            switch self {
            case .missingItems: return .missingItems
            case .otherDatabase: return .otherDatabase
            case .deletedElsewhere: return .deletedElsewhere
            }
        }

        /// Whether `answer` is one of this question's answers.
        func accepts(_ answer: Answer) -> Bool {
            switch (self, answer) {
            case (.missingItems, .restoreMissing), (.missingItems, .deleteEverywhere),
                 (.otherDatabase, .useSyncedData), (.otherDatabase, .useThisDatabase),
                 (.deletedElsewhere, .deleteHereToo), (.deletedElsewhere, .keepThem):
                return true
            default:
                return false
            }
        }

        /// An answer given to `self` still holds for `other`: the same situation, no
        /// worse than when the user decided.
        func covers(_ other: Question) -> Bool {
            switch (self, other) {
            case (.missingItems(let a), .missingItems(let b)): return b <= a
            case (.otherDatabase(let a), .otherDatabase(let b)): return b <= a
            case (.deletedElsewhere(let macA, let a), .deletedElsewhere(let macB, let b)): return macA == macB && b <= a
            default: return false
            }
        }
    }

    enum Answer {
        /// Missing items: put them back from sync.
        case restoreMissing
        /// Missing items: delete them on all Macs.
        case deleteEverywhere
        /// Swapped database: replace it with the synced data (after a backup).
        case useSyncedData
        /// Swapped database: send its data to all Macs.
        case useThisDatabase
        /// Deleted on another Mac: delete them here too (after a backup).
        case deleteHereToo
        /// Deleted on another Mac: keep them, and bring them back on all Macs.
        case keepThem
    }

    struct OtherMac: Identifiable, Equatable {
        enum Status: Equatable {
            case inSync
            /// Uses a newer file format: this Mac needs the update.
            case newerFormat
            case unreadable(String)
        }

        let id: URL
        let name: String
        let updated: Date?
        let appVersion: String?
        let status: Status
    }

    /// Turning sync on found other Macs while this Mac has data of its own.
    struct JoinRequest: Identifiable {
        let id = UUID()
        let otherMacs: [String]
        /// Items (not preferences) on this Mac and in the other Macs' data.
        let localItems: Int
        let otherItems: Int
    }

    private(set) var isEnabled: Bool
    private(set) var isSyncing = false
    /// Turning on is under way (reading the other Macs' data can wait for a permission
    /// prompt).
    private(set) var isTurningOn = false
    private(set) var lastSync: Date?
    private(set) var errorMessage: String?
    /// Something worth telling once, such as preferences having come from another Mac.
    var notice: String?
    private(set) var otherMacs: [OtherMac] = []
    private(set) var question: Question?
    var joinRequest: JoinRequest?
    /// Turned on with no data while no other Mac had synced: waiting to join one.
    private(set) var isWaiting = false

    let folder: URL
    @ObservationIgnored private let ledgerURL: URL
    @ObservationIgnored private let device: DeviceSnapshot.Device
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let timer: WorkTimer
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var container: ModelContainer?
    /// The database file, to notice when it's swapped for another one.
    @ObservationIgnored private var storeURL: URL?
    /// Makes a backup right away, on the main actor, so nothing changes between the
    /// backup and what sync does next. Returns whether it worked.
    @ObservationIgnored private var backup: () -> Bool = { true }
    /// Where this Mac's preferences are kept before another Mac's replace them (database
    /// backups don't contain preferences).
    @ObservationIgnored private var backupFolder: URL?
    /// Macs whose data this Mac has merged; meeting a new one can bring other preferences.
    @ObservationIgnored private var knownDevices: Set<String> = []
    @ObservationIgnored private var state: SyncState?
    /// Which database file the ledger was last in step with (path and file number).
    @ObservationIgnored private var ledgerStore: String?
    @ObservationIgnored private var savedLedger: Ledger?
    @ObservationIgnored private var publishedState: SyncState?
    @ObservationIgnored private var ownFileExists = false
    @ObservationIgnored private var cache: [URL: SyncFolder.RemoteFile] = [:]
    /// The user's answers, one per kind of question (a sync can meet several).
    @ObservationIgnored private var approvals: [Question.Kind: (question: Question, answer: Answer)] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var turnOffWhenDone = false
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var isOpeningWatcher = false
    @ObservationIgnored private var poller: Task<Void, Never>?

    /// How syncs treat this Mac's database until one completes. Kept in the defaults, so
    /// it survives a sync that fails or a quit before it.
    private enum Mode: String {
        /// Deletions go to all Macs, unless many items are missing (`question`).
        case normal
        /// Everything goes to all Macs without asking: after restoring a backup.
        case allowDeletions
        /// Missing items come back from the ledger: after replacing a database that
        /// couldn't be opened.
        case keepMissing
    }

    /// Deleting at least this many items, and at least a fifth of all, needs a decision.
    static let deletionThreshold = 10
    static let enabledKey = "deviceSyncEnabled"
    private static let modeKey = "deviceSyncMode"

    private var mode: Mode {
        get { defaults.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .normal }
        set { defaults.set(newValue == .normal ? nil : newValue.rawValue, forKey: Self.modeKey) }
    }

    /// The ledger file: this Mac's snapshot, the database it belongs to, and whether this
    /// Mac still waits for another Mac's data.
    private struct Ledger: Codable, Equatable {
        var snapshot: DeviceSnapshot
        var store: String?
        var waiting = false
        var devices: Set<String> = []

        init(snapshot: DeviceSnapshot, store: String?, waiting: Bool, devices: Set<String>) {
            self.snapshot = snapshot
            self.store = store
            self.waiting = waiting
            self.devices = devices
        }

        // Fields added later fall back to their defaults, so older ledgers still load.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            snapshot = try container.decode(DeviceSnapshot.self, forKey: .snapshot)
            store = try container.decodeIfPresent(String.self, forKey: .store)
            waiting = try container.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
            devices = try container.decodeIfPresent(Set<String>.self, forKey: .devices) ?? []
        }
    }

    init(folder: URL = SyncFolder.defaultURL(),
         ledger: URL = StoreLocation.applicationSupport.appendingPathComponent("Sync/ledger.json"),
         device: DeviceSnapshot.Device = SyncDevice.current(),
         defaults: UserDefaults = .standard, preferences: Preferences = .shared, timer: WorkTimer = .shared,
         now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.ledgerURL = ledger
        self.device = device
        self.defaults = defaults
        self.preferences = preferences
        self.timer = timer
        self.now = now
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let data = try? Data(contentsOf: ledger), let file = try? JSONDecoder().decode(Ledger.self, from: data) {
            state = file.snapshot.state
            ledgerStore = file.store
            isWaiting = file.waiting
            knownDevices = file.devices
            savedLedger = file
        }
        if isEnabled && state == nil {
            // Without its ledger this Mac can't tell its own changes from the others'.
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            notice = tr("Sync was turned off because its records on this Mac are missing. Turn it on again to continue.")
        }
    }

    // MARK: - Running

    /// Sync `container` (stored at `storeURL`), and from now on sync automatically.
    /// `backup` makes a backup of the database right away and returns whether it worked;
    /// it runs before sync replaces or deletes many items. Preferences replaced by
    /// another Mac's are saved in `backupFolder`.
    func start(container: ModelContainer, storeURL: URL?, backupFolder: URL?, backup: @escaping () -> Bool) {
        connect(container: container, storeURL: storeURL, backupFolder: backupFolder, backup: backup)
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isApplying else { return }
                    self.scheduleSync()
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSync(after: .zero) }
            },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            },
        ]
        observeSettings()
        if isEnabled { activate() }
    }

    /// Use `container` without syncing automatically (tests call `sync()` themselves).
    func connect(container: ModelContainer, storeURL: URL? = nil, backupFolder: URL? = nil,
                 backup: @escaping () -> Bool) {
        self.container = container
        self.storeURL = storeURL
        self.backupFolder = backupFolder
        self.backup = backup
    }

    /// Sync once a burst of changes has settled.
    func scheduleSync(after delay: Duration = .seconds(2)) {
        guard isEnabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.sync()
        }
    }

    /// Also runs while a question waits: it checks the situation again, and the
    /// question goes away when it no longer applies.
    func sync() async {
        guard isEnabled else { return }
        await exclusively {
            let others = try await self.readFolder()
            if try self.cycle(others) { try await self.publish() }
        }
        // The watcher couldn't be set up before access to the folder was allowed.
        if isEnabled && !observers.isEmpty { watchFolder() }
    }

    // MARK: - Settings

    /// The Settings toggle: on while syncing, and while turning on waits for a decision.
    var isTurnedOnInSettings: Bool {
        get { isEnabled || joinRequest != nil || isTurningOn }
        set {
            if newValue { Task { await turnOn() } } else { turnOff() }
        }
    }

    /// Whether Settings asks which data to keep; dismissing it without a choice cancels.
    var isAskingToJoin: Bool {
        get { joinRequest != nil }
        set { if !newValue && joinRequest != nil { turnOff() } }
    }

    // MARK: - Turning sync on and off

    /// A Mac with data joining others asks what to do with its data (`joinRequest`); an
    /// empty one takes theirs. The first Mac with data publishes it. An empty Mac that
    /// finds no other Mac waits to join one, so it can never override anything.
    func turnOn() async {
        guard !isEnabled, !isTurningOn else { return }
        notice = nil
        isTurningOn = true
        defer { isTurningOn = false }
        await exclusively {
            let others = try await self.readFolder()
            let context = try self.context()
            let local = try self.exportLocal(context)
            let localItems = local.values.count { $0.kind != .setting }
            if !others.isEmpty {
                if localItems > 0 {
                    var theirs = SyncState()
                    for other in others { SyncMerge.merge(other.records, into: &theirs) }
                    self.joinRequest = JoinRequest(otherMacs: others.map(\.device.name).sorted(),
                                                   localItems: localItems, otherItems: theirs.liveItemCount)
                    return
                }
                try self.join(.combine, others: others, local: local, context: context)
            } else if localItems > 0 {
                // A Mac whose file can't be read right now may hold the data.
                try self.checkOthersAreReadable()
                try self.startWithThisMac(local: local)
            } else {
                try self.save(SyncState(), waiting: true)
            }
            self.enable()
            try await self.publish()
        }
    }

    /// Answer to `joinRequest`. Data that's replaced is backed up first.
    func join(_ decision: JoinDecision) async {
        joinRequest = nil
        isTurningOn = true
        defer { isTurningOn = false }
        await exclusively {
            let others = try await self.readFolder()
            let context = try self.context()
            let local = try self.exportLocal(context)
            if !others.isEmpty {
                try self.join(decision, others: others, local: local, context: context)
            } else if decision == .useOtherMacs {
                // Never replace this Mac's data with nothing.
                throw SyncError(tr("The other Macs’ data is no longer in the sync folder, so nothing was replaced."))
            } else {
                try self.checkOthersAreReadable()
                try self.startWithThisMac(local: local)
            }
            self.enable()
            try await self.publish()
        }
    }

    /// While waiting: stop waiting and sync this Mac's data as the first Mac.
    func startWithThisMacsData() async {
        guard isWaiting else { return }
        await exclusively {
            let others = try await self.readFolder()
            let context = try self.context()
            let local = try self.exportLocal(context)
            if others.isEmpty {
                // Without items, its preferences would be all it brings, likely defaults.
                guard local.values.contains(where: { $0.kind != .setting }) else {
                    throw SyncError(tr("This Mac has no data to start with yet. Add some, or turn on sync on the Mac that has your data."))
                }
                try self.checkOthersAreReadable()
                try self.startWithThisMac(local: local)
            } else {
                // Another Mac's data arrived meanwhile: join it rather than compete.
                try self.join(.combine, others: others, local: local, context: context)
            }
            try await self.publish()
        }
    }

    /// Stop syncing this Mac and remove its file from the sync folder. Its data stays.
    func turnOff() {
        guard isEnabled || joinRequest != nil || isTurningOn else { return }
        joinRequest = nil
        isTurningOn = false
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        deactivate()
        // A sync or setup step still running would write the ledger and this Mac's file
        // again; clean up once it's done.
        if isSyncing {
            turnOffWhenDone = true
            return
        }
        forget()
    }

    private func forget() {
        state = nil
        savedLedger = nil
        publishedState = nil
        ledgerStore = nil
        isWaiting = false
        try? FileManager.default.removeItem(at: ledgerURL)
        otherMacs = []
        cache = [:]
        lastSync = nil
        question = nil
        approvals = [:]
        knownDevices = []
        errorMessage = nil
        mode = .normal
        let url = SyncFolder.fileURL(device: device.id, in: folder)
        Task.detached(priority: .utility) { try? SyncFolder.remove(url) }
    }

    /// Answer to `question` (the one the user saw). The next sync acts on it if the
    /// situation is still the same (or smaller); otherwise it asks again.
    func answer(_ answer: Answer, to question: Question) async {
        guard question.accepts(answer) else { return }
        approvals[question.kind] = (question, answer)
        if self.question == question { self.question = nil }
        await sync()
    }

    /// Restoring a backup: after the restart, this Mac's data goes to the other Macs as it
    /// is, deletions included.
    static func prepareForRestore(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: enabledKey) else { return }
        defaults.set(Mode.allowDeletions.rawValue, forKey: modeKey)
    }

    /// Replacing a database that couldn't be opened: after the restart, everything is
    /// put back from sync.
    static func prepareForRecovery(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: enabledKey) else { return }
        defaults.set(Mode.keepMissing.rawValue, forKey: modeKey)
    }

    static func isTurnedOn(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    // MARK: - The sync itself

    private func context() throws -> ModelContext {
        guard let container else { throw SyncError(tr("Work Tracker can’t open its database.")) }
        return container.mainContext
    }

    /// One sync or setup step at a time; a sync asked for meanwhile runs afterwards.
    private func exclusively(_ work: @escaping () async throws -> Void) async {
        guard !isSyncing else {
            rerun = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if turnOffWhenDone {
                turnOffWhenDone = false
                isEnabled = false
                defaults.set(false, forKey: Self.enabledKey)
                deactivate()
                forget()
            } else if rerun {
                rerun = false
                scheduleSync(after: .zero)
            }
        }
        do {
            try await work()
            if isEnabled && question == nil { lastSync = now() }
            errorMessage = nil
        } catch {
            errorMessage = tr("Could not sync: %@", error.localizedDescription)
        }
    }

    /// The decision for `detected`: the user's answer when it still covers the
    /// situation, else nil, and the question is (asked again).
    private func decision(for detected: Question) -> Answer? {
        if let approval = approvals[detected.kind], approval.question.covers(detected) { return approval.answer }
        approvals[detected.kind] = nil
        question = detected
        return nil
    }

    /// One sync: everything from reading the database to writing it happens without
    /// suspending, so nothing the user does meanwhile is overwritten. Returns whether
    /// there's something to publish.
    private func cycle(_ others: [DeviceSnapshot]) throws -> Bool {
        guard var state else { return false }
        if isWaiting {
            // The first data from another Mac: join it, adding what was entered here.
            guard !others.isEmpty else { return false }
            let context = try context()
            try join(.combine, others: others, local: exportLocal(context), context: context)
            return true
        }

        let context = try context()
        let local = try exportLocal(context)
        let foreign = SyncDatabase.foreignRecords(in: state)
        var keepMissing = mode == .keepMissing
        var deletionsApproved = mode != .normal

        // An answer only stands while its situation does: a check that ran without
        // finding it drops the answer (checks this sync didn't reach keep theirs).
        var checked: Set<Question.Kind> = [], situations: Set<Question.Kind> = []
        defer { approvals = approvals.filter { !checked.contains($0.key) || situations.contains($0.key) } }

        if mode == .normal {
            // The database file was swapped for another one: its differences are no edits.
            checked.insert(.otherDatabase)
            if let identity = currentStore(), let known = ledgerStore, identity != known {
                let differences = SyncMerge.differences(local, from: state, ignoring: foreign)
                if differences > 0 {
                    situations.insert(.otherDatabase)
                    switch decision(for: .otherDatabase(changes: differences)) {
                    case .useSyncedData?:
                        try replace(local, with: state, in: context, foreign: foreign)
                        try finish(state)
                        return true
                    case .useThisDatabase?:
                        deletionsApproved = true
                    default:
                        return false
                    }
                }
            }
            let missing = SyncMerge.pendingDeletions(local, in: state, ignoring: foreign).count { state.records[$0]?.kind != .setting }
            checked.insert(.missingItems)
            if !deletionsApproved, missing >= Self.deletionThreshold, missing * 5 >= state.liveItemCount {
                situations.insert(.missingItems)
                switch decision(for: .missingItems(count: missing)) {
                case .restoreMissing?: keepMissing = true
                case .deleteEverywhere?: break
                default: return false
                }
            }
        }

        let at = now()
        SyncMerge.absorb(local, into: &state, device: device.id, now: at, deletions: !keepMissing, ignoring: foreign)
        if mode == .allowDeletions {
            // The restored data is this Mac's from now on, even if what follows waits for
            // an answer: later deletions are asked about again.
            try save(state, waiting: false)
            mode = .normal
        }
        for other in others {
            SyncMerge.merge(other.records, into: &state)
        }
        let pinned = timerProject(in: context)
        var resolution = SyncMerge.resolve(&state, device: device.id, now: at, pinned: pinned)
        var changes = SyncMerge.changes(from: local, to: state, ignoring: SyncDatabase.foreignRecords(in: state))

        // Many items deleted on another Mac (or this Mac's data replaced there). Only the
        // duplicates this sync merged don't count.
        let deletions = changes.deletions.filter { $0.kind != .setting && !resolution.removed.contains($0.id) }
        let localItems = local.values.count { $0.kind != .setting }
        checked.insert(.deletedElsewhere)
        if deletions.count >= Self.deletionThreshold, deletions.count * 5 >= localItems {
            situations.insert(.deletedElsewhere)
            switch decision(for: .deletedElsewhere(mac: deleter(of: deletions.map(\.id), in: state, others: others),
                                                   count: deletions.count)) {
            case .deleteHereToo?:
                break
            case .keepThem?:
                // Bring them back everywhere: this Mac's copies become the newest.
                for deletion in deletions {
                    if let payload = local[deletion.id] {
                        state.records[deletion.id] = SyncRecord(id: deletion.id, version: state.tick(device: device.id, now: at),
                                                                payload: payload, isDeleted: false)
                    }
                }
                resolution = SyncMerge.resolve(&state, device: device.id, now: at, pinned: pinned)
                changes = SyncMerge.changes(from: local, to: state, ignoring: SyncDatabase.foreignRecords(in: state))
            default:
                return false
            }
        }
        if changes.deletedItemCount >= Self.deletionThreshold {
            guard backup() else {
                throw SyncError(tr("Work Tracker couldn’t back up this Mac’s data, so it didn’t delete anything. It tries again at the next sync."))
            }
        }
        let newMacs = Set(others.map(\.device.id)).subtracting(knownDevices)
        if try keepSettings(local, replacedBy: changes), !newMacs.isEmpty {
            notice = tr("This Mac now uses the schedule, vacation and balance settings of your other Macs. Its previous settings are saved in the Backups folder.")
        }
        try write(changes, merged: resolution.merged, to: context)
        try finish(state, others: others)
        return true
    }

    /// A sync went through: save the ledger and forget what it was waiting for.
    private func finish(_ state: SyncState, others: [DeviceSnapshot] = []) throws {
        knownDevices.formUnion(others.map(\.device.id))
        try save(state, waiting: false)
        mode = .normal
        approvals = [:]
        question = nil
    }

    /// Make this Mac's database match the ledger exactly (after a backup): the synced
    /// data for a swapped database.
    private func replace(_ local: [String: SyncPayload], with state: SyncState, in context: ModelContext,
                         foreign: Set<String>) throws {
        guard backup() else {
            throw SyncError(tr("This Mac’s data could not be backed up, so it was not replaced."))
        }
        var changes = SyncMerge.changes(from: local, to: state, replacing: true, ignoring: foreign)
        let pinned = timerProject(in: context)
        changes.deletions.removeAll { pinned.contains($0.id) }
        try keepSettings(local, replacedBy: changes)
        try write(changes, merged: [:], to: context)
    }

    /// Join Macs that already sync (`others`), doing `decision` with this Mac's data.
    private func join(_ decision: JoinDecision, others: [DeviceSnapshot], local: [String: SyncPayload],
                      context: ModelContext) throws {
        var state = SyncState()
        for other in others {
            SyncMerge.merge(other.records, into: &state)
        }
        let at = now()
        let pinned = timerProject(in: context)
        switch decision {
        case .combine:
            // The synced data wins wherever it knows a record, deletions and newer edits
            // included; this Mac adds only what it doesn't know. Preferences come from
            // the Macs that already sync.
            let unknown = local.filter { $0.value.kind != .setting && state.records[$0.key] == nil }
            SyncMerge.absorb(unknown, into: &state, device: device.id, now: at, deletions: false)
        case .useOtherMacs:
            break
        case .useThisMac:
            // Everything the other Macs have and this one doesn't is deleted there; they
            // ask first when that's a lot.
            SyncMerge.absorb(local, into: &state, device: device.id, now: at)
        }
        let resolution = SyncMerge.resolve(&state, device: device.id, now: at, pinned: pinned)
        var changes = SyncMerge.changes(from: local, to: state, replacing: decision == .useOtherMacs,
                                        ignoring: SyncDatabase.foreignRecords(in: state))
        changes.deletions.removeAll { pinned.contains($0.id) }
        // Back up whenever this Mac's own items change or go.
        let touchesItems = changes.deletedItemCount > 0
            || changes.upserts.contains { $0.kind != .setting && local[$0.id] != nil }
        if touchesItems {
            guard backup() else {
                throw SyncError(tr("This Mac’s data could not be backed up, so it was not replaced."))
            }
        }
        if try keepSettings(local, replacedBy: changes) {
            notice = tr("This Mac now uses the schedule, vacation and balance settings of your other Macs. Its previous settings are saved in the Backups folder.")
        }
        try write(changes, merged: resolution.merged, to: context)
        try finish(state, others: others)
    }

    /// The first Mac: its data becomes the synced data.
    private func startWithThisMac(local: [String: SyncPayload]) throws {
        var state = self.state ?? SyncState()
        state.records = [:]
        SyncMerge.absorb(local, into: &state, device: device.id, now: now())
        try finish(state, others: [])
    }

    /// Before sync changes this Mac's preferences, keep their current values next to the
    /// backups (database backups don't contain preferences); the newest 30 stay. Returns
    /// whether any changed. Throws, stopping the sync, when they can't be kept.
    @discardableResult
    private func keepSettings(_ local: [String: SyncPayload], replacedBy changes: SyncMerge.Changes) throws -> Bool {
        var values: [String: SettingValue] = [:]
        for record in changes.upserts where record.kind == .setting {
            if case .setting(let value)? = local[record.id], local[record.id] != record.payload { values[record.id] = value }
        }
        guard !values.isEmpty else { return false }
        guard let backupFolder else { return true }
        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        let prefix = "settings-before-sync-"
        do {
            try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            let file = backupFolder.appendingPathComponent("\(prefix)\(stamp)-\(UUID().uuidString.prefix(4)).json")
            try DeviceSnapshot.encoder().encode(values).write(to: file, options: .atomic)
            let kept = try FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in kept.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
        } catch {
            throw SyncError(tr("This Mac’s settings couldn’t be saved before replacing them, so nothing was changed: %@",
                               error.localizedDescription))
        }
        return true
    }

    /// The Mac that deleted most of `ids`, by name (this Mac's own name for deletions it
    /// made earlier and gets back, as after restoring its data outside the app).
    private func deleter(of ids: [String], in state: SyncState, others: [DeviceSnapshot]) -> String {
        var names = Dictionary(others.map { ($0.device.id, $0.device.name) }, uniquingKeysWith: { first, _ in first })
        names[device.id] = device.name
        let devices = ids.compactMap { state.records[$0]?.version.device }
        let top = Dictionary(grouping: devices, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        return top.flatMap { names[$0] } ?? tr("Another Mac")
    }

    /// Refuse to go first while another Mac's file can't be read: it may hold the data.
    private func checkOthersAreReadable() throws {
        for file in cache.values {
            switch file.content {
            case .snapshot:
                continue
            case .newerFormat:
                throw SyncError(tr("Another Mac syncs with a newer version of Work Tracker. Update this Mac first."))
            case .unreadable(let message):
                throw SyncError(tr("Another Mac’s sync file can’t be read yet (%@). Try again in a moment; if it keeps failing, remove that file from the sync folder.", message))
            }
        }
    }

    private func exportLocal(_ context: ModelContext) throws -> [String: SyncPayload] {
        try context.save()
        if try SyncDatabase.assignMissingIDs(in: context) { try context.save() }
        return try SyncDatabase.export(context: context, preferences: preferences)
    }

    /// Write changes into the database. They aren't undoable: undoing them would only
    /// make this Mac differ from the others.
    private func write(_ changes: SyncMerge.Changes, merged: [String: String], to context: ModelContext) throws {
        guard !changes.isEmpty else { return }
        let timerProject = timer.isRunning ? timer.project(in: context) : nil
        let timerProjectID = timerProject?.syncID?.uuidString, timerProjectName = timerProject?.name
        isApplying = true
        defer { isApplying = false }
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        do {
            try SyncDatabase.apply(changes, to: context, preferences: preferences)
            try context.save()
        } catch {
            context.rollback()
            undoManager?.enableUndoRegistration()
            throw error
        }
        undoManager?.enableUndoRegistration()
        // Only now: clearing the stacks also re-enables registration, so clearing them
        // while it's disabled leaves the enable call unmatched (an exception).
        undoManager?.removeAllActions()

        // The timer's project merged into another one with the same name.
        if timer.isRunning, timer.project(in: context) == nil {
            let target = timerProjectID.flatMap { merged[$0] ?? $0 }.flatMap(UUID.init(uuidString:))
            let projects = try context.fetch(FetchDescriptor<Project>())
            if let replacement = projects.first(where: { $0.syncID == target })
                ?? projects.first(where: { $0.name == timerProjectName && !$0.isArchived }) {
                timer.reassign(to: replacement)
            }
        }
    }

    private func timerProject(in context: ModelContext) -> Set<String> {
        guard timer.isRunning, let id = timer.project(in: context)?.syncID else { return [] }
        return [id.uuidString]
    }

    /// The database file's path and file number: a moved, switched or restored database
    /// is a different file.
    private func currentStore() -> String? {
        guard let storeURL, let attributes = try? FileManager.default.attributesOfItem(atPath: storeURL.path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(storeURL.standardizedFileURL.path)#\(number)"
    }

    /// Save the ledger, and which database file it is in step with.
    private func save(_ state: SyncState, waiting: Bool) throws {
        self.state = state
        isWaiting = waiting
        let store = currentStore() ?? ledgerStore
        let file = Ledger(snapshot: DeviceSnapshot(device: device, publishedAt: .distantPast, state: state),
                          store: store, waiting: waiting, devices: knownDevices)
        defer { updateOtherMacs() }
        guard file != savedLedger else { return }
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DeviceSnapshot.encoder().encode(file).write(to: ledgerURL, options: .atomic)
        savedLedger = file
        ledgerStore = store
    }

    /// A waiting Mac publishes nothing: it has nothing to share yet.
    private func publish() async throws {
        guard let state, !isWaiting, state != publishedState || !ownFileExists else { return }
        let data = try DeviceSnapshot.encoder().encode(DeviceSnapshot(device: device, publishedAt: now(), state: state))
        let url = SyncFolder.fileURL(device: device.id, in: folder)
        try await Task.detached(priority: .utility) { try SyncFolder.write(data, to: url) }.value
        publishedState = state
        ownFileExists = true
    }

    private func readFolder() async throws -> [DeviceSnapshot] {
        let folder = self.folder, ownID = device.id, cache = self.cache
        let listing: SyncFolder.Listing
        do {
            listing = try await Task.detached(priority: .utility) {
                try SyncFolder.prepare(folder)
                return try SyncFolder.read(folder, ownDevice: ownID, cache: cache)
            }.value
        } catch is SyncFolder.Unavailable {
            throw SyncError(tr("iCloud Drive is off on this Mac. Turn it on in System Settings ▸ Apple Account ▸ iCloud."))
        } catch where SyncFolder.isPermissionDenied(error) {
            throw SyncError(tr("Work Tracker isn’t allowed to use iCloud Drive. Allow it in System Settings ▸ Privacy & Security ▸ Files & Folders, then sync again."))
        }
        self.cache = listing.others
        ownFileExists = listing.ownFileExists
        updateOtherMacs()
        return listing.others.values.compactMap(\.snapshot)
    }

    private func updateOtherMacs() {
        otherMacs = cache.map { url, file in
            let snapshot = file.snapshot
            let status: OtherMac.Status
            switch file.content {
            case .snapshot: status = .inSync
            case .newerFormat: status = .newerFormat
            case .unreadable(let message): status = .unreadable(message)
            }
            return OtherMac(id: url, name: snapshot?.device.name ?? url.deletingPathExtension().lastPathComponent,
                            updated: snapshot?.publishedAt ?? file.modified, appVersion: snapshot?.device.appVersion, status: status)
        }
        .sorted { ($0.name, $0.id.path) < ($1.name, $1.id.path) }
    }

    /// Publish what changed since the last sync, before quitting. Skipped whenever a
    /// sync would ask first or the database file was swapped.
    private func flush() {
        guard isEnabled, !isWaiting, question == nil, mode == .normal, !isSyncing, var state,
              currentStore() == ledgerStore || ledgerStore == nil,
              let context = try? context(), let local = try? exportLocal(context) else { return }
        let foreign = SyncDatabase.foreignRecords(in: state)
        let missing = SyncMerge.pendingDeletions(local, in: state, ignoring: foreign).count { state.records[$0]?.kind != .setting }
        guard missing < Self.deletionThreshold || missing * 5 < state.liveItemCount else { return }
        guard SyncMerge.absorb(local, into: &state, device: device.id, now: now(), ignoring: foreign) > 0,
              (try? save(state, waiting: false)) != nil else { return }
        guard let data = try? DeviceSnapshot.encoder().encode(DeviceSnapshot(device: device, publishedAt: now(), state: state)) else { return }
        // Don't hold up quitting: iCloud Drive may be waiting for a permission prompt.
        // The ledger is saved, so the next launch publishes what doesn't make it now.
        let url = SyncFolder.fileURL(device: device.id, in: folder)
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            try? SyncFolder.write(data, to: url)
            written.signal()
        }
        _ = written.wait(timeout: .now() + 3)
    }

    // MARK: - Triggers

    private func enable() {
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        if !observers.isEmpty { activate() }
    }

    private func activate() {
        watchFolder()
        poller?.cancel()
        poller = Task { [weak self] in
            var minutes = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                minutes += 1
                if minutes % 10 == 0 { await self?.sync() } else { await self?.checkFolder() }
            }
        }
        scheduleSync(after: .zero)
    }

    private func deactivate() {
        pending?.cancel()
        poller?.cancel()
        poller = nil
        watcher?.cancel()
        watcher = nil
    }

    /// Sync when another Mac's file changed (cheap: compares dates and sizes).
    private func checkFolder() async {
        guard isEnabled, !isSyncing else { return }
        let folder = self.folder, ownID = device.id, cache = self.cache
        let changed = await Task.detached(priority: .utility) { SyncFolder.hasChanges(folder, ownDevice: ownID, cache: cache) }.value
        if changed { scheduleSync(after: .zero) }
    }

    /// Opening the folder can wait for the iCloud Drive permission prompt, so it happens
    /// off the main thread; until then the minute-by-minute check covers changes.
    private func watchFolder() {
        guard watcher == nil, !isOpeningWatcher else { return }
        isOpeningWatcher = true
        let folder = self.folder
        Task { [weak self] in
            let descriptor = await Task.detached(priority: .utility) { () -> Int32 in
                guard (try? SyncFolder.prepare(folder)) != nil else { return -1 }
                return open(folder.path, O_EVTONLY)
            }.value
            guard let self else {
                if descriptor >= 0 { close(descriptor) }
                return
            }
            isOpeningWatcher = false
            guard descriptor >= 0 else { return }
            guard isEnabled, watcher == nil else {
                close(descriptor)
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.checkFolder() }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }
    }

    /// Synced preferences don't save the database; watch them directly.
    private func observeSettings() {
        withObservationTracking {
            _ = SyncDatabase.settings(preferences)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleSync()
                self?.observeSettings()
            }
        }
    }
}

struct SyncError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
