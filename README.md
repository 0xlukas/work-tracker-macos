# Work Tracker

A macOS 27 app for tracking working hours against a Swiss (Zurich) work schedule: time entries per project, absences, public holidays, vacation allowance and overtime balance. The interface follows the macOS 27 Liquid Glass design language.

This repository is published automatically from the author's own repository, one commit per update. Issues and pull requests are welcome; accepted changes are made there and arrive here with the next update.

## Installing

Work Tracker isn't in the App Store, so build it yourself: install Xcode 27 (it needs the macOS 27 SDK), run `scripts/build-app.sh` and move `.build/app/WorkTracker.app` to `/Applications`. A build made on your own Mac opens like any other app. A copy built elsewhere is signed ad hoc only, so macOS blocks it the first time; allow it in System Settings ▸ Privacy & Security ▸ Open Anyway.

Public holidays are the ones of the canton of Zurich (see Work schedule and balances).

Work Tracker is under the MIT license (`LICENSE`).

## Building

```sh
swift test                      # needs Xcode selected and its license accepted
scripts/build-app.sh            # release WorkTracker.app in .build/app
BUNDLE_ID=com.worktracker.app.test scripts/build-app.sh /tmp/test   # separate settings, data and sync folder for testing
WORK_TRACKER_LIVE_MODEL=1 swift test --filter LiveVoiceModelTests  # sample sentences through the on-device model
```

The app is built from `WorkTracker.xcodeproj` (open it in Xcode to run and debug). Its app target syncs the `WorkTracker/Sources` folder, so new files need no project changes; `Package.swift` covers the same sources for `swift test`. Keep the deployment target (27.0) and Swift version in step between the two. Xcode compiles the String Catalogs (`Localizable`, `InfoPlist` for the privacy prompts, `AppShortcuts` for the Siri phrases), the Liquid Glass icon (`Resources/AppIcon.icon`), extracts the App Intents metadata Siri and Shortcuts read, and signs ad hoc with the hardened runtime and the microphone entitlement (`WorkTracker/WorkTracker.entitlements`).

Only the installed app (bundle ID `com.worktracker.app`) uses the real data: every other build keeps its database in `~/Library/Application Support/WorkTracker (<bundle ID>)/` and syncs through `Work Tracker Sync (<bundle ID>)` in iCloud Drive. Xcode's Debug configuration is `com.worktracker.app.debug` for that reason, so trying something out on a Mac that syncs never touches the real data. To test syncing on one Mac, run two test builds with `defaults write <bundle ID> syncFolder -string <folder>` pointing both at the same folder.

## Features

- **Daily Entry** — entries per day with project and optional note. Times are typed as `0930`, `930`, `9` or `9:30`; ↑/↓ nudge (⇧ for hours); the End field accepts `24:00`. ⌘[ / ⌘] move between days, ⌘T jumps to today, ⌘N adds an entry. Right-click an entry to duplicate it; **More ▸ Copy Entries from …** copies the previous day with entries (overlapping ones are skipped). New entries default to the last-used project.
- **Missing entries** — past working days since tracking started with no time entries and no full-day absence are flagged: a count on Daily Entry in the sidebar, an orange mark in the week list, and a **days without entries** menu under the week that jumps to them. Overview shows the count for the selected year. Today only counts once it's over.
- **Timer** — start a timer for a project from the toolbar or the menu bar item; stopping it creates entries, split at midnight and around existing entries. The menu bar shows today's hours and this week's balance. A running timer survives quitting.
- **Voice entry** (Apple Intelligence) — the microphone button in Daily Entry (⇧⌘D) listens in the UI language, transcribed on the Mac with SpeechAnalyzer. The on-device model turns the sentence into a command: “Starting work on Alpha” / «Ich beginne mit Alpha» starts the timer (switching from a running one), “Stopping work” / «Feierabend» stops and saves it, and “Yesterday 8:30 to 12 on Alpha, code review” opens pre-filled entry sheets to confirm (several blocks in one sentence open one after another). Needs Apple Intelligence turned on.
- **Siri and Shortcuts** — “Start work on Alpha in Work Tracker”, “Stop work in Work Tracker”, “Log work in Work Tracker”, “Log a call in Work Tracker” or “Log a call from Meier in Work Tracker” (German: «Arbeit an Alpha in Work Tracker beginnen», «Feierabend in Work Tracker», «Anruf von Meier in Work Tracker erfassen», …). The actions Start Work, Stop Work, Log Work and Log Call are also in the Shortcuts app and Spotlight. Siri phrases must name the app; the in-app button doesn't need it.
- **Undo** — Edit ▸ Undo (⌘Z) reverts deleting, copying and editing entries, absences and projects. Changes from other Macs or AI assistants aren't undoable and clear the undo history.
- **AI assistants** — Settings ▸ Assistants lets Claude Code, Codex and other MCP clients on the same Mac read and change everything (see below).
- **Projects** — colour per project (click the circle), archiving (hides a project from pickers, keeps its history), and an hours-per-project report for any date range. Names must be unique.
- **Absences** — click cycle full day → half day → none, Shift-click for ranges. Built-in categories: vacation, sick, public service, unpaid leave (reduces expected hours, so it neither uses vacation nor touches the overtime balance); plus custom categories (see below).
- **Calendar** — Settings ▸ General ▸ **Show absences in Calendar** (off by default) keeps a “Work Tracker” calendar in iCloud (or the Mac's default calendar account) in step with your absences: one all-day event per run of days of the same category. Weekends and public holidays in between don't split a run, half days are events of their own, and the events follow every change, undo included. The app owns that calendar and replaces anything else in it. Turning the setting off leaves the calendar as it is.
- **Sync between Macs** — Settings ▸ Sync keeps the data of several Macs in step through iCloud Drive (see below).
- **Calls** — Settings ▸ Calls ▸ **Track calls** (off by default, per Mac) logs who called, about what, which department it concerned, roughly how long it took and who solved the issue (see below).
- **Overview** — today/week/month, balance to date, all-time balance (with opening balance), holiday and absence counts, monthly breakdown, CSV export (daily summary or every entry; comma or German-Excel semicolon format).

## Work schedule and balances

Settings ▸ Work holds the contract hours per weekday. Add a schedule change when the contract changes (for example 80% from next January); earlier days keep their old schedule. Half-day holidays and half-day absences count half of that day's scheduled hours. Days without scheduled hours expect nothing and take no absences.

Public holidays are the Zurich holidays as defined in `Holidays.swift` (Easter-based dates, Sechseläuten and Knabenschiessen), computed for any year.

The vacation allowance applies per calendar year. Optionally, unused days carry into the next year, and days can be carried into the first tracked year. Vacation beyond a year's allowance gets no time credit: those specific days count as working days, so every period — a month, a year, all-time — shows the same result. An opening balance (overtime from before tracking started) is added to the all-time balance.

## Custom absence categories

In **Absences**, use **Manage Categories…** beside the category picker. Add a name, colour, icon, and counting rule:

- **Reduce expected hours:** time off without consuming vacation allowance.
- **Use vacation allowance:** time off counted against the shared annual vacation allowance.
- **Leave expected hours unchanged:** record the absence without granting time credit.

Renaming or changing the colour/icon updates existing displays. Counting-rule changes apply only when assigning a category to a new entry; existing entries retain their original rule. Archiving removes a category from the picker while preserving historical entries and reports. Built-in categories cannot be edited or archived.

## Calls

Calls are logged after the fact, never timed: a call's length is one of three blocks, under 15 minutes (`< 15 min`), 15 minutes to 1 hour (`< 1 h`) or over 1 hour (`> 1 h`). Calls sit beside the working time; they don't create entries or change any balance.

- **Logging:** ⌃⌥C in any app (Settings ▸ Calls offers ⌃⌥⌘C or no shortcut; a Carbon hot key, so no Accessibility permission), **Log Call** in the menu bar or ⌘N on the Calls screen opens a small floating panel that takes typing without bringing Work Tracker to the front. Caller and topic complete from earlier calls (ignoring case and accents, and taking the earlier spelling); the latest callers and the chosen caller's usual topics are one click away, and Return moves on to the next field. The **Department** menu offers the departments from Settings ▸ Calls and picks the one last used with the caller. **Solved by me** is ticked when the person called solved the issue and left unticked when the caller did. Clicking the length (or ⌘1–⌘3) saves the call as of now; Esc or the shortcut again closes the panel.
- **Calls screen** (sidebar, while calls are tracked): a week, month, year, all calls or a custom range (**From**/**To**), stepped with the arrows. Cards show the number of calls and the time on them, each against the period before (while a period is under way, against the same point of the one before: “vs. this time last week”); the share solved by me; and the calls per length. Below them: a chart of the calls per day, week or month (whichever fits the period), split by length; the calls per weekday and per hour of the day; **Recurring Questions**, the same caller about the same topic more than once (click one to show those calls); and counts with time per caller, topic and department (click one to show only its calls), then the list of calls. Double-click a call to change it, including its day and time; **Log Earlier Call…** (in the ⋯ menu) adds one that's already over. Right-click a caller or topic to rename it in every call (onto an existing name merges the two).
- **Time on calls** is estimated, since calls aren't timed: a call counts as 7.5 minutes (`< 15 min`), 37.5 minutes (`< 1 h`) or 75 minutes (`> 1 h`), and estimates are shown with ≈.
- **Siri:** “Log a call in Work Tracker” (or “… from Meier …”) asks who called, what the call was about, how long it was (under 15 minutes, under an hour, over an hour) and whether you solved the issue. Siri learns the callers' names, so known callers work in the phrase; a name Siri doesn't know becomes a new caller. The department follows the caller as in the panel; in Shortcuts it can be set. Logging needs **Track calls** on.
- **Departments** are kept in Settings ▸ Calls and sync. Removing one keeps it on earlier calls; renaming one renames it in every call.
- **Export for an AI:** **Copy All Calls for AI** (top of the Calls screen) copies every call as Markdown to paste into an AI chat or upload: what the data is and how to read it (the length blocks, the time estimate, who “solved by” means), an overview, exact tables the model would otherwise count itself (and often miscount) — per caller with their most common topic, topic, department, recurring questions, month, weekday and hour of the day — then every call as CSV, which its analysis tools can load. The **Export** menu does the same for the calls shown (the period and any filter) or for all calls, and saves either as Markdown or CSV (one row per call, with an estimated minutes column).

## Storage

The database is `WorkTracker.store` in `~/Library/Application Support/WorkTracker/` or a folder chosen in Settings ▸ Storage. Moving it copies a consistent snapshot (SQLite backup API) to the new folder and restarts the app; an existing database in the destination is never overwritten silently — you choose to replace it (the old file is kept under Backups) or to use it.

Keep the live database out of cloud-synced folders (Google Drive, iCloud Drive, Dropbox, OneDrive): sync clients upload the store and its WAL separately and can corrupt it. The app warns when the database is in such a folder and offers to move it to this Mac and copy backups there instead.

If the database cannot be opened, the app shows a recovery window instead of quitting: restore the latest backup, reveal the files, or quit. Nothing is deleted or recreated. When the Mac syncs, **Replace with Synced Data** moves the database into Backups and fills a new one from sync instead, which is usually newer than the latest backup.

## Sync between Macs

Settings ▸ Sync ▸ **Sync with your other Macs** (off by default). Each Mac keeps its own database; the live database never goes to iCloud. Instead, each Mac keeps a ledger of every record it knows — entries, projects, absences, custom categories, calls, the call departments and the preferences balances depend on (schedule, allowance, carry-over, start date, opening balance, full-time week) — with the time of its last change, and publishes it as `device-<id>.json` in the “Work Tracker Sync” folder in iCloud Drive. Every Mac writes only its own file and merges the others record by record: the later change wins, deleted records stay as markers so a deletion syncs too. Language, export format, backups, the calendar setting, whether calls are tracked (and their shortcut) and a running timer stay per Mac. Records are matched by the sync ID every row has since schema V5 (`Sync/`, `SyncMerge` for the rules).

Syncs run after launch, about two seconds after a change, when the app becomes active, when another Mac's file changes (checked every minute, and through a folder watch) and every ten minutes; quitting publishes pending changes. Undo doesn't cover changes that arrive from another Mac.

- **Turning it on:** the first Mac with data publishes it. A Mac whose database is empty takes the other Macs' data without asking; if no other Mac syncs yet, it waits (publishing nothing, so it can't override anything) and joins the first data that arrives, adding whatever was entered meanwhile. While waiting, **Start with This Mac's Data** makes it the first Mac. A Mac with data of its own that joins asks, with item counts, whether to **combine** both, use only the other Macs' data, or use only its own. Combining adds this Mac's items the others don't know; wherever they know an item, their version stays (deletions and newer edits included), and their preferences win. This Mac backs up first whenever its own items change. While another Mac's file can't be read (or comes from a newer version), a Mac doesn't go first. Turning sync off removes the Mac's file from the folder and keeps its data.
- **Preferences:** whenever sync changes this Mac's synced preferences, it first saves their values as `settings-before-sync-….json` next to the backups (backups only hold the database; the newest 30 are kept), and says so when they come from a Mac it meets for the first time. If that file can't be written, nothing is changed.
- **Merging rules:** two projects (or custom categories) with the same name merge into the oldest one, which takes over the entries (and a running timer); two absences on one day and the same entry added twice become one; a project or category another Mac deleted comes back while entries, absences or the timer still use it. Macs that started syncing apart from each other simply merge.
- **Sync asks before anything drastic**, in the main window and in Settings ▸ Sync (the menu bar points to it), and syncs nothing meanwhile:
  - many items (10 or more, and at least a fifth of all) are missing from this Mac's database compared with the last sync: restore them, or delete them everywhere;
  - many items would be deleted here because another Mac deleted them (or chose to use only its own data): delete them here too, or keep them and bring them back everywhere;
  - the database file was swapped (another folder's database chosen in Settings ▸ Storage, a Time Machine restore) and differs from the last sync: use the synced data (the file is made to match it exactly), or this database on all Macs.

  Each sync checks the situation again: a question disappears when it no longer applies, and an answer only applies to its own question and while no more is at stake than when it was given. Several questions are asked in turn.
- Before deleting or replacing many items, a Mac makes a backup right away, before anything can change, and does nothing if the backup fails. **Restoring a backup** sends that state to the other Macs too (they confirm large deletions); this also holds when the first sync after the restore fails.
- **Different versions:** values a newer version wrote that this one doesn't know (a new absence type or preference) are passed on untouched. Changes that need more (a new kind of record or field) raise the file format, and older Macs then wait with "update this Mac" until they're updated.
- macOS asks once per Mac whether Work Tracker may access files in iCloud Drive; sync waits for the answer. If access was declined, allow it in System Settings ▸ Privacy & Security ▸ Files & Folders.

Use **Show absences in Calendar** on only one of the Macs, so they don't both rewrite the same iCloud calendar.

## AI assistants (MCP)

Settings ▸ Assistants ▸ **Let AI assistants use Work Tracker** (off by default, per Mac) runs an [MCP](https://modelcontextprotocol.io) server inside the app: Streamable HTTP with plain JSON responses at `http://127.0.0.1:47615/mcp`. It listens on the loopback interface only, so nothing outside the Mac can reach it, and every request needs `Authorization: Bearer <key>`; requests addressed to another host name or sent from a web page of another origin are refused. The key is generated when the server is first turned on; **New Key** replaces it. Idle, the server only waits for connections. It's stateless, so clients keep working when the app restarts for an update. Turn it on on the Mac where the assistants run: their changes reach the other Macs through sync.

Set up a client with **Copy Command** (Claude Code; run it in Terminal) or **Copy Settings** (Codex; add to `~/.codex/config.toml`):

```sh
claude mcp add --scope user --transport http work-tracker http://127.0.0.1:47615/mcp --header "Authorization: Bearer <key>"
```

The tools (`Assistant/AssistantTools.swift`) work on the app's database, calculator and preferences, so answers match what the app shows and the app's rules apply (no overlapping entries, unique project names, archived projects take no entries, …):

- **Read:** `get_overview` (today, balances, vacation, timer, sync state), `get_summary` (a period, optionally per day, week or month), `list_entries`, `list_projects`, `list_absences`, `list_absence_categories`, `get_vacation`, `list_days_without_entries`, `list_holidays`, `get_settings`.
- **Write:** `add_entries` (all or nothing), `update_entry`, `delete_entries`, `copy_entries`, `set_absences` / `remove_absences` (ranges; non-working days are skipped), `create_project` / `update_project` / `delete_project`, `create_absence_category` / `update_absence_category`, `start_timer` / `stop_timer` / `discard_timer`, `update_settings`, `set_schedule` / `remove_schedule_change`.
- **Calls:** `list_calls`, `get_call_summary` (per length, caller, topic and department, with estimated minutes), `log_call`, `update_call`, `delete_calls`. Lengths are `short`, `medium` and `long`; departments must be in the list from Settings ▸ Calls.

Dates are `YYYY-MM-DD` (or today/yesterday) and times `HH:MM` in Zurich time; entries are identified by their sync ID. A test build next to the installed app needs another port: `defaults write <bundle ID> assistantServerPort -int 47616`.

## Backups

The app checks hourly (while running, with or without a window) whether a backup is due and makes at most one a day; **Back Up Now** forces one. Snapshots use SQLite's online backup API, including committed WAL data, pass an integrity check, and are self-contained single files. If nothing changed since the last snapshot, that one is re-dated instead of storing a copy, so the 30 retained snapshots cover as much history as possible. Snapshots live under `~/Library/Application Support/WorkTracker/Backups/<id>/`; **Copy Backups To** additionally copies each one to another folder (for example a cloud drive), with the same retention.

To restore, pick a snapshot in Settings ▸ Backups ▸ Restore. The app restarts, moves the current database (with its WAL/SHM files) into `Backups/replaced-…`, and copies the snapshot in place before opening it; when the Mac syncs, the other Macs go back to it too. Preferences (schedule, allowance, start date, opening balance) live in the app's defaults, not in the database.

## Validation

`swift test` covers the calculator (all categories and day kinds, schedules, per-year allowance and carry-over), holidays, migrations V1–V6, backups, store moves and restores, sync (the merge rules, and two simulated Macs syncing through a folder: joining, both directions, conflicts, missing items, restores, recovery), CSV, the timer, entry actions, parsing, voice command resolution, the assistant tools and MCP server (HTTP parsing, request checks, a round trip over the network), calls (name matching, suggestions, reports, periods, statistics, the Markdown and CSV exports, migration V5–V6, syncing), and catalog completeness. Set `WORK_TRACKER_TEST_STORE` to a standalone database snapshot to also check that a real store migrates without losing entries or hours.
