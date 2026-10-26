import Foundation
import FoundationModels

/// Turns a transcript into a `SpokenCommand` with the on-device Apple Intelligence model.
struct VoiceCommandParser {
    /// Active project names, so the model picks one of them.
    let projects: [String]

    /// Why voice commands can't be used right now, or nil when they can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(Localization.locale)
                ? nil : tr("Apple Intelligence doesn’t support this language yet.")
        case .unavailable(.deviceNotEligible):
            return tr("This Mac doesn’t support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return tr("Turn on Apple Intelligence in System Settings to use voice entry.")
        case .unavailable(.modelNotReady):
            return tr("Apple Intelligence is still getting ready. Try again in a few minutes.")
        case .unavailable:
            return tr("Apple Intelligence isn’t available right now.")
        }
    }

    func parse(_ transcript: String, now: Date = Date()) async throws -> SpokenCommand {
        let session = LanguageModelSession(instructions: instructions(now: now))
        let response = try await session.respond(to: transcript, generating: SpokenCommand.self,
                                                 options: GenerationOptions(samplingMode: .greedy))
        return response.content
    }

    /// The model can't do date arithmetic reliably, so it gets a table of recent days to
    /// copy from instead of computing "last Tuesday" itself.
    func instructions(now: Date) -> String {
        var weekday = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), calendar: .zurich, timeZone: .zurich)
            .weekday(.wide)
        weekday.timeZone = .zurich
        let today = now.startOfDayZurich
        let days = (0..<14).map { offset -> String in
            let day = today.addingDays(-offset)
            let label = offset == 0 ? ", today" : offset == 1 ? ", yesterday" : ""
            return "- \(Self.isoDay(day)) (\(day.formatted(weekday))\(label))"
        }
        return """
        You turn one spoken sentence from the user of a time-tracking app into a command. \
        The sentence may be in English or German.

        Actions:
        - startTimer: the user starts working now, e.g. "starting work on Alpha", "start Alpha", \
        "ich beginne mit Alpha", "ich fange mit Alpha an".
        - stopTimer: the user stops working, e.g. "stopping work", "stop the timer", "Feierabend", \
        "ich höre auf".
        - log: the user reports work already done with times or a duration, e.g. "yesterday from 8 \
        to 12 on Alpha", "heute zwei Stunden Beta, Meeting".
        - unknown: anything else.

        Times are 24-hour HH:mm. "half past eight" is 08:30; in German "halb neun" is 08:30 and \
        "Viertel nach drei" is 15:15 during working hours. When morning or afternoon isn't said, \
        pick the time between 06:00 and 20:00. "Noon" or "Mittag" is 12:00; "midnight" is 24:00.

        Examples (with projects Apollo and Zephyr, today 2026-03-10, yesterday 2026-03-09):
        - "Starting work on Apollo" → startTimer, project Apollo, no time.
        - "Started Apollo at 8" → startTimer, project Apollo, time 08:00.
        - "Stopping work" → stopTimer, no time.
        - "Yesterday 8:30 to 12 on Zephyr, budget planning" → log, one entry: day 2026-03-09, \
        start 08:30, end 12:00, project Zephyr, note "budget planning".
        - "Heute von 13 bis 17 Uhr an Zephyr" → log, one entry: day 2026-03-10, start 13:00, \
        end 17:00, project Zephyr, no note.
        - "Drei Stunden Apollo, Workshop" → log, one entry: day 2026-03-10, minutes 180, \
        project Apollo, note "Workshop".
        Only set minutes when a duration is said. A note only contains words the user said about \
        the work itself, never times, days, durations or the project.

        Days (the current time is \(TimeField.format(now))):
        \(days.joined(separator: "\n"))
        Without a day, use today.

        Projects:
        \(projects.map { "- \($0)" }.joined(separator: "\n"))
        Only use a project from this list, written exactly as listed.
        """
    }

    static func isoDay(_ date: Date) -> String {
        let c = Calendar.zurich.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
