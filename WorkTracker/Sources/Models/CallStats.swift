import Foundation

/// Statistics over calls for the Calls screen and the exports: how they spread over time,
/// over the week and the day, and which questions come back.
enum CallStats {
    /// How a chart over time groups calls, depending on how long the period is.
    enum Bucket: Equatable {
        case day, week, month

        /// Days for up to a month, weeks for up to half a year, months beyond.
        static func forSpan(from: Date, to: Date) -> Bucket {
            let days = (Calendar.zurich.dateComponents([.day], from: from.startOfDayZurich, to: to.startOfDayZurich).day ?? 0) + 1
            return days <= 31 ? .day : days <= 183 ? .week : .month
        }

        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            }
        }

        /// The start of the bucket `date` falls in (Zurich midnight; weeks start on Monday).
        func start(of date: Date) -> Date {
            switch self {
            case .day: return date.startOfDayZurich
            case .week: return date.startOfWeekZurich
            case .month:
                return Calendar.zurich.date(from: Calendar.zurich.dateComponents([.year, .month], from: date))!
            }
        }
    }

    /// Calls of one length in one bucket, for a stacked bar chart.
    struct Bar: Identifiable, Equatable {
        let start: Date
        let length: CallLength
        let count: Int

        var id: String { "\(start.timeIntervalSinceReferenceDate)-\(length.rawValue)" }
    }

    /// Calls per bucket and length, oldest first; buckets without calls are left out.
    static func timeline(_ calls: [PhoneCall], bucket: Bucket) -> [Bar] {
        var counts: [Date: [CallLength: Int]] = [:]
        for call in calls { counts[bucket.start(of: call.date), default: [:]][call.length, default: 0] += 1 }
        return counts.keys.sorted().flatMap { start in
            CallLength.allCases.compactMap { length in
                counts[start]?[length].map { Bar(start: start, length: length, count: $0) }
            }
        }
    }

    /// Calls per weekday, Monday first.
    static func byWeekday(_ calls: [PhoneCall]) -> [Int] {
        var counts = Array(repeating: 0, count: 7)
        for call in calls { counts[call.date.mondayBasedWeekday] += 1 }
        return counts
    }

    /// Calls per hour of the day (Zurich time), 0 to 23.
    static func byHour(_ calls: [PhoneCall]) -> [Int] {
        var counts = Array(repeating: 0, count: 24)
        for call in calls { counts[Calendar.zurich.component(.hour, from: call.date)] += 1 }
        return counts
    }

    /// A caller asking about the same topic again and again: worth a document or a training.
    struct Recurring: Identifiable, Equatable {
        let caller: String
        let topic: String
        var calls: Int
        var estimatedMinutes: Double
        var last: Date

        var id: String { CallNames.key(caller) + "\u{1F}" + CallNames.key(topic) }
    }

    /// Caller and topic pairs with at least `minimum` calls, the most calls first (ties: the
    /// most recent first). Names differing only in case or accents count as one, shown with
    /// the latest spelling.
    static func recurring(_ calls: [PhoneCall], minimum: Int = 2, limit: Int = 5) -> [Recurring] {
        var pairs: [String: Recurring] = [:]
        for call in calls.sorted(by: { $0.date > $1.date }) where !call.topic.isEmpty {
            let key = CallNames.key(call.caller) + "\u{1F}" + CallNames.key(call.topic)
            if pairs[key] == nil {
                pairs[key] = Recurring(caller: call.caller, topic: call.topic, calls: 0, estimatedMinutes: 0, last: call.date)
            }
            pairs[key]!.calls += 1
            pairs[key]!.estimatedMinutes += call.length.estimatedMinutes
        }
        return pairs.values
            .filter { $0.calls >= minimum }
            .sorted { ($0.calls, $0.last) > ($1.calls, $1.last) }
            .prefix(limit)
            .map { $0 }
    }

    /// e.g. "≈ 2h 15m".
    static func formatEstimate(minutes: Double) -> String {
        "≈ " + TimeFormatting.hours(minutes / 60)
    }
}
