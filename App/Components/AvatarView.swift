import HeydayKit
import SwiftUI

/// A correspondent's initials on a colour of their own. IMAP carries no pictures, so
/// every avatar is one of these.
struct AvatarView: View {
    let address: EmailAddress?
    var size: CGFloat = 32

    var body: some View {
        Text(initials)
            .font(.system(size: 0.4 * size, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .padding(0.12 * size)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }

    /// The first letters of the first two words of the name, or of the address.
    private var initials: String {
        let words = (address?.displayName ?? "?").split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }

    /// The same colour every time for the same address.
    private var color: Color {
        guard let key = address?.key else { return .gray }
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.colors[sum % Self.colors.count]
    }

    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown]
}
