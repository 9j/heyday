import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    /// What sits behind a window's content.
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// What text is written on: a card, a page, a field.
    static var textBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension Notification.Name {
    /// Posted when the app comes to the front.
    static var appBecameActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }
}

extension View {
    /// A button that reads as a link in running text.
    func linkStyled() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// A second line under the window's title. Only a Mac has a place for one that
    /// leaves the title alone: on iPhone a subtitle shrinks the large title of the
    /// list it is on, so one list would look unlike the next.
    func subtitled(_ subtitle: String) -> some View {
        #if os(macOS)
        navigationSubtitle(subtitle)
        #else
        self
        #endif
    }

    /// What floats over the content under it: the system's glass where it has
    /// glass, and before that a material with an edge and a little shadow.
    @ViewBuilder
    func floatingSurface(in shape: some Shape) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }

    /// A choice between two or three sentences, all of them in view.
    func choiceOfSentences() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.inline)
        #endif
    }
}
