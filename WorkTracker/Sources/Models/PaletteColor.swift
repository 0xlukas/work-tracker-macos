import SwiftUI
import AppKit

/// Shared colour palette for projects and absence categories. Raw values are persisted,
/// and the case order matches the palette projects were coloured from before V4.
enum PaletteColor: String, CaseIterable, Codable {
    case blue, green, orange, purple, pink, teal, indigo, red, mint, cyan

    var nsColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .teal: return .systemTeal
        case .indigo: return .systemIndigo
        case .red: return .systemRed
        case .mint: return .systemMint
        case .cyan: return .systemCyan
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var title: String { tr(rawValue.capitalized) }
}
