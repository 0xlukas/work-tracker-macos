import XCTest
@testable import WorkTracker

final class LocalizationTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WorkTracker/Sources")
    }

    /// Every literal `tr("…")` key must have a German entry in the String Catalog.
    func testEveryKeyIsTranslated() throws {
        let catalogURL = sources.appendingPathComponent("Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: [String: Any]])

        let pattern = try NSRegularExpression(pattern: #"\btr\(\s*"((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(match.range(at: 1), in: text)!])
                    .replacingOccurrences(of: #"\""#, with: #"""#)
                let localizations = strings[key]?["localizations"] as? [String: Any]
                if localizations?["de"] == nil { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertEqual(missing, [], "Add these keys to Localizable.xcstrings")
    }

    func testPluralsAndLanguageSwitch() {
        let saved = Localization.current
        defer { Localization.current = saved }

        Localization.current = .en
        XCTAssertEqual(tr("%lld projects", 1), "1 project")
        XCTAssertEqual(tr("%lld projects", 3), "3 projects")
        XCTAssertEqual(tr("Copied %lld entries from %@; %lld skipped because they overlap.", 1, "Mon", 2),
                       "Copied 1 entry from Mon; 2 skipped because of overlaps.")

        Localization.current = .de
        XCTAssertEqual(tr("%lld entries", 1), "1 Eintrag")
        XCTAssertEqual(tr("%lld entries", 2), "2 Einträge")
        XCTAssertEqual(tr("Vacation"), "Ferien")
        XCTAssertEqual(Localization.locale.language.languageCode?.identifier, "de")
        XCTAssertTrue(Localization.allTranslations(of: "Vacation").isSuperset(of: ["Vacation", "Ferien"]))
    }
}
