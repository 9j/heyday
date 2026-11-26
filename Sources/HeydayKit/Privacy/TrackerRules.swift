import Foundation

/// A way an email reports back to its sender.
public struct MailTracker: Hashable, Sendable {
    public enum Kind: Sendable {
        /// An image fetched so the sender learns the email was opened.
        case pixel
        /// A link that goes to a tracker first, which records the click and then
        /// sends you on.
        case link
    }

    public let kind: Kind
    /// Whose tracking it is, when it is a service this app knows by name.
    public let service: String?
    public let host: String

    /// What to call it: the service if known, otherwise where it reports to.
    public var name: String { service ?? host }

    /// The click tracker a link goes through, if it goes through one. For asking
    /// before such a link is opened.
    public static func tracking(link url: URL) -> MailTracker? {
        TrackerRules.clickTracker(at: url)
    }
}

/// What this app knows about how email is tracked: the addresses the well-known
/// mailing services use, and the tell-tale shapes of the rest.
enum TrackerRules {
    /// Where a service's trackers live. A nil host means any host: mailing services
    /// let senders use their own domain, and only the path gives them away. A
    /// parameter is one the address has to carry, for a service whose trackers
    /// have no path of their own.
    private struct Address {
        let service: String
        let host: String?
        let path: String?
        let parameter: String?

        init(_ service: String, host: String? = nil, path: String? = nil, parameter: String? = nil) {
            self.service = service
            self.host = host
            self.path = path
            self.parameter = parameter
        }

        func matches(_ url: URL) -> Bool {
            if let host, !TrackerRules.host(of: url, isUnder: host) { return false }
            if let path, !url.path.contains(path) { return false }
            if let parameter, !TrackerRules.queryItems(of: url).contains(where: { $0.name == parameter }) { return false }
            return true
        }
    }

    private static let openTrackers = [
        Address("Mailchimp", host: "list-manage.com", path: "/track/open.php"),
        Address("Mailchimp", host: "list-manage.com", parameter: "c2id"),
        Address("Mandrill", host: "mandrillapp.com", path: "/track/open.php"),
        Address("SendGrid", path: "/wf/open"),
        Address("SendGrid", path: "/ss/o/"),
        Address("Loops", host: "vialoops.com", path: "/CI0/"),
        Address("Amazon SES", host: "awstrack.me", path: "/I0/"),
        Address("Amazon SES", path: "/CI0/"),
        Address("Mailgun", path: "/o/eJ"),
        Address("Mailjet", host: "mjt.lu", path: "/oo/"),
        Address("Postmark", host: "pstmrk.it", path: "/open"),
        Address("HubSpot", host: "hubspotemail.net"),
        Address("HubSpot", host: "track.hubspot.com"),
        Address("HubSpot", path: "/e2t/o/"),
        Address("HubSpot", path: "/e3t/Cto/"),
        Address("Customer.io", path: "/e/o/"),
        Address("Intercom", host: "intercom-mail.com", path: "/via/o"),
        Address("Intercom", host: "via.intercom.io", path: "/o"),
        Address("Salesforce Marketing Cloud", path: "/open.aspx"),
        Address("Constant Contact", host: "rs6.net", path: "/on.jsp"),
        Address("Brevo", path: "/tr/op/"),
        Address("Brevo", path: "/mk/op/"),
        Address("ActiveCampaign", path: "/lt.php"),
        Address("Substack", host: "substack.com", path: "/o/"),
        Address("Google Analytics", host: "google-analytics.com", path: "/collect"),
        Address("GitHub", host: "github.com", path: "/notifications/beacon/"),
        Address("PayPal", host: "t.paypal.com", path: "/ts"),
        Address("LinkedIn", host: "linkedin.com", path: "/emimp/"),
        Address("Facebook", host: "facebook.com", path: "/email_open_log_pic.php"),
        Address("Mailtrack", host: "mailtrack.io", path: "/trace/"),
        Address("Yesware", host: "t.yesware.com"),
        Address("Streak", host: "mailfoogae.appspot.com"),
        Address("Superhuman", host: "r.superhuman.com"),
        Address("Mixmax", host: "track.mixmax.com"),
    ]

    private static let clickTrackers = [
        Address("Mailchimp", host: "list-manage.com", path: "/track/click"),
        Address("Mailchimp", host: "list-manage.com", parameter: "c2id"),
        Address("Mandrill", host: "mandrillapp.com", path: "/track/click"),
        Address("SendGrid", path: "/ls/click"),
        Address("SendGrid", path: "/wf/click"),
        Address("SendGrid", path: "/ss/c/"),
        Address("Loops", host: "vialoops.com", path: "/CL0/"),
        Address("Amazon SES", host: "awstrack.me", path: "/L0/"),
        Address("Amazon SES", path: "/CL0/"),
        Address("Mailgun", path: "/c/eJ"),
        Address("Mailjet", host: "mjt.lu", path: "/lnk/"),
        Address("Postmark", host: "pstmrk.it"),
        Address("HubSpot", host: "hubspotlinks.com"),
        Address("HubSpot", path: "/e2t/c/"),
        Address("HubSpot", path: "/e3t/Ctc/"),
        Address("Klaviyo", host: "klclick.com"),
        Address("Customer.io", path: "/e/c/"),
        Address("Brevo", path: "/tr/cl/"),
        Address("Brevo", path: "/mk/cl/"),
        Address("Salesforce Marketing Cloud", host: "exct.net"),
        Address("Substack", host: "substack.com", path: "/redirect/"),
        Address("ConvertKit", host: "convertkit-mail.com"),
        Address("ConvertKit", host: "convertkit-mail2.com"),
    ]

    /// First labels that only a click tracker's host would have. Deliberately
    /// short: `link.` and `go.` front plenty of ordinary sites.
    private static let trackerHostLabels: Set<String> = ["click", "clicks", "track", "tracking", "trk", "lnk"]

    /// First labels of hosts that mailing services serve from. A picture that comes
    /// from one of these is not taken for an ordinary shared file.
    private static let mailingHostLabels: Set<String> = trackerHostLabels.union(
        ["email", "e", "em", "t", "o", "open", "pixel", "px", "beacon", "link", "links"]
    )

    /// Query parameters that only say how a picture should be served.
    private static let presentationParameters: Set<String> = [
        "w", "h", "width", "height", "size", "s", "sz", "q", "quality", "fit", "format", "fm", "f", "auto", "dpr", "crop",
        "scale", "resize", "mode", "bg", "v", "ver", "version",
    ]

    /// Query parameters that exist to follow a click into the site it lands on.
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id", "igshid",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok",
        "vero_id", "vero_conv", "oly_enc_id", "oly_anon_id", "_openstat", "s_kwcid", "ck_subscriber_id", "_kx",
    ]

    /// The service whose open tracker an image address is, if it is a known one.
    static func openTracker(at url: URL) -> MailTracker? {
        guard let host = url.host?.lowercased() else { return nil }
        return openTrackers.first { $0.matches(url) }.map { MailTracker(kind: .pixel, service: $0.service, host: host) }
    }

    /// The click tracker a link goes through, known by name or by the look of its host.
    static func clickTracker(at url: URL) -> MailTracker? {
        guard let host = url.host?.lowercased() else { return nil }
        if let known = clickTrackers.first(where: { $0.matches(url) }) {
            return MailTracker(kind: .link, service: known.service, host: host)
        }
        let labels = host.split(separator: ".")
        if labels.count > 2, trackerHostLabels.contains(String(labels[0])) {
            return MailTracker(kind: .link, service: nil, host: host)
        }
        return nil
    }

    /// Where a link really leads, when it is one of the redirects that carry their
    /// destination in plain sight. Nil for any other link, including a tracked one
    /// whose destination only the tracker knows.
    static func destination(embeddedIn url: URL) -> URL? {
        let path = url.path
        func parameter(_ names: String...) -> String? {
            let items = queryItems(of: url)
            return names.lazy.compactMap { name in items.first { $0.name == name }?.value }.first
        }

        var embedded: String?
        if host(of: url, isUnder: "google.com"), path == "/url" {
            embedded = parameter("q", "url")
        } else if host(of: url, isUnder: "safelinks.protection.outlook.com") {
            embedded = parameter("url")
        } else if host(of: url, isUnder: "facebook.com"), path == "/l.php" {
            embedded = parameter("u")
        } else if host(of: url, isUnder: "l.instagram.com") {
            embedded = parameter("u")
        } else if host(of: url, isUnder: "linkedin.com"), path == "/redir/redirect" {
            embedded = parameter("url")
        } else if host(of: url, isUnder: "slack-redir.net"), path == "/link" {
            embedded = parameter("url")
        } else if host(of: url, isUnder: "youtube.com"), path == "/redirect" {
            embedded = parameter("q")
        } else if host(of: url, isUnder: "awstrack.me"), let wrapped = url.absoluteString.firstMatch(of: #//C?L0/([^/]+)/#) {
            // The destination is the path component after `L0`, percent-encoded.
            embedded = String(wrapped.1).removingPercentEncoding
        } else if host(of: url, isUnder: "urldefense.com"), let wrapped = url.absoluteString.firstMatch(of: #//v3/__(.+?)__;/#) {
            embedded = String(wrapped.1)
        } else if let wrapped = url.absoluteString.firstMatch(of: #//CL0/([^/]+)/#) {
            // Amazon SES again, served from the sender's own domain.
            embedded = String(wrapped.1).removingPercentEncoding
        }

        guard let embedded, let destination = URL(string: embedded), ["http", "https"].contains(destination.scheme?.lowercased()) else {
            return nil
        }
        return destination
    }

    /// The address without the parameters that are only there to track.
    static func strippingTrackingParameters(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems
        else { return url }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// Whether an image's address looks like the one every recipient was given, with
    /// nothing in it that could be a mark for one reader: an ordinary host, and no
    /// parameters beyond how to serve the picture. Fetching such an image tells its
    /// server that somebody did, not who.
    ///
    /// The path is not judged. Mailing services file a sender's pictures under
    /// generated names, so a long identifier there is the rule in real mail, and it
    /// is the same for every recipient; the mark for one reader is carried in a
    /// parameter.
    ///
    /// This is a judgement from the look of the address. A sender who wants to can
    /// put a personal mark in the path, and one who writes to you alone needs no
    /// mark at all.
    static func looksShared(imageAt url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let labels = host.split(separator: ".")
        if labels.count > 2, mailingHostLabels.contains(String(labels[0])) { return false }
        if clickTrackers.contains(where: { $0.matches(url) }) { return false }

        for parameter in queryItems(of: url) {
            guard presentationParameters.contains(parameter.name.lowercased()), !looksGenerated(parameter.value ?? "") else { return false }
        }
        return true
    }

    /// Whether text reads as a generated identifier rather than a name somebody
    /// chose: a long stretch of hexadecimal, a long run with digits in it, or a long
    /// run of letters whose case changes the way encoded data does.
    private static func looksGenerated(_ text: String) -> Bool {
        let compact = text.filter { $0 != "-" && $0 != "_" }
        if compact.count >= 16, compact.allSatisfy(\.isHexDigit) { return true }

        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { run in
            if run.count >= 12, run.contains(where: \.isNumber) { return true }
            let lowerToUpper = zip(run, run.dropFirst()).count { $0.isLowercase && $1.isUppercase }
            return run.count >= 16 && lowerToUpper >= 3
        }
    }

    private static func queryItems(of url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private static func host(of url: URL, isUnder domain: String) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
