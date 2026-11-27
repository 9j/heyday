import Foundation

/// Minimal HTTP transport for non-translation endpoints (OAuth 2.0 token calls and
/// Thunderbird ISPDB autoconfig). Tests inject a scripted implementation.
public protocol AuthHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral URLSession transport with cookies and caches disabled.
public struct URLSessionAuthTransport: AuthHTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Server configuration discovered from Thunderbird's public ISPDB
/// (`autoconfig.thunderbird.net/v1.1/<domain>`).
public struct AutoconfigResult: Equatable, Sendable {
    public let displayName: String?
    public let imap: ServerEndpoint
    public let smtp: ServerEndpoint
    public let prefersOAuth2: Bool
    public let oauthProvider: OAuth2ProviderID?
    public let serverSavesSentMail: Bool

    public init(
        displayName: String?,
        imap: ServerEndpoint,
        smtp: ServerEndpoint,
        prefersOAuth2: Bool,
        oauthProvider: OAuth2ProviderID?,
        serverSavesSentMail: Bool
    ) {
        self.displayName = displayName
        self.imap = imap
        self.smtp = smtp
        self.prefersOAuth2 = prefersOAuth2
        self.oauthProvider = oauthProvider
        self.serverSavesSentMail = serverSavesSentMail
    }
}

/// Looks up mail server settings by email domain using built-in presets first and
/// Thunderbird's public ISPDB XML autoconfig service as a fallback.
public struct ISPDBClient: Sendable {
    public static let baseURL = URL(string: "https://autoconfig.thunderbird.net/v1.1")!

    private let transport: any AuthHTTPTransport

    public init(transport: any AuthHTTPTransport = URLSessionAuthTransport(timeout: 8)) {
        self.transport = transport
    }

    public func lookup(domain: String) async -> AutoconfigResult? {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              let escaped = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(Self.baseURL.absoluteString)/\(escaped)")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/xml, text/xml", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await transport.data(for: request),
              (200..<300).contains(response.statusCode)
        else { return nil }

        return AutoconfigXMLParser.parse(data)
    }
}

/// Parses Thunderbird's `clientConfig` v1.1 XML format into an `AutoconfigResult`.
public enum AutoconfigXMLParser {
    public static func parse(_ data: Data) -> AutoconfigResult? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let imap = delegate.imapServer, let smtp = delegate.smtpServer else {
            return nil
        }

        let oauthProvider = MailProviderCatalog.oauthProvider(forHostname: imap.endpoint.host)
            ?? MailProviderCatalog.oauthProvider(forHostname: smtp.endpoint.host)
        let supportsOAuth = imap.authentications.contains("oauth2") || smtp.authentications.contains("oauth2")
        let supportsPassword = imap.authentications.contains { $0.hasPrefix("password") }
        let prefersOAuth = supportsOAuth && (!supportsPassword || oauthProvider == .fastmail || oauthProvider == .microsoft)
        let serverSavesSentMail = oauthProvider == .google || oauthProvider == .microsoft

        return AutoconfigResult(
            displayName: delegate.displayName,
            imap: imap.endpoint,
            smtp: smtp.endpoint,
            prefersOAuth2: prefersOAuth,
            oauthProvider: supportsOAuth ? oauthProvider : nil,
            serverSavesSentMail: serverSavesSentMail
        )
    }

    private struct ParsedServer {
        let endpoint: ServerEndpoint
        let authentications: [String]
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var displayName: String?
        var imapServer: ParsedServer?
        var smtpServer: ParsedServer?

        private enum ServerKind { case incomingIMAP, outgoingSMTP, ignored }

        private var serverKind: ServerKind = .ignored
        private var currentElement = ""
        private var buffer = ""

        private var host = ""
        private var port: Int?
        private var socketType = ""
        private var authentications: [String] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentElement = elementName
            buffer = ""
            switch elementName {
            case "incomingServer":
                let type = attributeDict["type"]?.lowercased()
                serverKind = (type == "imap" && imapServer == nil) ? .incomingIMAP : .ignored
                resetServerFields()
            case "outgoingServer":
                let type = attributeDict["type"]?.lowercased()
                serverKind = (type == "smtp" && smtpServer == nil) ? .outgoingSMTP : .ignored
                resetServerFields()
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "displayName" where displayName == nil && serverKind == .ignored && !text.isEmpty:
                displayName = text
            case "hostname" where serverKind != .ignored:
                host = text
            case "port" where serverKind != .ignored:
                port = Int(text)
            case "socketType" where serverKind != .ignored:
                socketType = text.uppercased()
            case "authentication" where serverKind != .ignored && !text.isEmpty:
                authentications.append(text.lowercased())
            case "incomingServer":
                if serverKind == .incomingIMAP, let built = buildServer(defaultPort: 993) {
                    imapServer = built
                }
                serverKind = .ignored
            case "outgoingServer":
                if serverKind == .outgoingSMTP, let built = buildServer(defaultPort: 587) {
                    smtpServer = built
                }
                serverKind = .ignored
            default:
                break
            }
            buffer = ""
            currentElement = ""
        }

        private func resetServerFields() {
            host = ""
            port = nil
            socketType = ""
            authentications = []
        }

        private func buildServer(defaultPort: Int) -> ParsedServer? {
            guard !host.isEmpty else { return nil }
            let security: ConnectionSecurity = switch socketType {
            case "SSL": .tls
            case "STARTTLS": .startTLS
            case "PLAIN": .none
            default: .tls
            }
            return ParsedServer(
                endpoint: ServerEndpoint(host: host, port: port ?? defaultPort, security: security),
                authentications: authentications
            )
        }
    }
}
