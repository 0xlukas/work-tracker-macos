import SwiftUI

/// Surface vocabulary for the macOS 26/27 (Liquid Glass) design language.
///
/// Glass belongs to the navigation layer — the window toolbar, sheet chrome and the
/// floating quote overlay — and the system draws it. Content underneath uses quiet,
/// adaptive fills with continuous corners so it reads as the "paper" beneath the
/// glass instead of competing with it.
enum Surface {
    /// Cards and grouped panels.
    static let cardRadius: CGFloat = 14
    /// List rows, hover highlights and small badges.
    static let rowRadius: CGFloat = 10
}

extension View {
    /// A quiet content card. Pass `tint` for semantic cards (balance, hints); the
    /// default is a neutral fill that adapts to light/dark and the system glass tint.
    func cardSurface(tint: Color? = nil, radius: CGFloat = Surface.cardRadius) -> some View {
        modifier(CardSurface(tint: tint, radius: radius))
    }

    /// Hover/selection highlight for custom list rows.
    func rowHighlight(_ isActive: Bool, tint: Color? = nil) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: Surface.rowRadius, style: .continuous)
            if isActive, let tint {
                shape.fill(tint.opacity(0.14))
            } else if isActive {
                shape.fill(.fill.quaternary)
            }
        }
    }
}

private struct CardSurface: ViewModifier {
    let tint: Color?
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .clipShape(shape)
            .background {
                if let tint {
                    shape.fill(tint.opacity(0.09))
                } else {
                    shape.fill(.fill.quaternary)
                }
            }
            .overlay {
                if let tint {
                    shape.strokeBorder(tint.opacity(0.18), lineWidth: 1)
                } else {
                    shape.strokeBorder(.separator.opacity(0.6), lineWidth: 1)
                }
            }
    }
}

/// Thin capsule meter for daily/weekly/monthly progress. `progress` is clamped to 0…1.
struct MeterBar: View {
    var progress: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                if fraction > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(geo.size.width * fraction, height))
                }
            }
        }
        .frame(height: height)
    }
}

/// Small tinted capsule label used for day badges and summary pills.
struct TintedPill: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Row of clickable colour swatches; the selected one carries a ring.
struct ColorSwatchPicker: View {
    @Binding var selection: PaletteColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PaletteColor.allCases, id: \.self) { color in
                let isSelected = color == selection
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                                .padding(-3)
                        }
                        .padding(3)
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
