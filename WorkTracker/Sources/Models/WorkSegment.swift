import Foundation
import SwiftData

@Model
final class WorkSegment {
    var date: Date
    var startTime: Date
    var endTime: Date
    var durationHours: Double
    var project: Project?
    var note: String = ""
    /// The same entry on every Mac (see `DeviceSync`).
    var syncID: UUID?

    init(date: Date, startTime: Date, endTime: Date, project: Project?, note: String = "") {
        self.date = Calendar.zurich.startOfDay(for: date)
        self.startTime = startTime
        self.endTime = endTime
        self.durationHours = endTime.timeIntervalSince(startTime) / 3600.0
        self.project = project
        self.note = note
        self.syncID = UUID()
    }

    func recalculateDuration() {
        durationHours = endTime.timeIntervalSince(startTime) / 3600.0
    }

    /// Worked hours per Zurich day.
    static func hoursByDay(_ segments: [WorkSegment]) -> [Date: Double] {
        var result: [Date: Double] = [:]
        for segment in segments {
            result[segment.date.startOfDayZurich, default: 0] += segment.durationHours
        }
        return result
    }
}
