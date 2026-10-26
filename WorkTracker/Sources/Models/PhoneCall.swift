import Foundation
import SwiftData

/// How long a call took, in three blocks: picked after the call, nothing is timed.
enum CallLength: String, CaseIterable, Identifiable, Sendable {
    /// Under 15 minutes.
    case short
    /// 15 minutes to an hour.
    case medium
    /// Over an hour.
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return tr("< 15 min")
        case .medium: return tr("< 1 h")
        case .long: return tr("> 1 h")
        }
    }

    /// What a call of this length counts for in time estimates: the middle of the block
    /// (an hour and a quarter for "over 1 hour"), since calls aren't timed.
    var estimatedMinutes: Double {
        switch self {
        case .short: return 7.5
        case .medium: return 37.5
        case .long: return 75
        }
    }

    /// Spelled out, for help tags, VoiceOver and exports.
    var detail: String {
        switch self {
        case .short: return tr("Under 15 minutes")
        case .medium: return tr("15 minutes to 1 hour")
        case .long: return tr("Over 1 hour")
        }
    }
}

/// A call: who called, what about, which department it concerned, roughly how long it
/// took and who solved the issue.
/// Calls sit beside the working time: they don't create time entries or change any
/// balance.
@Model
final class PhoneCall {
    /// When the call was logged, or the day and time it was set to afterwards.
    var date: Date
    /// A `CallLength`.
    var lengthRaw: String
    var caller: String
    var topic: String = ""
    /// One of the departments in Settings ▸ Calls (when the call was logged), or empty.
    var department: String = ""
    var note: String = ""
    /// The issue was solved by the person called (the user), not by the caller.
    var solvedByMe: Bool = false
    /// The same call on every Mac (see `DeviceSync`).
    var syncID: UUID?

    init(date: Date, length: CallLength, caller: String, topic: String = "", department: String = "",
         note: String = "", solvedByMe: Bool = false) {
        self.date = date
        self.lengthRaw = length.rawValue
        self.caller = caller
        self.topic = topic
        self.department = department
        self.note = note
        self.solvedByMe = solvedByMe
        self.syncID = UUID()
    }

    var length: CallLength {
        get { CallLength(rawValue: lengthRaw) ?? .short }
        set { lengthRaw = newValue.rawValue }
    }

    /// Calls on the days `from…to` (Zurich), oldest first.
    static func descriptor(from: Date, through to: Date) -> FetchDescriptor<PhoneCall> {
        let start = from.startOfDayZurich, end = to.startOfDayZurich.addingDays(1)
        return FetchDescriptor(predicate: #Predicate { $0.date >= start && $0.date < end },
                               sortBy: [SortDescriptor(\.date)])
    }
}

/// Caller and topic names. They are plain text: the same name typed with different case
/// or accents counts once, and new calls take the spelling used before.
enum CallNames {
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `name` trimmed, and written like the matching name in `known` if there is one.
    static func canonical(_ name: String, in known: [String]) -> String {
        let name = trimmed(name)
        return known.first { same($0, name) } ?? name
    }

    /// Distinct non-empty names, the most used first (ties: the most recent first).
    static func ranked(_ uses: [(name: String, at: Date)]) -> [String] {
        var stats: [String: (name: String, count: Int, last: Date)] = [:]
        for use in uses where !use.name.isEmpty {
            let key = key(use.name)
            if let existing = stats[key] {
                stats[key] = (existing.name, existing.count + 1, max(existing.last, use.at))
            } else {
                stats[key] = (use.name, 1, use.at)
            }
        }
        return stats.values.sorted { ($0.count, $0.last) > ($1.count, $1.last) }.map(\.name)
    }

    /// What someone said or typed for a name (Siri, Shortcuts): the known name when it
    /// is one, else the known names containing it followed by the text as a new name.
    static func matches(_ spoken: String, in known: [String]) -> [String] {
        let name = trimmed(spoken)
        guard !name.isEmpty else { return [] }
        if let match = known.first(where: { same($0, name) }) { return [match] }
        let partial = known.filter { $0.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return partial + [name]
    }

    /// Distinct non-empty names, the most recent first.
    static func recent(_ uses: [(name: String, at: Date)], limit: Int) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for use in uses.sorted(by: { $0.at > $1.at }) where !use.name.isEmpty && seen.insert(key(use.name)).inserted {
            result.append(use.name)
            if result.count == limit { break }
        }
        return result
    }
}

/// What the call panel and the call sheet suggest.
struct CallSuggestions {
    /// Every caller, the most frequent first.
    let callers: [String]
    /// The latest callers, for one-click buttons.
    let recentCallers: [String]
    /// Every topic, the most frequent first.
    let topics: [String]
    private let calls: [(caller: String, topic: String, department: String, at: Date)]

    init(calls: [PhoneCall]) {
        let rows = calls.map { (caller: $0.caller, topic: $0.topic, department: $0.department, at: $0.date) }
        self.calls = rows
        callers = CallNames.ranked(rows.map { ($0.caller, $0.at) })
        recentCallers = CallNames.recent(rows.map { ($0.caller, $0.at) }, limit: 3)
        topics = CallNames.ranked(rows.map { ($0.topic, $0.at) })
    }

    /// The topics this caller called about, the most frequent first.
    func topics(of caller: String) -> [String] {
        let name = CallNames.trimmed(caller)
        guard !name.isEmpty else { return [] }
        return CallNames.ranked(calls.filter { CallNames.same($0.caller, name) }.map { ($0.topic, $0.at) })
    }

    /// The department of this caller's latest call that had one.
    func department(of caller: String) -> String? {
        let name = CallNames.trimmed(caller)
        guard !name.isEmpty else { return nil }
        return calls.filter { CallNames.same($0.caller, name) && !$0.department.isEmpty }.max { $0.at < $1.at }?.department
    }

    /// The department to preselect for this caller: their usual one if it's still in
    /// the list, else none (empty).
    func department(of caller: String, among departments: [String]) -> String {
        department(of: caller).flatMap { usual in departments.first { $0 == usual } } ?? ""
    }

    /// Every topic, this caller's first.
    func topicList(for caller: String) -> [String] {
        let own = topics(of: caller)
        let ownKeys = Set(own.map(CallNames.key))
        return own + topics.filter { !ownKeys.contains(CallNames.key($0)) }
    }

    /// The most recent calls, which is all the suggestions need.
    static var source: FetchDescriptor<PhoneCall> {
        var descriptor = FetchDescriptor<PhoneCall>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 2000
        return descriptor
    }
}

/// Calls counted per block, for one caller, one topic or a whole period.
struct CallGroup: Identifiable, Equatable {
    /// Empty for calls without a topic (or department).
    let name: String
    var counts: [CallLength: Int] = [:]
    /// Calls whose issue the user solved.
    var solvedByMe = 0

    var id: String { CallNames.key(name) }
    var count: Int { counts.values.reduce(0, +) }
    func count(_ length: CallLength) -> Int { counts[length] ?? 0 }
    /// Time on these calls, estimated from their lengths (see `CallLength.estimatedMinutes`).
    var estimatedMinutes: Double { counts.reduce(0) { $0 + $1.key.estimatedMinutes * Double($1.value) } }
    /// Share of the calls whose issue the user solved, or nil without calls.
    var solvedShare: Double? { count > 0 ? Double(solvedByMe) / Double(count) : nil }

    /// Most calls first, then the most long and medium ones.
    fileprivate var rank: [Int] { [count, count(.long), count(.medium)] }

    fileprivate mutating func add(_ call: PhoneCall) {
        counts[call.length, default: 0] += 1
        if call.solvedByMe { solvedByMe += 1 }
    }
}

enum CallReport {
    static func total(_ calls: [PhoneCall]) -> CallGroup {
        var group = CallGroup(name: "")
        for call in calls { group.add(call) }
        return group
    }

    static func byCaller(_ calls: [PhoneCall]) -> [CallGroup] { groups(calls, by: \.caller) }
    static func byTopic(_ calls: [PhoneCall]) -> [CallGroup] { groups(calls, by: \.topic) }
    static func byDepartment(_ calls: [PhoneCall]) -> [CallGroup] { groups(calls, by: \.department) }

    /// Most calls first; calls without a name last. Names that differ only in case or
    /// accents form one group, shown with the most recent spelling.
    static func groups(_ calls: [PhoneCall], by name: KeyPath<PhoneCall, String>) -> [CallGroup] {
        var groups: [String: CallGroup] = [:]
        for call in calls.sorted(by: { $0.date > $1.date }) {
            let value = call[keyPath: name]
            groups[CallNames.key(value), default: CallGroup(name: value)].add(call)
        }
        return groups.values.sorted { lhs, rhs in
            if lhs.name.isEmpty != rhs.name.isEmpty { return rhs.name.isEmpty }
            if lhs.rank != rhs.rank { return lhs.rank.lexicographicallyPrecedes(rhs.rank, by: >) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Saving and renaming calls, shared by the panel, the Calls screen and the assistant
/// tools.
@MainActor
enum CallLog {
    /// Save a call. Caller and topic take the spelling they had before.
    @discardableResult
    static func add(caller: String, topic: String, department: String = "", note: String = "", length: CallLength,
                    solvedByMe: Bool, at date: Date, context: ModelContext) -> PhoneCall {
        let known = (try? context.fetch(CallSuggestions.source)) ?? []
        let call = PhoneCall(date: date, length: length,
                             caller: CallNames.canonical(caller, in: known.map(\.caller)),
                             topic: CallNames.canonical(topic, in: known.map(\.topic)),
                             department: CallNames.trimmed(department),
                             note: CallNames.trimmed(note), solvedByMe: solvedByMe)
        context.insert(call)
        return call
    }

    /// What Siri says after logging a call.
    static func confirmation(_ call: PhoneCall) -> String {
        let solver = call.solvedByMe ? tr("solved by you") : tr("solved by the caller")
        return call.topic.isEmpty
            ? tr("Logged the call from %@ (%@, %@).", call.caller, call.length.detail, solver)
            : tr("Logged the call from %@ about %@ (%@, %@).", call.caller, call.topic, call.length.detail, solver)
    }

    /// Give every call of a caller (or about a topic, or for a department) a new name. A name that's already
    /// in use merges the two. Returns how many calls changed.
    @discardableResult
    static func rename(_ name: String, to newName: String, field: ReferenceWritableKeyPath<PhoneCall, String>,
                       context: ModelContext) -> Int {
        let calls = (try? context.fetch(FetchDescriptor<PhoneCall>())) ?? []
        let others = calls.filter { !CallNames.same($0[keyPath: field], name) }.map { $0[keyPath: field] }
        let target = CallNames.canonical(newName, in: others)
        var changed = 0
        for call in calls where CallNames.same(call[keyPath: field], name) && call[keyPath: field] != target {
            call[keyPath: field] = target
            changed += 1
        }
        return changed
    }
}
