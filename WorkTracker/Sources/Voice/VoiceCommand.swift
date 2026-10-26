import Foundation
import FoundationModels

// What the on-device model extracts from a spoken sentence (guided generation). Days and
// times stay strings here — the model copies them from the instructions — and are turned
// into dates by `VoiceCommand`, which is plain code and unit-tested. (The system model
// doesn't accept regex guides, so the formats are described and parsed leniently.)

@Generable
enum SpokenAction {
    /// "Starting work on Alpha", "Ich beginne mit Alpha".
    case startTimer
    /// "Stopping work", "Feierabend".
    case stopTimer
    /// Work already done: "Yesterday 8 to 12 on Alpha".
    case log
    case unknown
}

@Generable
struct SpokenEntry {
    @Guide(description: "The day of this block of work, copied from the list of days as yyyy-MM-dd.")
    var day: String

    @Guide(description: "Start time, 24-hour HH:mm. Omit when not said.")
    var start: String?

    @Guide(description: "End time, 24-hour HH:mm. Omit when not said.")
    var end: String?

    @Guide(description: "Length in minutes, only when a duration is said (\"two hours\", \"45 Minuten\").",
           .range(1...1440))
    var minutes: Int?

    @Guide(description: "Project name exactly as written in the list of projects. Omit when none is named.")
    var project: String?

    @Guide(description: "What was done, in the user's words and language, without days, times or the project name. Omit when nothing is said.")
    var note: String?
}

@Generable
struct SpokenCommand {
    @Guide(description: "What the user wants to do.")
    var action: SpokenAction

    @Guide(description: "For startTimer: the project name exactly as written in the list of projects. Omit when none is named.")
    var project: String?

    @Guide(description: "For startTimer and stopTimer: an explicitly said time, 24-hour HH:mm. Omit for “now”.")
    var time: String?

    @Guide(description: "For log: one entry per block of work. Empty for the other actions.", .maximumCount(8))
    var entries: [SpokenEntry]
}

/// A time entry understood from speech, shown in the entry sheet for confirmation.
struct EntryDraft: Identifiable, Equatable {
    let id = UUID()
    var date: Date
    var start: Date
    var end: Date
    var project: String?
    var note: String

    static func == (a: EntryDraft, b: EntryDraft) -> Bool {
        a.date == b.date && a.start == b.start && a.end == b.end && a.project == b.project && a.note == b.note
    }
}

enum VoiceCommand: Equatable {
    case log([EntryDraft])
    case startTimer(project: String?, at: Date?)
    case stopTimer(at: Date?)
    case notUnderstood

    /// Resolve the model's output against the clock. `nextStart` gives the start for an
    /// entry that only has a duration or an end (the end of the day's last entry).
    /// `transcript` is what was said; notes the model made up are dropped against it.
    init(_ spoken: SpokenCommand, transcript: String, now: Date, nextStart: (Date) -> Date) {
        switch spoken.action {
        case .startTimer:
            self = .startTimer(project: spoken.project, at: Self.pastTime(spoken.time, now: now))
        case .stopTimer:
            self = .stopTimer(at: Self.pastTime(spoken.time, now: now))
        case .log:
            let drafts = spoken.entries.compactMap {
                Self.draft($0, fallbackProject: spoken.project, now: now, nextStart: nextStart)
            }.map { draft in
                var draft = draft
                if !Self.isSpokenNote(draft.note, transcript: transcript, project: draft.project) { draft.note = "" }
                return draft
            }
            self = drafts.isEmpty ? .notUnderstood : .log(drafts)
        case .unknown:
            self = .notUnderstood
        }
    }

    /// A time said for starting or stopping the timer, today. Times in the future and the
    /// current minute (which the model tends to fill in) mean now (nil).
    static func pastTime(_ text: String?, now: Date) -> Date? {
        guard let text, let time = TimeField.parse(text, on: now.startOfDayZurich) else { return nil }
        return time < now.addingTimeInterval(-120) ? time : nil
    }

    /// The small model sometimes puts times in the note or borrows words from its
    /// instructions. Keep a note only when every word was said and it has no digits or
    /// project name.
    static func isSpokenNote(_ note: String, transcript: String, project: String?) -> Bool {
        let words = { (text: String) in
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let noteWords = words(note)
        guard !noteWords.isEmpty, !note.contains(where: \.isNumber) else { return false }
        if let project, note.range(of: project, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return false }
        return noteWords.isSubset(of: words(transcript))
    }

    static func day(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let date = Calendar.zurich.zurichDate(year: parts[0], month: parts[1], day: parts[2])
        // Reject dates the calendar rolled over (e.g. 2026-02-30).
        return Calendar.zurich.component(.day, from: date) == parts[2] ? date : nil
    }

    /// Fill in whatever the sentence left out: a start from the day's last entry, an end
    /// from the duration, or (for today) the current time.
    static func draft(_ entry: SpokenEntry, fallbackProject: String?, now: Date,
                      nextStart: (Date) -> Date) -> EntryDraft? {
        let day = day(entry.day) ?? now.startOfDayZurich
        let midnight = day.addingDays(1)
        var start = entry.start.flatMap { TimeField.parse($0, on: day) }
        var end = entry.end.flatMap { TimeField.parse($0, on: day, allowsEndOfDay: true) }
        let duration = entry.minutes.map { TimeInterval($0) * 60 }

        // "until midnight" comes back as 00:00.
        if let s = start, let e = end, e <= s, e == day { end = midnight }

        switch (start, end, duration) {
        case (_?, _?, _):
            break
        case (let s?, nil, let d?):
            end = s.addingTimeInterval(d)
        case (nil, let e?, let d?):
            start = e.addingTimeInterval(-d)
        case (let s?, nil, nil):
            let untilNow = day.isSameDay(as: now) && now > s
            end = untilNow ? now.roundedToMinute : s.addingTimeInterval(3600)
        case (nil, let e?, nil):
            let s = nextStart(day)
            start = s < e ? s : e.addingTimeInterval(-3600)
        case (nil, nil, let d?):
            start = nextStart(day)
            end = start!.addingTimeInterval(d)
        case (nil, nil, nil):
            return nil
        }
        guard let start, let end else { return nil }
        let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EntryDraft(date: day, start: max(start, day), end: min(end, midnight),
                          project: entry.project ?? fallbackProject, note: note)
    }
}
