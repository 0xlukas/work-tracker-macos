import Foundation

/// Shared formatting for hours and day counts, so every view renders durations the
/// same way. Rounds to whole minutes (so 7.999h shows as 8h 00m, not 7h 60m).
enum TimeFormatting {
    /// e.g. `8h 05m`. Pass a non-negative magnitude (callers use `abs` for balances).
    static func hours(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        return String(format: "%dh %02dm", totalMinutes / 60, abs(totalMinutes % 60))
    }

    /// e.g. `+2h 30m` / `-0h 45m`.
    static func signedHours(_ hours: Double) -> String {
        let rounded = (hours * 60).rounded()
        return (rounded < 0 ? "-" : "+") + Self.hours(abs(hours))
    }

    /// e.g. `8h` or `8:05` — compact for tight rows.
    static func hoursCompact(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = abs(totalMinutes % 60)
        return m == 0 ? "\(h)h" : String(format: "%d:%02d", h, m)
    }

    /// e.g. `1` or `1.5` — whole numbers stay integers, halves get one decimal.
    static func days(_ days: Double) -> String {
        days == days.rounded() ? "\(Int(days))" : days.formatted(.number.precision(.fractionLength(1)).locale(Localization.locale))
    }

    /// e.g. `1 day` / `2.5 days`.
    static func dayCount(_ value: Double) -> String {
        value == 1 ? tr("1 day") : tr("%@ days", days(value))
    }

    /// e.g. `1:30` for elapsed timers.
    static func clock(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Parse a signed duration: `12:30`, `-4:15`, `7.5`, `-2,25`, `+3`. Returns hours.
    static func parseSignedHours(_ input: String) -> Double? {
        var text = input.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        if let first = text.first, first == "-" || first == "−" || first == "+" {
            if first != "+" { sign = -1 }
            text.removeFirst()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h >= 0, (0..<60).contains(m) else { return nil }
            return sign * (Double(h) + Double(m) / 60)
        }
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return nil }
        return sign * value
    }

    /// Inverse of `parseSignedHours`, e.g. `+12:30`.
    static func signedClock(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return String(format: "%@%d:%02d", minutes < 0 ? "-" : "", abs(minutes) / 60, abs(minutes) % 60)
    }
}
