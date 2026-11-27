import HeydayKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Heyday's Dawn palette, derived directly from the app icon's sunrise gradient
/// (amethyst violet → warm coral-rose → sunset tangerine → rising sun gold).
/// Used consistently across accents, semantic box icons, dividers, and badges so
/// the entire app feels native to Apple platforms yet unmistakably Heyday.
enum HeydayTheme {
    /// Primary brand accent — matches `AccentColor.colorset` (`#E0466B` light / `#FF6482` dark).
    static let rose = Color("AccentColor")

    /// Upper sunrise sky violet (`#944FED` light / `#B57DFF` dark).
    static let violet = adaptiveColor(
        light: (0.580, 0.310, 0.929),
        dark: (0.710, 0.490, 1.000)
    )

    /// Sunset horizon coral-tangerine (`#EE6A32` light / `#FF8552` dark).
    static let coral = adaptiveColor(
        light: (0.933, 0.416, 0.196),
        dark: (1.000, 0.522, 0.322)
    )

    /// Rising sun mascot gold (`#DF9B0E` light / `#FFD154` dark).
    static let sun = adaptiveColor(
        light: (0.875, 0.608, 0.055),
        dark: (1.000, 0.820, 0.329)
    )

    /// Diagonal sunrise gradient matching the app icon background.
    static var dawnGradient: LinearGradient {
        LinearGradient(
            colors: [violet, rose, coral],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Horizontal dawn gradient for section hairlines and dividers.
    static var horizonGradient: LinearGradient {
        LinearGradient(
            colors: [violet, rose, coral, sun],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Warm rising-sun gradient for Heyday's Bubble Up orb badge.
    static var sunOrbGradient: LinearGradient {
        LinearGradient(
            colors: [sun, coral, rose],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Harmonious semantic tint for each sidebar destination, or `nil` for plain
    /// server mailboxes so Heyday's core workflow boxes stand out cleanly.
    static func sidebarTint(for listing: Listing) -> Color? {
        switch listing {
        case .box(.mebox): rose
        case .box(.feed): violet
        case .box(.paperTrail): coral
        case .screener: sun
        case .screenedOut: nil
        case .appFolder(.replyLater): coral
        case .appFolder(.setAside): sun
        case .mailbox: nil
        }
    }

    /// Creates an adaptive color that responds immediately to Light and Dark appearances.
    static func adaptiveColor(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}

/// Compact Heyday app icon mark used on onboarding and welcome screens.
struct HeydayAppMark: View {
    var size: CGFloat = 52

    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: HeydayTheme.rose.opacity(0.22), radius: 8, y: 3)
            .accessibilityHidden(true)
        #else
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(HeydayTheme.dawnGradient)
            Circle()
                .fill(HeydayTheme.sun)
                .frame(width: size * 0.44, height: size * 0.44)
                .offset(y: -size * 0.04)
            Image(systemName: "envelope.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: size * 0.1)
        }
        .frame(width: size, height: size)
        .shadow(color: HeydayTheme.rose.opacity(0.24), radius: 8, y: 3)
        .accessibilityHidden(true)
        #endif
    }
}
