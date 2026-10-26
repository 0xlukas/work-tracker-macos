import SwiftUI
import SwiftData
import AppKit

struct SettingsView: View {
    var body: some View {
        // Standard macOS Settings layout: a tab per topic, each a grouped form.
        TabView {
            Tab(tr("General"), systemImage: "gearshape") { GeneralSettings() }
            Tab(tr("Work"), systemImage: "briefcase") { WorkSettings() }
            Tab(tr("Calls"), systemImage: "phone") { CallSettings() }
            Tab(tr("Storage"), systemImage: "externaldrive") { StorageSettings() }
            Tab(tr("Sync"), systemImage: "arrow.triangle.2.circlepath") { SyncSettings() }
            Tab(tr("Assistants"), systemImage: "sparkles") { AssistantSettings() }
            Tab(tr("Backups"), systemImage: "clock.arrow.circlepath") { BackupSettings() }
        }
        .frame(width: 600, height: 540)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker(tr("Language"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section {
                Picker(tr("CSV format"), selection: $preferences.csvFormat) {
                    ForEach(CSVFormat.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(tr("Export"))
            } footer: {
                Text(tr("Excel with German regional settings expects semicolons and decimal commas."))
            }

            CalendarSyncSection()

            Section {
                Toggle(tr("Show an inspirational quote on launch"), isOn: $preferences.dailyQuoteEnabled)
            } header: {
                Text(tr("Daily Quote"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalendarSyncSection: View {
    @Environment(Preferences.self) private var preferences
    @Environment(CalendarSync.self) private var calendarSync
    @Environment(DeviceSync.self) private var deviceSync

    var body: some View {
        Section {
            Toggle(tr("Show absences in Calendar"), isOn: Binding(
                get: { preferences.calendarSyncEnabled },
                set: { enabled in Task { await calendarSync.setEnabled(enabled) } }))
            if preferences.calendarSyncEnabled {
                if let error = calendarSync.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if calendarSync.needsAccess {
                        Button(tr("Open Privacy Settings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                } else if let date = calendarSync.lastSync {
                    LabeledContent(tr("Last updated")) {
                        Text([calendarSync.accountName, date.formatted(.app.day().month().year().hour().minute())]
                            .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(tr("Calendar"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Absences appear as all-day events in a “Work Tracker” calendar in iCloud and follow every change. Work Tracker manages that calendar, so edits made to it in Calendar are replaced. Turning this off keeps the calendar; delete it in Calendar if you no longer want it."))
                if deviceSync.isEnabled {
                    // Each Mac would otherwise rewrite the same iCloud calendar.
                    Text(tr("Your Macs sync, so turn this on for only one of them."))
                }
            }
        }
    }
}

// MARK: - Work: schedule, vacation, balances

private struct WorkSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var editingPeriod: WorkSchedule.Period?
    @State private var openingBalanceText = ""
    @State private var openingBalanceInvalid = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                ForEach(Array(preferences.schedule.periods.enumerated()), id: \.element.id) { index, period in
                    periodRow(period, isFirst: index == 0)
                }
                Button {
                    let start = max(Date().startOfDayZurich, (preferences.schedule.periods.last?.effectiveFrom ?? .distantPast).addingDays(1))
                    var period = preferences.schedule.period(on: start)
                    period.id = UUID()
                    period.effectiveFrom = start
                    editingPeriod = period
                } label: {
                    Label(tr("Add Schedule Change…"), systemImage: "plus")
                }
            } header: {
                Text(tr("Work Schedule"))
            } footer: {
                Text(tr("Expected hours per weekday. Add a change when your contract changes — earlier balances keep the old schedule. Half-day holidays and half-day absences count half of that day's hours."))
            }

            Section {
                DatePicker(tr("Start date"), selection: $preferences.trackingStartDate, displayedComponents: .date)
                LabeledContent(tr("Opening balance")) {
                    HStack(spacing: 6) {
                        TextField("", text: $openingBalanceText, prompt: Text("+0:00"))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onSubmit(commitOpeningBalance)
                        Text(tr("hours")).foregroundStyle(.secondary)
                    }
                }
                if openingBalanceInvalid {
                    Text(tr("Enter hours like +12:30, -4:15 or 7.5."))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(tr("Tracking"))
            } footer: {
                Text(tr("Overtime (+) or undertime (−) carried in from before the start date. Added to the all-time balance."))
            }

            Section {
                Stepper(value: $preferences.vacationEntitlement, in: 0...60, step: 0.5) {
                    LabeledContent(tr("Annual vacation entitlement")) {
                        Text(TimeFormatting.dayCount(preferences.vacationEntitlement))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Toggle(tr("Carry unused days into the next year"), isOn: $preferences.carryOverVacation)
                Stepper(value: $preferences.openingVacationCarryOver, in: 0...60, step: 0.5) {
                    LabeledContent(tr("Carried into %@", String(preferences.trackingStartDate.zurichYear))) {
                        Text(TimeFormatting.dayCount(preferences.openingVacationCarryOver))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text(tr("Vacation"))
            } footer: {
                Text(tr("Vacation beyond a year's allowance gets no time credit — those days count as normal working days."))
            }
        }
        .formStyle(.grouped)
        .onAppear { openingBalanceText = TimeFormatting.signedClock(preferences.openingBalanceHours) }
        .onDisappear(perform: commitOpeningBalance)
        .sheet(item: $editingPeriod) { period in
            ScheduleEditor(period: period, isFirst: period.id == preferences.schedule.periods.first?.id,
                           fullTimeWeeklyHours: preferences.fullTimeWeeklyHours) { saved, fullTimeWeek in
                preferences.fullTimeWeeklyHours = fullTimeWeek
                preferences.schedule.upsert(saved)
            }
        }
    }

    private func periodRow(_ period: WorkSchedule.Period, isFirst: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isFirst ? tr("Initial schedule") : tr("From %@", period.effectiveFrom.formatted(.app.day().month().year())))
                Text(scheduleSummary(period))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(tr("Edit…")) { editingPeriod = period }
                .controlSize(.small)
            if !isFirst {
                Button(role: .destructive) { preferences.schedule.remove(id: period.id) } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help(tr("Remove this schedule change"))
            }
        }
    }

    private func scheduleSummary(_ period: WorkSchedule.Period) -> String {
        let percent = (period.workload(fullTimeWeeklyHours: preferences.fullTimeWeeklyHours) * 100).rounded()
        return tr("%@ per week (%@%%)", TimeFormatting.hoursCompact(period.weeklyHours), String(Int(percent)))
    }

    private func commitOpeningBalance() {
        if let value = TimeFormatting.parseSignedHours(openingBalanceText.isEmpty ? "0" : openingBalanceText) {
            preferences.openingBalanceHours = value
            openingBalanceText = TimeFormatting.signedClock(value)
            openingBalanceInvalid = false
        } else {
            openingBalanceInvalid = true
        }
    }
}

/// Edit one schedule period: hours per weekday, with a workload shortcut.
private struct ScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var period: WorkSchedule.Period
    let isFirst: Bool
    @State var fullTimeWeeklyHours: Double
    /// Receives the edited period and the full-time reference week.
    let onSave: (WorkSchedule.Period, Double) -> Void
    @State private var workload = 100.0

    init(period: WorkSchedule.Period, isFirst: Bool, fullTimeWeeklyHours: Double,
         onSave: @escaping (WorkSchedule.Period, Double) -> Void) {
        _period = State(initialValue: period)
        self.isFirst = isFirst
        _fullTimeWeeklyHours = State(initialValue: fullTimeWeeklyHours)
        self.onSave = onSave
        _workload = State(initialValue: (period.workload(fullTimeWeeklyHours: fullTimeWeeklyHours) * 100).rounded())
    }

    private var weekdayNames: [String] {
        // Monday-first, in the UI language.
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        let symbols = formatter.standaloneWeekdaySymbols ?? []
        return (0..<7).map { symbols.isEmpty ? "\($0)" : symbols[($0 + 1) % 7].capitalized(with: Localization.locale) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isFirst {
                        LabeledContent(tr("Applies"), value: tr("From the start of tracking"))
                    } else {
                        DatePicker(tr("Applies from"), selection: $period.effectiveFrom, displayedComponents: .date)
                    }
                }

                Section {
                    ForEach(0..<7, id: \.self) { index in
                        Stepper(value: $period.hours[index], in: 0...14, step: 0.25) {
                            LabeledContent(weekdayNames[index]) {
                                Text(period.hours[index] == 0 ? tr("Off") : TimeFormatting.hours(period.hours[index]))
                                    .monospacedDigit()
                                    .foregroundStyle(period.hours[index] == 0 ? .tertiary : .secondary)
                            }
                        }
                    }
                    LabeledContent(tr("Per week"), value: TimeFormatting.hours(period.weeklyHours))
                } header: {
                    Text(tr("Hours per day"))
                }

                Section {
                    Stepper(value: $workload, in: 5...100, step: 5) {
                        LabeledContent(tr("Workload"), value: "\(Int(workload)) %")
                    }
                    Stepper(value: $fullTimeWeeklyHours, in: 20...50, step: 0.5) {
                        LabeledContent(tr("Full-time week"), value: TimeFormatting.hours(fullTimeWeeklyHours))
                    }
                    Button(tr("Spread Evenly over Monday–Friday")) {
                        let daily = fullTimeWeeklyHours / 5 * workload / 100
                        period.hours = [daily, daily, daily, daily, daily, 0, 0]
                    }
                } header: {
                    Text(tr("Part-time"))
                } footer: {
                    Text(tr("Sets each weekday to the workload's share of a full-time week. Adjust single days above afterwards."))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tr("Work Schedule"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save")) {
                        onSave(period, fullTimeWeeklyHours)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 440, height: 560)
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Preferences.self) private var preferences
    @Environment(BackupManager.self) private var backups

    /// A move waiting for the user's decision.
    private struct PendingMove: Identifiable {
        let id = UUID()
        let directory: URL
        let mirror: URL?
    }

    @State private var cloudChoice: URL?
    @State private var existingStoreMove: PendingMove?
    @State private var moveError: String?
    @State private var needsRestart = false

    private var currentDirectory: URL { StoreLocation.currentDirectory }
    private var isDefault: Bool { StoreLocation.customDirectory == nil }
    private var isCloud: Bool { StoreLocation.isCloudSynced(currentDirectory) }

    var body: some View {
        Form {
            if isCloud {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(tr("Your database is in a cloud-synced folder"), systemImage: "exclamationmark.icloud.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(tr("Sync clients upload the database and its journal separately and can create conflicting copies, which can corrupt or lose data. Keep the database on this Mac and let the app copy verified backups into the cloud folder instead."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(tr("Move Database to This Mac & Back Up to This Folder")) {
                            requestMove(to: StoreLocation.defaultDirectory,
                                        mirror: currentDirectory.appendingPathComponent("Work Tracker Backups", isDirectory: true))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(isDefault ? tr("Default (Application Support)") : tr("Custom location"),
                              systemImage: isDefault ? "internaldrive" : "folder")
                            .font(.subheadline)
                        Text(currentDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(tr("Choose Folder…")) { chooseFolder() }
                    if !isDefault {
                        Button(tr("Reset to Default")) { requestMove(to: StoreLocation.defaultDirectory, mirror: nil) }
                    }
                }
                .padding(.vertical, 2)
                Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([StoreLocation.storeURL]) }
            } header: {
                Text(tr("Database Location"))
            } footer: {
                Text(tr("Moving copies a consistent snapshot of your data to the new folder and restarts the app. The old copy is left in place."))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(tr("This folder is synced by a cloud service"), isPresented: Binding(
            get: { cloudChoice != nil }, set: { if !$0 { cloudChoice = nil } }
        ), presenting: cloudChoice) { folder in
            Button(tr("Keep Database Local & Back Up There")) {
                preferences.backupMirrorDirectory = folder
                Task { await backups.run(force: true) }
            }
            Button(tr("Store the Database There Anyway")) { requestMove(to: folder, mirror: nil) }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(tr("A live database in a synced folder can be corrupted. Recommended: keep it on this Mac and copy backups to that folder."))
        }
        .confirmationDialog(tr("That folder already contains a Work Tracker database"), isPresented: Binding(
            get: { existingStoreMove != nil }, set: { if !$0 { existingStoreMove = nil } }
        ), presenting: existingStoreMove) { move in
            Button(tr("Replace It with the Current Data")) { performMove(move, policy: .replace) }
            Button(tr("Use the Data Already There")) { performMove(move, policy: .useExisting) }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { move in
            let modified = DatabaseBackup.modificationDate(of: StoreLocation.storeURL(in: move.directory))?
                .formatted(.app.day().month().year().hour().minute()) ?? "–"
            Text(tr("The database there was last changed %@. Replacing it keeps the old file in Backups.", modified))
        }
        .alert(tr("Could not move the database"), isPresented: Binding(
            get: { moveError != nil }, set: { if !$0 { moveError = nil } }
        )) {
            Button(tr("OK")) {}
        } message: {
            Text(moveError ?? "")
        }
        .alert(tr("Restart Required"), isPresented: $needsRestart) {
            Button(tr("Restart Now")) {}
        } message: {
            Text(tr("Work Tracker restarts to use the new location. Changes are only saved there after the restart."))
        }
        .onChange(of: needsRestart) { _, showing in
            // However the alert is dismissed, restart: until then, edits would still go
            // to the old location and be missing from the new one.
            if !showing { StoreLocation.relaunch() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose data storage folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if StoreLocation.isCloudSynced(url) {
            cloudChoice = url
        } else {
            requestMove(to: url, mirror: nil)
        }
    }

    private func requestMove(to directory: URL, mirror: URL?) {
        let move = PendingMove(directory: directory, mirror: mirror)
        if StoreLocation.hasStore(in: directory) {
            existingStoreMove = move
        } else {
            performMove(move, policy: .refuse)
        }
    }

    private func performMove(_ move: PendingMove, policy: StoreLocation.ExistingStorePolicy) {
        do {
            try modelContext.save()
            try StoreLocation.moveStore(to: move.directory, existing: policy)
            if let mirror = move.mirror { preferences.backupMirrorDirectory = mirror }
            needsRestart = true
        } catch {
            moveError = error.localizedDescription
        }
    }
}

// MARK: - Sync

private struct SyncSettings: View {
    @Environment(DeviceSync.self) private var sync

    var body: some View {
        @Bindable var sync = sync
        Form {
            Section {
                Toggle(tr("Sync with your other Macs"), isOn: $sync.isTurnedOnInSettings)
                if sync.isTurningOn && !sync.isEnabled && sync.joinRequest == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("Connecting to iCloud Drive… If macOS asks, allow Work Tracker to access files in iCloud Drive."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let notice = sync.notice {
                    Label(notice, systemImage: "info.circle")
                }
                if let error = sync.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if sync.isWaiting {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Waiting for data from your other Macs. Anything you add here meanwhile is added to theirs. If no other Mac syncs yet, start with this Mac’s data instead."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(tr("Start with This Mac’s Data")) { Task { await sync.startWithThisMacsData() } }
                            .disabled(sync.isSyncing)
                    }
                }
                if sync.isEnabled {
                    LabeledContent(tr("Last synced")) {
                        HStack(spacing: 6) {
                            if sync.isSyncing { ProgressView().controlSize(.small) }
                            Text(sync.lastSync?.formatted(.app.day().month().year().hour().minute()) ?? "–")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(tr("Sync Now")) { Task { await sync.sync() } }
                            .disabled(sync.isSyncing || sync.question != nil)
                        Button(tr("Show Sync Folder")) { NSWorkspace.shared.open(sync.folder) }
                    }
                }
            } header: {
                Text(tr("Sync Between Macs"))
            } footer: {
                Text(tr("Each Mac keeps its own database. Work Tracker exchanges the changes through the “Work Tracker Sync” folder in iCloud Drive and merges them; when the same item was changed on two Macs, the later change wins. The work schedule, vacation and balance settings sync too. Language, export format, backups and the calendar are set per Mac."))
            }

            if let question = sync.question {
                SyncQuestionSection(question: question)
            }

            if sync.isEnabled {
                Section(tr("Other Macs")) {
                    if sync.otherMacs.isEmpty {
                        Text(tr("No other Mac yet. Turn on sync in Work Tracker on your other Mac too."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sync.otherMacs) { mac in
                        LabeledContent {
                            Text(status(of: mac))
                                .foregroundStyle(mac.status == .inSync ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text(mac.name)
                            if let version = mac.appVersion {
                                Text(tr("Work Tracker %@", version))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(tr("Your other Macs already sync their data"), isPresented: $sync.isAskingToJoin,
                            presenting: sync.joinRequest) { _ in
            // Clear the request first: dismissing the dialog with it still set turns sync off.
            Button(tr("Combine Both")) { join(.combine) }
            Button(tr("Use Only the Other Macs’ Data"), role: .destructive) { join(.useOtherMacs) }
            Button(tr("Use Only This Mac’s Data"), role: .destructive) { join(.useThisMac) }
            Button(tr("Cancel"), role: .cancel) { sync.turnOff() }
        } message: { request in
            Text(tr("This Mac has %@ items of its own, and the synced data from %@ has %@. Combine them, or keep only one side’s data. Combining takes the schedule, vacation and balance settings from the other Macs. Whatever is replaced on this Mac is backed up first.",
                    String(request.localItems), request.otherMacs.formatted(.list(type: .and).locale(Localization.locale)),
                    String(request.otherItems)))
        }
    }

    private func join(_ decision: DeviceSync.JoinDecision) {
        sync.joinRequest = nil
        Task { await sync.join(decision) }
    }

    private func status(of mac: DeviceSync.OtherMac) -> String {
        switch mac.status {
        case .inSync:
            return mac.updated.map { tr("Updated %@", $0.formatted(.app.day().month().year().hour().minute())) } ?? ""
        case .newerFormat:
            return tr("Has a newer version of Work Tracker; update this Mac")
        case .unreadable(let message):
            return tr("Can’t read its data: %@", message)
        }
    }
}

/// Sync waits for a decision (also asked in the main window).
struct SyncQuestionSection: View {
    @Environment(DeviceSync.self) private var sync
    let question: DeviceSync.Question

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(question.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(question.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(question.answers, id: \.label) { option in
                        Button(option.label, role: option.isDestructive ? .destructive : nil) {
                            Task { await sync.answer(option.answer, to: question) }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

extension DeviceSync.Question {
    struct Option {
        let answer: DeviceSync.Answer
        let label: String
        let isDestructive: Bool
    }

    var title: String {
        switch self {
        case .missingItems: return tr("Sync is paused")
        case .otherDatabase: return tr("This Mac uses a different database")
        case .deletedElsewhere(let mac, _): return tr("“%@” deleted many items", mac)
        }
    }

    var message: String {
        switch self {
        case .missingItems(let count):
            return tr("%@ items that were there at the last sync are missing on this Mac. Sync waits, so they aren’t deleted on your other Macs too. Restore them from sync, or delete them everywhere if you removed them on purpose.",
                      String(count))
        case .otherDatabase(let changes):
            return tr("%@ items differ from the last sync because this Mac’s database file was switched or restored. Sync waits until you choose which data to keep.",
                      String(changes))
        case .deletedElsewhere(_, let count):
            return tr("Syncing would delete %@ items on this Mac too. Sync waits, in case that wasn’t meant to happen. Delete them here as well (this Mac’s data is backed up first), or keep them and bring them back on all Macs.",
                      String(count))
        }
    }

    /// The safer answer first.
    var answers: [Option] {
        switch self {
        case .missingItems:
            return [Option(answer: .restoreMissing, label: tr("Restore Them"), isDestructive: false),
                    Option(answer: .deleteEverywhere, label: tr("Delete Them on All Macs"), isDestructive: true)]
        case .otherDatabase:
            return [Option(answer: .useSyncedData, label: tr("Use the Synced Data"), isDestructive: false),
                    Option(answer: .useThisDatabase, label: tr("Use This Database on All Macs"), isDestructive: true)]
        case .deletedElsewhere:
            return [Option(answer: .keepThem, label: tr("Keep Them"), isDestructive: false),
                    Option(answer: .deleteHereToo, label: tr("Delete Them Here Too"), isDestructive: true)]
        }
    }
}

// MARK: - Calls

private struct CallSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Preferences.self) private var preferences
    @Environment(CallControl.self) private var callControl
    @State private var newDepartment = ""
    @State private var editingDepartment: String?
    @State private var editName = ""
    @State private var departmentError: String?
    @FocusState private var renameFocused: Bool

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle(tr("Track calls"), isOn: $preferences.callTrackingEnabled)
                if preferences.callTrackingEnabled {
                    Picker(tr("Keyboard shortcut"), selection: $preferences.callShortcut) {
                        ForEach(CallShortcut.allCases) { Text($0.title).tag($0) }
                    }
                    if callControl.shortcutUnavailable {
                        Text(tr("Another app already uses %@. Pick another shortcut.", preferences.callShortcut.title))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text(tr("Calls"))
            } footer: {
                Text(tr("Log who called, what about, which department it concerned, roughly how long it took and who solved the issue. The shortcut opens a small panel in any app; clicking the call’s length saves it. Calls don’t change your hours. Turning this off hides calls on this Mac and keeps them."))
            }

            if preferences.callTrackingEnabled {
                Section {
                    ForEach(preferences.callDepartments, id: \.self) { department in
                        departmentRow(department)
                    }
                    .onMove { preferences.callDepartments.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField(tr("Add department"), text: $newDepartment, prompt: Text(tr("New department")))
                            .labelsHidden()
                            .onSubmit(addDepartment)
                            .onChange(of: newDepartment) { departmentError = nil }
                        Button(tr("Add"), action: addDepartment)
                            .disabled(CallNames.trimmed(newDepartment).isEmpty)
                    }
                    if let departmentError {
                        Text(departmentError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(tr("Departments"))
                } footer: {
                    Text(tr("The choices of the call panel’s Department menu; drag to reorder. Removing one keeps it on earlier calls; renaming one renames it in every call. Your Macs share this list."))
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func departmentRow(_ department: String) -> some View {
        if editingDepartment == department {
            HStack {
                TextField(tr("Department"), text: $editName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { rename(department) }
                    .onAppear { renameFocused = true }
                Button(tr("Save")) { rename(department) }
                Button(tr("Cancel")) { editingDepartment = nil }
            }
        } else {
            HStack {
                Text(department)
                Spacer()
                Button { startEditing(department) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help(tr("Rename"))
                    .accessibilityLabel(tr("Rename %@", department))
                Button { preferences.callDepartments.removeAll { $0 == department } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(tr("Remove"))
                .accessibilityLabel(tr("Remove %@", department))
            }
            .contextMenu {
                Button(tr("Rename")) { startEditing(department) }
                Button(tr("Remove"), role: .destructive) { preferences.callDepartments.removeAll { $0 == department } }
            }
        }
    }

    private func isTaken(_ name: String, except: String? = nil) -> Bool {
        preferences.callDepartments.contains { $0 != except && CallNames.same($0, name) }
    }

    private func addDepartment() {
        let name = CallNames.trimmed(newDepartment)
        guard !name.isEmpty else { return }
        guard !isTaken(name) else {
            departmentError = tr("A department with this name already exists.")
            return
        }
        preferences.callDepartments.append(name)
        newDepartment = ""
    }

    private func startEditing(_ department: String) {
        editingDepartment = department
        editName = department
        departmentError = nil
    }

    private func rename(_ department: String) {
        let name = CallNames.trimmed(editName)
        guard !name.isEmpty, name != department else {
            editingDepartment = nil
            return
        }
        guard !isTaken(name, except: department) else {
            departmentError = tr("A department with this name already exists.")
            return
        }
        if let index = preferences.callDepartments.firstIndex(of: department) {
            preferences.callDepartments[index] = name
        }
        CallLog.rename(department, to: name, field: \.department, context: modelContext)
        try? modelContext.save()
        editingDepartment = nil
    }
}

// MARK: - Assistants

private struct AssistantSettings: View {
    @Environment(AssistantServer.self) private var server
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle(tr("Let AI assistants use Work Tracker"), isOn: Binding(
                    get: { server.isEnabled }, set: { server.setEnabled($0) }))
                if server.isEnabled {
                    if let error = server.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        LabeledContent(tr("Address")) {
                            Text(server.endpoint)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text(tr("AI Assistants"))
            } footer: {
                Text(tr("Claude Code, Codex and other assistants that support MCP can then read your entries, balances, absences and projects and change them. Only apps on this Mac can connect, and only with the key in their setup. Their changes sync to your other Macs and can’t be undone with ⌘Z. Turn this on only on the Mac where your assistants run."))
            }

            if server.isEnabled {
                Section {
                    LabeledContent(tr("Claude Code")) {
                        copyButton(tr("Copy Command"), id: "claude", text: claudeCommand)
                    }
                    LabeledContent(tr("Codex")) {
                        copyButton(tr("Copy Settings"), id: "codex", text: codexSettings)
                    }
                    LabeledContent(tr("Key")) {
                        Button(tr("New Key")) {
                            server.renewToken()
                            copied = nil
                        }
                    }
                } header: {
                    Text(tr("Setup"))
                } footer: {
                    Text(tr("Run the Claude Code command in Terminal, or add the Codex settings to ~/.codex/config.toml. Both contain the key. A new key locks out assistants set up with the old one until you set them up again."))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var claudeCommand: String {
        "claude mcp add --scope user --transport http work-tracker \(server.endpoint) --header \"Authorization: Bearer \(server.token)\""
    }

    private var codexSettings: String {
        """
        [mcp_servers.work-tracker]
        url = "\(server.endpoint)"
        http_headers = { Authorization = "Bearer \(server.token)" }
        """
    }

    private func copyButton(_ title: String, id: String, text: String) -> some View {
        Button(copied == id ? tr("Copied") : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = id
        }
    }
}

// MARK: - Backups

private struct BackupSettings: View {
    @Environment(BackupManager.self) private var backups
    @Environment(Preferences.self) private var preferences
    @Environment(DeviceSync.self) private var deviceSync
    @State private var pendingRestore: BackupSnapshot?
    @State private var restoreResult = StoreLocation.takeRestoreResult()

    var body: some View {
        Form {
            if let restoreResult {
                Section {
                    Label(restoreResult, systemImage: "checkmark.circle")
                }
            }

            Section {
                if let date = backups.lastBackup {
                    LabeledContent(tr("Last backup")) {
                        Text(date.formatted(.app.day().month().year().hour().minute()))
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = backups.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Button(tr("Back Up Now")) {
                        Task { await backups.run(force: true) }
                    }
                    .disabled(backups.isRunning)
                    Button(tr("Show Backups")) {
                        try? FileManager.default.createDirectory(at: backups.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(backups.directory)
                    }
                }
            } header: {
                Text(tr("Database Backups"))
            } footer: {
                Text(tr("A verified backup is saved daily while the app is running (skipped when nothing changed). The latest 30 are kept on this Mac."))
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preferences.backupMirrorDirectory?.path ?? tr("Not set"))
                            .font(.caption)
                            .foregroundStyle(preferences.backupMirrorDirectory == nil ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(tr("Choose Folder…")) { chooseMirror() }
                    if preferences.backupMirrorDirectory != nil {
                        Button(tr("Stop Copying")) { preferences.backupMirrorDirectory = nil }
                    }
                }
                if let error = backups.mirrorErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(tr("Copy Backups To"))
            } footer: {
                Text(tr("Also copy each backup to another folder — for example a cloud drive — so your data survives losing this Mac."))
            }

            Section(tr("Restore")) {
                if backups.snapshots.isEmpty {
                    Text(tr("No backups yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(backups.snapshots) { snapshot in
                    HStack {
                        Text(snapshot.date.formatted(.app.weekday(.abbreviated).day().month().year().hour().minute()))
                            .monospacedDigit()
                        Text(ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(tr("Restore…")) { pendingRestore = snapshot }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { backups.refresh() }
        .confirmationDialog(tr("Restore this backup?"), isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        ), presenting: pendingRestore) { snapshot in
            Button(tr("Restore and Restart"), role: .destructive) { backups.restore(snapshot) }
            Button(tr("Cancel"), role: .cancel) {}
        } message: { snapshot in
            let message = tr("Work Tracker restarts and replaces the current data with the backup from %@. The current database is kept in the Backups folder.",
                             snapshot.date.formatted(.app.day().month().year().hour().minute()))
            Text(deviceSync.isEnabled ? message + " " + tr("Your other Macs also go back to this backup.") : message)
        }
    }

    private func chooseMirror() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose a folder for backup copies")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.backupMirrorDirectory = url
        Task { await backups.run(force: true) }
    }
}
