import Foundation
import Observation

/// Separator and number format for CSV exports.
enum CSVFormat: String, CaseIterable, Identifiable {
    /// Comma separator, decimal point.
    case standard
    /// Semicolon separator, decimal comma — what German-locale Excel expects.
    case excelGerman

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return tr("Comma-separated (standard)")
        case .excelGerman: return tr("Semicolon-separated (Excel, German)")
        }
    }
}

/// Vacation allowance settings used by the calculator.
struct VacationAllowance: Equatable {
    /// Days per calendar year.
    var entitlement: Double = 25
    /// Carry unused days into the following year.
    var carryOver: Bool = false
    /// Days carried into the year tracking starts in (from before the app was used).
    var openingCarryOver: Double = 0
    /// Year tracking starts in; `openingCarryOver` applies to it.
    var startYear: Int = Date().zurichYear
}

/// User preferences, stored in `UserDefaults` and observable, so every screen and the
/// Settings window update the moment a value changes.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let trackingStartDate = "trackingStartDate"
        static let vacationEntitlement = "vacationEntitlementDays"
        static let carryOverVacation = "carryOverVacation"
        static let openingVacationCarryOver = "openingVacationCarryOver"
        static let openingBalanceHours = "openingBalanceHours"
        static let workSchedule = "workSchedule"
        static let fullTimeWeeklyHours = "fullTimeWeeklyHours"
        static let dailyQuoteEnabled = "dailyQuoteEnabled"
        static let lastQuoteShownDate = "lastQuoteShownDate"
        static let csvFormat = "csvFormat"
        static let backupMirrorDirectory = "backupMirrorDirectory"
        static let calendarSyncEnabled = "calendarSyncEnabled"
        static let absenceCalendarID = "absenceCalendarID"
        static let callTrackingEnabled = "callTrackingEnabled"
        static let callShortcut = "callShortcut"
        static let callDepartments = "callDepartments"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let date = defaults.object(forKey: Key.trackingStartDate) as? Date {
            trackingStartDate = date.startOfDayZurich
        } else {
            // First launch: pin the start to today. Leaving it unset made the tracking
            // window restart every day.
            let today = Date().startOfDayZurich
            trackingStartDate = today
            defaults.set(today, forKey: Key.trackingStartDate)
        }
        vacationEntitlement = defaults.object(forKey: Key.vacationEntitlement) as? Double ?? 25
        carryOverVacation = defaults.bool(forKey: Key.carryOverVacation)
        openingVacationCarryOver = defaults.double(forKey: Key.openingVacationCarryOver)
        openingBalanceHours = defaults.double(forKey: Key.openingBalanceHours)
        fullTimeWeeklyHours = defaults.object(forKey: Key.fullTimeWeeklyHours) as? Double ?? 40
        schedule = defaults.data(forKey: Key.workSchedule)
            .flatMap { try? JSONDecoder().decode(WorkSchedule.self, from: $0) } ?? .standard
        dailyQuoteEnabled = defaults.object(forKey: Key.dailyQuoteEnabled) as? Bool ?? true
        lastQuoteShownDate = defaults.object(forKey: Key.lastQuoteShownDate) as? Date
        csvFormat = defaults.string(forKey: Key.csvFormat).flatMap(CSVFormat.init(rawValue:)) ?? .standard
        backupMirrorDirectory = defaults.string(forKey: Key.backupMirrorDirectory).map { URL(fileURLWithPath: $0) }
        calendarSyncEnabled = defaults.bool(forKey: Key.calendarSyncEnabled)
        absenceCalendarID = defaults.string(forKey: Key.absenceCalendarID)
        callTrackingEnabled = defaults.bool(forKey: Key.callTrackingEnabled)
        callShortcut = defaults.string(forKey: Key.callShortcut).flatMap(CallShortcut.init(rawValue:)) ?? .controlOptionC
        callDepartments = defaults.stringArray(forKey: Key.callDepartments) ?? []
        language = Localization.current
    }

    var trackingStartDate: Date {
        didSet {
            let day = trackingStartDate.startOfDayZurich
            if day != trackingStartDate { trackingStartDate = day; return }
            defaults.set(day, forKey: Key.trackingStartDate)
        }
    }

    var vacationEntitlement: Double { didSet { defaults.set(vacationEntitlement, forKey: Key.vacationEntitlement) } }
    var carryOverVacation: Bool { didSet { defaults.set(carryOverVacation, forKey: Key.carryOverVacation) } }
    var openingVacationCarryOver: Double {
        didSet { defaults.set(openingVacationCarryOver, forKey: Key.openingVacationCarryOver) }
    }
    /// Overtime (+) or undertime (−) brought in from before tracking started.
    var openingBalanceHours: Double { didSet { defaults.set(openingBalanceHours, forKey: Key.openingBalanceHours) } }
    /// Reference week for the workload percentage.
    var fullTimeWeeklyHours: Double { didSet { defaults.set(fullTimeWeeklyHours, forKey: Key.fullTimeWeeklyHours) } }

    var schedule: WorkSchedule {
        didSet { defaults.set(try? JSONEncoder().encode(schedule), forKey: Key.workSchedule) }
    }

    var dailyQuoteEnabled: Bool { didSet { defaults.set(dailyQuoteEnabled, forKey: Key.dailyQuoteEnabled) } }
    var lastQuoteShownDate: Date? { didSet { defaults.set(lastQuoteShownDate, forKey: Key.lastQuoteShownDate) } }

    var shouldShowDailyQuote: Bool {
        guard dailyQuoteEnabled else { return false }
        guard let lastShown = lastQuoteShownDate else { return true }
        return !lastShown.isSameDay(as: Date())
    }

    var csvFormat: CSVFormat { didSet { defaults.set(csvFormat.rawValue, forKey: Key.csvFormat) } }

    /// Optional second folder (e.g. a cloud drive) that receives a copy of every backup.
    var backupMirrorDirectory: URL? {
        didSet { defaults.set(backupMirrorDirectory?.path, forKey: Key.backupMirrorDirectory) }
    }

    /// Mirror absences into the Work Tracker calendar (see `CalendarSync`).
    var calendarSyncEnabled: Bool { didSet { defaults.set(calendarSyncEnabled, forKey: Key.calendarSyncEnabled) } }
    /// EventKit identifier of the Work Tracker calendar once it exists.
    var absenceCalendarID: String? { didSet { defaults.set(absenceCalendarID, forKey: Key.absenceCalendarID) } }

    /// Calls in the sidebar, the menu bar and the call shortcut (see `CallControl`). Per
    /// Mac; the calls themselves sync.
    var callTrackingEnabled: Bool { didSet { defaults.set(callTrackingEnabled, forKey: Key.callTrackingEnabled) } }
    var callShortcut: CallShortcut { didSet { defaults.set(callShortcut.rawValue, forKey: Key.callShortcut) } }
    /// The departments a call can be logged for, in the order shown. Syncs.
    var callDepartments: [String] { didSet { defaults.set(callDepartments, forKey: Key.callDepartments) } }

    var language: AppLanguage { didSet { Localization.current = language } }

    var allowance: VacationAllowance {
        VacationAllowance(entitlement: vacationEntitlement, carryOver: carryOverVacation,
                          openingCarryOver: openingVacationCarryOver, startYear: trackingStartDate.zurichYear)
    }

    /// A calculator for the current schedule and allowance over the given absences.
    func calculator(absences: [Date: AbsenceEntry]) -> WorkHoursCalculator {
        WorkHoursCalculator(absences: absences, schedule: schedule, allowance: allowance)
    }
}
