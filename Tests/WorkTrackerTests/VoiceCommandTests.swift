import XCTest
import SwiftData
@testable import WorkTracker

final class VoiceCommandTests: XCTestCase {
    /// Friday 25 September 2026, 16:40 Zurich.
    let now = time(day(9, 25), 16, 40)
    let nextStart = { (day: Date) in time(day, 13) }

    private func command(_ action: SpokenAction, project: String? = nil, time: String? = nil,
                         entries: [SpokenEntry] = []) -> VoiceCommand {
        VoiceCommand(SpokenCommand(action: action, project: project, time: time, entries: entries),
                     transcript: "worked on code review today", now: now, nextStart: nextStart)
    }

    private func entry(_ day: String = "2026-09-25", start: String? = nil, end: String? = nil, minutes: Int? = nil,
                       project: String? = "Alpha", note: String? = nil) -> SpokenEntry {
        SpokenEntry(day: day, start: start, end: end, minutes: minutes, project: project, note: note)
    }

    private func draft(_ entry: SpokenEntry) -> EntryDraft? {
        guard case .log(let drafts) = command(.log, entries: [entry]) else { return nil }
        return drafts.first
    }

    func testTimerCommands() {
        XCTAssertEqual(command(.startTimer, project: "Alpha"), .startTimer(project: "Alpha", at: nil))
        XCTAssertEqual(command(.startTimer, project: "Alpha", time: "08:15"),
                       .startTimer(project: "Alpha", at: time(day(9, 25), 8, 15)))
        XCTAssertEqual(command(.stopTimer), .stopTimer(at: nil))
        XCTAssertEqual(command(.stopTimer, time: "17:30"), .stopTimer(at: nil), "a future time means now")
        XCTAssertEqual(command(.stopTimer, time: "16:39"), .stopTimer(at: nil), "the current minute means now")
        XCTAssertEqual(command(.unknown), .notUnderstood)
    }

    func testStartAndEnd() {
        let d = draft(entry("2026-09-24", start: "08:30", end: "12:00", note: " code review "))
        XCTAssertEqual(d?.date, day(9, 24))
        XCTAssertEqual(d?.start, time(day(9, 24), 8, 30))
        XCTAssertEqual(d?.end, time(day(9, 24), 12))
        XCTAssertEqual(d?.project, "Alpha")
        XCTAssertEqual(d?.note, "code review")
    }

    func testDurations() {
        XCTAssertEqual(draft(entry(start: "09:00", minutes: 90))?.end, time(day(9, 25), 10, 30))
        XCTAssertEqual(draft(entry(end: "12:00", minutes: 30))?.start, time(day(9, 25), 11, 30))
        let onlyDuration = draft(entry(minutes: 120))
        XCTAssertEqual(onlyDuration?.start, time(day(9, 25), 13), "starts after the day's last entry")
        XCTAssertEqual(onlyDuration?.end, time(day(9, 25), 15))
    }

    func testMissingEnd() {
        XCTAssertEqual(draft(entry(start: "14:00"))?.end, time(day(9, 25), 16, 40), "today: until now")
        XCTAssertEqual(draft(entry("2026-09-23", start: "14:00"))?.end, time(day(9, 23), 15), "other days: one hour")
        XCTAssertEqual(draft(entry(end: "11:00"))?.start, time(day(9, 25), 10), "next start after the end")
    }

    func testMidnightAndClamping() {
        XCTAssertEqual(draft(entry(start: "22:00", end: "00:00"))?.end, day(9, 26))
        XCTAssertEqual(draft(entry(start: "23:00", minutes: 120))?.end, day(9, 26), "never past midnight")
    }

    func testFallbacks() {
        XCTAssertEqual(draft(entry("yesterday", start: "08:00", end: "09:00"))?.date, day(9, 25), "bad day means today")
        XCTAssertEqual(VoiceCommand.day("2026-02-30"), nil)
        XCTAssertEqual(command(.log, entries: [entry()]), .notUnderstood, "no times at all")
        guard case .log(let drafts) = command(.log, project: "Beta", entries: [entry(start: "08:00", end: "09:00", project: nil)]) else {
            return XCTFail()
        }
        XCTAssertEqual(drafts.first?.project, "Beta")
    }

    func testNotesMustBeSpoken() {
        let said = "Heute von 13 bis 17 Uhr an Beta, Workshop vorbereitet"
        XCTAssertTrue(VoiceCommand.isSpokenNote("Workshop vorbereitet", transcript: said, project: "Beta"))
        XCTAssertFalse(VoiceCommand.isSpokenNote("von 13 bis 17 Uhr", transcript: said, project: "Beta"), "times")
        XCTAssertFalse(VoiceCommand.isSpokenNote("an Beta", transcript: said, project: "Beta"), "project")
        XCTAssertFalse(VoiceCommand.isSpokenNote("code review", transcript: said, project: "Beta"), "not said")
    }

    func testInstructionsListRecentDays() {
        let text = VoiceCommandParser(projects: ["Alpha", "Beta"]).instructions(now: now)
        XCTAssertTrue(text.contains("- 2026-09-25 (Friday, today)"))
        XCTAssertTrue(text.contains("- 2026-09-24 (Thursday, yesterday)"))
        XCTAssertTrue(text.contains("- 2026-09-12 (Saturday)"))
        XCTAssertTrue(text.contains("- Beta"))
    }
}

@MainActor
final class EntryAndTimerActionTests: XCTestCase {
    func testProblem() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let project = Project(name: "Alpha")
        context.insert(project)
        let existing = WorkSegment(date: day(9, 22), startTime: time(day(9, 22), 9), endTime: time(day(9, 22), 10), project: project)
        context.insert(existing)
        let d = day(9, 22)
        XCTAssertNil(EntryActions.problem(start: time(d, 10), end: time(d, 11), on: d, others: [existing]))
        XCTAssertNotNil(EntryActions.problem(start: time(d, 9, 30), end: time(d, 11), on: d, others: [existing]))
        XCTAssertNotNil(EntryActions.problem(start: time(d, 11), end: time(d, 10), on: d, others: []))
        XCTAssertNotNil(EntryActions.problem(start: time(d, 23), end: time(d.addingDays(1), 1), on: d, others: []))
        XCTAssertEqual(EntryActions.project(named: "alpha", in: context)?.name, "Alpha")
    }

    func testTimerActions() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let alpha = Project(name: "Alpha"), beta = Project(name: "Beta")
        context.insert(alpha)
        context.insert(beta)
        let defaults = UserDefaults(suiteName: "VoiceTimerTests-\(UUID().uuidString)")!
        let timer = WorkTimer(defaults: defaults)
        let d = day(9, 22)

        XCTAssertEqual(TimerActions.stop(at: time(d, 9), timer: timer, context: context), tr("No timer is running."))
        _ = TimerActions.start(alpha, at: time(d, 8), timer: timer, context: context)
        _ = TimerActions.start(beta, at: time(d, 9), timer: timer, context: context)
        XCTAssertEqual(timer.project(in: context)?.name, "Beta", "starting again switches projects")
        _ = TimerActions.stop(at: time(d, 10, 30), timer: timer, context: context)
        let segments = EntryActions.segments(on: d, in: context)
        XCTAssertEqual(segments.map { $0.project?.name }, ["Alpha", "Beta"])
        XCTAssertEqual(segments.map(\.durationHours), [1, 1.5])
        XCTAssertFalse(timer.isRunning)
    }
}

/// Runs sample sentences through the real on-device model. Opt-in (slow, needs Apple
/// Intelligence): `WORK_TRACKER_LIVE_MODEL=1 swift test --filter LiveVoiceModelTests`.
final class LiveVoiceModelTests: XCTestCase {
    func testSentences() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WORK_TRACKER_LIVE_MODEL"] == "1")
        try XCTSkipIf(VoiceCommandParser.unavailableReason != nil, VoiceCommandParser.unavailableReason ?? "")
        let now = time(day(9, 25), 16, 40)
        let parser = VoiceCommandParser(projects: ["Alpha", "Beta Relaunch", "Other"])
        let cases: [(String, (VoiceCommand) -> Bool)] = [
            ("Starting work on Alpha", { $0 == .startTimer(project: "Alpha", at: nil) }),
            ("Stopping work", { $0 == .stopTimer(at: nil) }),
            ("I started on Alpha at 8", { $0 == .startTimer(project: "Alpha", at: time(day(9, 25), 8)) }),
            ("Zwei Stunden Other, Mails", {
                guard case .log(let d) = $0, let e = d.first else { return false }
                return e.project == "Other" && e.end.timeIntervalSince(e.start) == 7200
            }),
            ("Ich beginne mit Beta Relaunch", { $0 == .startTimer(project: "Beta Relaunch", at: nil) }),
            ("Feierabend", { $0 == .stopTimer(at: nil) }),
            ("Yesterday from 8:30 to 12 on Alpha, code review", {
                guard case .log(let d) = $0, let e = d.first else { return false }
                return d.count == 1 && e.project == "Alpha" && e.start == time(day(9, 24), 8, 30) && e.end == time(day(9, 24), 12)
            }),
            ("Heute von 13 bis 17 Uhr an Beta Relaunch", {
                guard case .log(let d) = $0, let e = d.first else { return false }
                return e.project == "Beta Relaunch" && e.start == time(day(9, 25), 13) && e.end == time(day(9, 25), 17)
                    && !e.note.contains("13")
            }),
            ("Today 8 to 12 on Alpha and then 13 to 17 on Beta Relaunch", {
                guard case .log(let d) = $0 else { return false }
                return d.map(\.project) == ["Alpha", "Beta Relaunch"] && d.last?.end == time(day(9, 25), 17)
            }),
        ]
        var failures: [String] = []
        for (sentence, check) in cases {
            let spoken = try await parser.parse(sentence, now: now)
            let command = VoiceCommand(spoken, transcript: sentence, now: now) { time($0, 8, 10) }
            print("🎙 \(sentence) → \(spoken) → \(command)")
            if !check(command) { failures.append(sentence) }
        }
        XCTAssertEqual(failures, [])
    }
}
