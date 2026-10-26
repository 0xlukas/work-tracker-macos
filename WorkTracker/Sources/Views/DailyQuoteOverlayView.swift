import SwiftUI
import AppKit

struct DailyQuoteOverlayView: View {
    let quote: DailyQuote
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Dim the workspace; the quote floats above it on a Liquid Glass slab.
            Rectangle()
                .fill(.black.opacity(0.78))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                // Red star accent
                Image(systemName: "star.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red.opacity(0.75))
                    .padding(.bottom, 28)
                    .accessibilityHidden(true)

                // Quote
                Text("\u{201C}\(quote.text)\u{201D}")
                    .font(.system(.title, design: .serif).weight(.light))
                    .italic()
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(8)

                // Attribution
                VStack(spacing: 4) {
                    Text("— \(quote.thinker)")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(.white.opacity(0.85))

                    if let source = quote.source {
                        Text(source)
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 44)
            .frame(maxWidth: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .contentShape(.rect(cornerRadius: 28))
            .onTapGesture(perform: onDismiss)
            .padding(48)

            // Dismiss hint (not hit-testable, so clicks reach the backdrop)
            VStack {
                Spacer()
                Text(tr("Press any key, or click anywhere, to start your day"))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 28)
            }
            .allowsHitTesting(false)

            // Visible, accessible close affordance (Escape and any-key also dismiss).
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)   // Escape
                    .help(tr("Dismiss (Esc)"))
                    .accessibilityLabel(tr("Dismiss quote"))
                    .padding(20)
                }
                Spacer()
            }

            // Invisible key capture (any key dismisses)
            KeyCaptureRepresentable(onEvent: onDismiss)
                .frame(width: 0, height: 0)
        }
    }
}

// MARK: - Key & Mouse Capture

private struct KeyCaptureRepresentable: NSViewRepresentable {
    var onEvent: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onEvent = onEvent
    }
}

final class KeyCaptureNSView: NSView {
    var onEvent: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        onEvent?()
    }

}
