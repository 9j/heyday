import Foundation

/// Whether an email chooses its own colours.
///
/// One that does was designed for the white page mail has always been read on, and
/// has to be shown on one: its dark text may sit on nothing at all. One that does
/// not is only words, and can take the colours of whatever it is shown in, which is
/// what lets a plain email be read light on dark.
public enum MailBodyColours {
    /// A colour or a background set anywhere in the HTML, as an attribute
    /// (`bgcolor="…"`, `<font color=…>`, the body tag's `text="…"` and `link="…"`)
    /// or in a style (`color: …`, `background-color: …`). Words that merely say
    /// "color:" in the email's text count too, as does a link with `text=` in its
    /// address: taking a plain email for a designed one only costs it the dark page.
    public static func areSet(in html: String) -> Bool {
        html.contains(/\b(?:bgcolor|background|color)\s*[:=]|\b(?:text|link|vlink|alink)\s*=/.ignoresCase())
    }
}
