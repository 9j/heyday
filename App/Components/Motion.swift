import SwiftUI

/// The app's motions, named for what moves. Every animation is one of these, so the
/// app speeds up, slows down or goes still as a whole, and nothing moves at a pace
/// of its own.
enum Motion {
    /// A control answering a touch: a dot going out, a symbol changing, a count ticking.
    static let response = Animation.snappy(duration: 0.24)
    /// Things changing size or place: a row leaving a list, a message unfolding.
    static let layout = Animation.smooth(duration: 0.36)
    /// Something coming on screen or leaving it: a notice, a banner, a toast.
    static let arrival = Animation.spring(duration: 0.44, bounce: 0.14)
    /// What each of those becomes for someone who asked for less motion: a short fade,
    /// with nothing travelling.
    static let reduced = Animation.easeOut(duration: 0.16)

    /// The animation to use when starting one in code, as `withAnimation` does.
    static func chosen(_ animation: Animation, reducing reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

extension View {
    /// Animates whatever changes with `value`. With Reduce Motion on, the change
    /// fades in place instead.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.chosen(animation, reducing: reduceMotion), value: value)
    }
}

// MARK: - Transitions

/// Comes on screen by fading in while settling into place from a little below, and
/// leaves the same way. With Reduce Motion on, it only fades.
struct SettleTransition: Transition {
    /// How far from its place the view starts, in points. Negative starts above.
    var distance: CGFloat = 8

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(Settle(isInPlace: phase.isIdentity, distance: distance))
    }
}

private struct Settle: ViewModifier {
    let isInPlace: Bool
    let distance: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isInPlace ? 1 : 0)
            .offset(y: isInPlace || reduceMotion ? 0 : distance)
    }
}

extension Transition where Self == SettleTransition {
    /// Rises into place.
    static var settle: SettleTransition { SettleTransition() }
    /// Drops into place, for something that hangs from the top of the screen.
    static var settleFromAbove: SettleTransition { SettleTransition(distance: -8) }
}

// MARK: - Pressing

/// A control drawn by the app that gives a little under the finger or the pointer.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Motion.response, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
