import Foundation

/// A remote image the sender put in an email. The page never fetches it: the app
/// does, and puts it in the page afterwards.
public struct HeldImage: Equatable, Sendable {
    /// Where to fetch it: the sender's address with its tracking parameters taken off.
    public let url: URL
    /// Whether the address looks the same for every recipient, so that fetching it
    /// says nothing about who did. Such an image may be fetched without asking; any
    /// other waits to be asked for.
    public let looksShared: Bool
    /// The sender's own `<img>` tag, kept so the image can be shown as they laid it out.
    let tag: HTMLTag

    /// The sender's tag with the fetched image in place of the remote address.
    public func html(showing image: RemoteImage) -> String {
        var tag = tag
        // Nothing may send the web view back to the network, or run on a click.
        tag.attributes.removeAll { ["srcset", "sizes", "loading"].contains($0.name) || $0.name.hasPrefix("on") }
        tag.set("src", to: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())")
        return tag.html
    }
}

/// What was found in an email's HTML and done about it.
public struct PrivacyReport: Equatable, Sendable {
    /// Images taken out because they exist to report that the email was opened.
    public var pixels: [MailTracker] = []
    /// Links left going through a click tracker, because only the tracker knows
    /// where they lead. One entry per link.
    public var trackedLinks: [MailTracker] = []
    /// Links whose tracking was taken off: unwrapped from a redirect, or stripped of
    /// tracking parameters.
    public var cleanedLinks = 0

    public init() {}

    public var isEmpty: Bool { pixels.isEmpty && trackedLinks.isEmpty && cleanedLinks == 0 }
}

/// An email body with its trackers dealt with.
public struct ProtectedBody: Equatable, Sendable {
    /// For showing. Tracking pixels are gone, links are cleaned, and every other
    /// remote image is a placeholder marked `data-heyday-image="<index into images>"`,
    /// to be replaced once the app has fetched the image.
    public let displayHTML: String
    /// For quoting in a reply or forward. Tracking pixels are gone and links are
    /// cleaned; the sender's other images are left as written.
    public let quotableHTML: String
    public let images: [HeldImage]
    public let report: PrivacyReport
}

/// Takes the tracking out of an email's HTML.
///
/// Images that are there only to track are removed outright. Every other remote
/// image is fetched by the app rather than the page, from an address with the
/// tracking parameters taken off, and is marked for whether that address looks
/// shared by all recipients or could be a mark for one of them.
///
/// None of this hides the reader's network address from a server an image is
/// fetched from, or the time of the fetch; that takes a relay between the reader
/// and the sender, which this app does not have.
public enum MailBodyProtector {
    public static func protect(_ html: String) -> ProtectedBody {
        var images: [HeldImage] = []
        var report = PrivacyReport()
        let display = rewrite(html, holdingBackImages: true, images: &images, report: &report)
        var ignoredImages: [HeldImage] = []
        var ignoredReport = PrivacyReport()
        let quotable = rewrite(html, holdingBackImages: false, images: &ignoredImages, report: &ignoredReport)
        return ProtectedBody(displayHTML: display, quotableHTML: quotable, images: images, report: report)
    }

    private static func rewrite(
        _ html: String,
        holdingBackImages: Bool,
        images: inout [HeldImage],
        report: inout PrivacyReport
    ) -> String {
        HTMLTags.rewrite(html) { tag in
            switch tag.name {
            case "img":
                guard let written = remoteURL(tag["src"]) else { return nil }
                let url = TrackerRules.strippingTrackingParameters(written)
                if let tracker = TrackerRules.openTracker(at: url) {
                    report.pixels.append(tracker)
                    return ""
                }
                if isPixelSized(tag) {
                    report.pixels.append(MailTracker(kind: .pixel, service: nil, host: url.host?.lowercased() ?? ""))
                    return ""
                }
                guard holdingBackImages else { return nil }
                // An image the sender hides is not shown, so there is nothing to
                // offer. It is not called a tracker: layouts hide pictures too.
                if isHidden(tag) { return "" }
                let image = HeldImage(url: url, looksShared: TrackerRules.looksShared(imageAt: url), tag: tag)
                images.append(image)
                return placeholder(at: images.count - 1, for: image)

            case "a", "area":
                return cleanedLink(tag, report: &report)

            case "meta":
                // A refresh sends the reader to another page without being asked.
                return tag["http-equiv"]?.lowercased() == "refresh" ? "" : nil

            case "base":
                // Would redirect every relative address in the email.
                return ""

            default:
                return nil
            }
        }
    }

    // MARK: Links

    /// The link with what tracking can be removed taken off, or nil if it is fine as written.
    private static func cleanedLink(_ original: HTMLTag, report: inout PrivacyReport) -> String? {
        var tag = original
        // `ping` asks the browser to notify these addresses when the link is followed.
        tag.set("ping", to: nil)

        if let written = remoteURL(tag["href"]) {
            var url = written
            // Redirects can be nested; a handful of layers is already unusual.
            for _ in 0..<4 {
                guard let inner = TrackerRules.destination(embeddedIn: url) else { break }
                url = inner
            }
            url = TrackerRules.strippingTrackingParameters(url)
            if url != written {
                report.cleanedLinks += 1
                tag.set("href", to: url.absoluteString)
            }
            if let tracker = TrackerRules.clickTracker(at: url) {
                report.trackedLinks.append(tracker)
                tag.set("data-heyday-tracker", to: tracker.name)
                tag.set("title", to: "Tracked by \(tracker.name)")
            }
        }
        return tag == original ? nil : tag.html
    }

    // MARK: Images

    /// An address that would be fetched from the network, or nil for one that would
    /// not: inline data, an attachment reference, or nothing usable.
    private static func remoteURL(_ written: String?) -> URL? {
        guard var address = written?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        if address.hasPrefix("//") { address = "https:" + address }
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }

    /// Whether an image is at most one pixel each way. A remote image too small to
    /// see has one use.
    private static func isPixelSized(_ tag: HTMLTag) -> Bool {
        if let width = pixels(tag["width"]), let height = pixels(tag["height"]), width <= 1, height <= 1 { return true }
        let style = compactStyle(of: tag)
        return style.contains(/(^|;)width:[01](px)?(!important)?(;|$)/) && style.contains(/(^|;)height:[01](px)?(!important)?(;|$)/)
    }

    private static func isHidden(_ tag: HTMLTag) -> Bool {
        let style = compactStyle(of: tag)
        return style.contains("display:none") || style.contains("visibility:hidden")
    }

    /// The tag's inline style, lowercased and without spaces.
    private static func compactStyle(of tag: HTMLTag) -> String {
        (tag["style"] ?? "").lowercased().filter { !$0.isWhitespace }
    }

    /// A length attribute such as `600` or `600px`, in pixels.
    private static func pixels(_ written: String?) -> Int? {
        guard let written else { return nil }
        let digits = written.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "px", with: "")
        return Int(digits)
    }

    /// What stands in for an image until it is fetched: a box of the image's own
    /// size. One that waits to be asked for says what it is and asks to be clicked.
    private static func placeholder(at index: Int, for image: HeldImage) -> String {
        let tag = image.tag
        var style = ""
        if let width = pixels(tag["width"]), width > 0 {
            style += "width:\(width)px;"
            if let height = pixels(tag["height"]), height > 0 { style += "aspect-ratio:\(width)/\(height);" }
        } else if let height = pixels(tag["height"]), height > 0 {
            style += "height:\(height)px;"
        }
        let description = tag["alt"].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let label = image.looksShared ? "Loading…" : description.map { "Show image: \($0)" } ?? "Show image"
        let host = image.url.host ?? ""
        return "<span class=\"heyday-image\" data-heyday-image=\"\(index)\" role=\"button\""
            + " title=\"\(HTMLText.escapeAttribute("Load this image from \(host)"))\" style=\"\(style)\">"
            + "<span class=\"heyday-image-label\">\(HTMLText.escape(label))</span></span>"
    }
}
