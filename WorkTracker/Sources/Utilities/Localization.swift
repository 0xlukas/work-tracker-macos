import Foundation

/// UI language. `.system` follows the macOS language; the others force a language
/// regardless of system settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case de

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return tr("System")
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }
}

/// Tiny localization layer over the String Catalog (`Localizable.xcstrings`) in the
/// package's resource bundle. The English source text is the lookup key, so a missing
/// translation falls back to English. Plural keys (`%lld …`) use the catalog's plural
/// variations.
enum Localization {
    static let storageKey = "appLanguage"

    static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// Strings ship in the packaged app under `Contents/Resources/<lang>.lproj`
    /// (`Bundle.main`); when running from `swift run`/tests they live in the SwiftPM
    /// resource bundle (`Bundle.module`). Prefer whichever actually has them.
    private static var baseBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.main.path(forResource: "de", ofType: "lproj") != nil ? .main : .module
        #else
        // Xcode app target: the catalog is compiled straight into the app bundle.
        .main
        #endif
    }

    /// The language actually shown: the forced one, or the best system match.
    static var effectiveLanguageCode: String {
        switch current {
        case .en: return "en"
        case .de: return "de"
        case .system:
            return Bundle.preferredLocalizations(from: ["en", "de"], forPreferences: Locale.preferredLanguages).first ?? "en"
        }
    }

    /// Locale for dates and numbers: the UI language with the user's region, so
    /// month and weekday names match the UI language — also when the system language
    /// is one the app isn't translated into (the UI then falls back to English).
    static var locale: Locale {
        let system = Locale.autoupdatingCurrent
        if current == .system, system.language.languageCode?.identifier == effectiveLanguageCode { return system }
        let region = system.region?.identifier ?? "CH"
        return Locale(identifier: "\(effectiveLanguageCode)_\(region)")
    }

    private static func bundle(for code: String) -> Bundle {
        let base = baseBundle
        if let path = base.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        return base
    }

    static func string(_ key: String) -> String {
        let bundle = current == .system ? baseBundle : bundle(for: effectiveLanguageCode)
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Every translation of `key`, for matching user input against built-in names in
    /// any language.
    static func allTranslations(of key: String) -> Set<String> {
        Set(["en", "de"].map { bundle(for: $0).localizedString(forKey: key, value: key, table: nil) } + [key])
    }
}

/// Localize a UI string. The key is the English source text.
func tr(_ key: String) -> String {
    Localization.string(key)
}

/// Localize a format string and substitute arguments (e.g. `tr("of %@ expected", h)`).
/// Integer arguments pick the catalog's plural variation.
func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localization.string(key), locale: Localization.locale, arguments: args)
}
