import SwiftUI

extension View {
    /// How a notice over an email's body looks: quiet text on a tinted strip.
    func messageNotice() -> some View {
        font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
