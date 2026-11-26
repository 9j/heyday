import SwiftUI

/// A grey bar standing where a line of text will be, while what it says is fetched.
struct PlaceholderBar: View {
    /// The longest the bar gets. Nil takes all the width on offer.
    var width: CGFloat?
    var height: CGFloat = 10

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(maxWidth: width ?? .infinity)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A band of light crossing the view again and again: how a placeholder says the
    /// real thing is on its way. With Reduce Motion on, the view stays still.
    func shimmering() -> some View {
        modifier(Shimmer())
    }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasCrossed = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .mask {
                    GeometryReader { proxy in
                        // Three widths of gradient, bright in the middle third, slid
                        // from its right third to its left across the view.
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.45), location: 0.35),
                                .init(color: .black, location: 0.5),
                                .init(color: .black.opacity(0.45), location: 0.65),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 3)
                        .offset(x: (hasCrossed ? 0 : -2) * proxy.size.width)
                    }
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        hasCrossed = true
                    }
                }
        }
    }
}

/// A spinner for a wait of unknown length, which keeps out of sight for the first
/// moment: most waits here are over before it would have been seen, and one that
/// flashes by reads as a glitch.
struct WaitingIndicator: View {
    /// Said beside the spinner, once it shows.
    var label: String?

    @State private var isShown = false

    var body: some View {
        Group {
            if let label {
                ProgressView(label)
            } else {
                ProgressView()
            }
        }
        .opacity(isShown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(Motion.reduced) { isShown = true }
        }
    }
}
