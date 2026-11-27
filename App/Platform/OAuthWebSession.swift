import Foundation
import HeydayKit

#if os(macOS)
import AppKit
import Network
#else
import AuthenticationServices
import UIKit
#endif

/// Interactive browser-based OAuth 2.0 sign-in for macOS and iOS.
///
/// - On macOS, binds an ephemeral loopback listener on `127.0.0.1:0` and opens the
///   system default browser (matching RFC 8252 / Google Desktop / Microsoft / Fastmail
///   public-client guidance so existing browser sessions and passkeys work seamlessly).
/// - On iOS, runs `ASWebAuthenticationSession` with the `app.heyday://` callback scheme.
struct OAuthWebAuthenticator: Sendable {
    private let client: OAuth2Client

    init(client: OAuth2Client = OAuth2Client()) {
        self.client = client
    }

    func authorize(
        account: MailAccount,
        config: OAuth2AccountConfig
    ) async throws(OAuth2Error) -> (MailAccount, OAuth2Tokens) {
        let pkce = OAuth2PKCE.generate()
        #if os(macOS)
        return try await authorizeOnMac(account: account, config: config, pkce: pkce)
        #else
        return try await authorizeOnIOS(account: account, config: config, pkce: pkce)
        #endif
    }

    /// Resolves a Client ID — performing RFC 7591 dynamic client registration when the
    /// provider supports it (Fastmail) and none was supplied.
    private func resolveConfig(
        _ config: OAuth2AccountConfig,
        redirectURI: String
    ) async throws(OAuth2Error) -> OAuth2AccountConfig {
        var resolved = config
        if resolved.clientID.isEmpty {
            if let registration = resolved.registrationEndpoint {
                resolved.clientID = try await client.registerDynamicClient(
                    at: registration,
                    clientName: "Heyday",
                    redirectURI: redirectURI
                )
            } else {
                throw OAuth2Error(.missingClientID)
            }
        }
        return resolved
    }

    #if os(macOS)
    private func authorizeOnMac(
        account: MailAccount,
        config: OAuth2AccountConfig,
        pkce: OAuth2PKCE
    ) async throws(OAuth2Error) -> (MailAccount, OAuth2Tokens) {
        let server = try await LoopbackOAuthServer.start()
        defer { server.stop() }

        let redirectURI = "http://127.0.0.1:\(server.port)/oauth/\(config.provider.rawValue)"
        let resolvedConfig = try await resolveConfig(config, redirectURI: redirectURI)
        let authURL = client.authorizationURL(
            config: resolvedConfig,
            redirectURI: redirectURI,
            pkce: pkce,
            loginHint: account.sender.address
        )

        let opened = await MainActor.run { NSWorkspace.shared.open(authURL) }
        guard opened else {
            throw OAuth2Error(.network, "Could not open your web browser for sign-in.")
        }

        let callbackURL = try await server.waitForCallback(port: server.port)
        await MainActor.run { NSApp.activate() }

        let code = try client.parseCallbackURL(callbackURL, expectedState: pkce.state)
        let tokens = try await client.exchangeCode(code, config: resolvedConfig, redirectURI: redirectURI, pkce: pkce)

        var updatedAccount = account
        updatedAccount.authMethod = .oauth2(resolvedConfig)
        return (updatedAccount, tokens)
    }
    #else
    private func authorizeOnIOS(
        account: MailAccount,
        config: OAuth2AccountConfig,
        pkce: OAuth2PKCE
    ) async throws(OAuth2Error) -> (MailAccount, OAuth2Tokens) {
        let scheme = "app.heyday"
        let redirectURI = "\(scheme)://oauth/\(config.provider.rawValue)"
        let resolvedConfig = try await resolveConfig(config, redirectURI: redirectURI)
        let authURL = client.authorizationURL(
            config: resolvedConfig,
            redirectURI: redirectURI,
            pkce: pkce,
            loginHint: account.sender.address
        )

        let callbackURL = try await IOSWebAuthRunner.run(url: authURL, callbackScheme: scheme)
        let code = try client.parseCallbackURL(callbackURL, expectedState: pkce.state)
        let tokens = try await client.exchangeCode(code, config: resolvedConfig, redirectURI: redirectURI, pkce: pkce)

        var updatedAccount = account
        updatedAccount.authMethod = .oauth2(resolvedConfig)
        return (updatedAccount, tokens)
    }
    #endif
}

// MARK: - macOS Loopback Callback Server (127.0.0.1:0)

#if os(macOS)
private final class LoopbackOAuthServer: @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.heyday.oauth.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var pendingResult: Result<URL, Error>?
    private var stopped = false

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws(OAuth2Error) -> LoopbackOAuthServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw OAuth2Error(.network, "Could not start local sign-in callback listener (\(error.localizedDescription)).")
        }

        let port: UInt16
        do {
            port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
                let gate = OnceGate()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let boundPort = listener.port?.rawValue, boundPort > 0 {
                            gate.run { cont.resume(returning: boundPort) }
                        } else {
                            gate.run { cont.resume(throwing: OAuth2Error(.network, "Local callback port was unavailable.")) }
                        }
                    case .failed(let error):
                        gate.run { cont.resume(throwing: OAuth2Error(.network, error.localizedDescription)) }
                    case .cancelled:
                        gate.run { cont.resume(throwing: OAuth2Error(.cancelled)) }
                    default:
                        break
                    }
                }
                listener.start(queue: DispatchQueue(label: "app.heyday.oauth.start"))
            }
        } catch let error as OAuth2Error {
            listener.cancel()
            throw error
        } catch {
            listener.cancel()
            throw OAuth2Error(.network, error.localizedDescription)
        }

        let server = LoopbackOAuthServer(listener: listener, port: port)
        listener.newConnectionHandler = { [weak server] connection in
            server?.handle(connection)
        }
        return server
    }

    func waitForCallback(port: UInt16) async throws(OAuth2Error) -> URL {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                    lock.lock()
                    if let pendingResult {
                        lock.unlock()
                        cont.resume(with: pendingResult)
                        return
                    }
                    if stopped {
                        lock.unlock()
                        cont.resume(throwing: OAuth2Error(.cancelled))
                        return
                    }
                    continuation = cont
                    lock.unlock()
                }
            } onCancel: { [weak self] in
                self?.finish(with: .failure(OAuth2Error(.cancelled)))
                self?.stop()
            }
        } catch let error as OAuth2Error {
            throw error
        } catch {
            throw OAuth2Error(.network, error.localizedDescription)
        }
    }

    func stop() {
        lock.lock()
        let shouldCancel = !stopped
        stopped = true
        let pending = continuation
        continuation = nil
        lock.unlock()

        if shouldCancel {
            listener.cancel()
        }
        pending?.resume(throwing: OAuth2Error(.cancelled))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data, let url = Self.extractURL(fromHTTPRequest: data, port: self.port) else {
                Self.sendHTTP(connection, status: "400 Bad Request", body: Self.failureHTML)
                return
            }
            // Ignore browser favicon requests so they don't consume the OAuth callback.
            if url.path == "/favicon.ico" {
                Self.sendHTTP(connection, status: "404 Not Found", body: "")
                return
            }
            Self.sendHTTP(connection, status: "200 OK", body: Self.successHTML)
            self.finish(with: .success(url))
        }
    }

    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        guard pendingResult == nil else {
            lock.unlock()
            return
        }
        pendingResult = result
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    private static func extractURL(fromHTTPRequest data: Data, port: UInt16) -> URL? {
        guard let request = String(data: data, encoding: .utf8),
              let firstLine = request.split(separator: "\r\n", maxSplits: 1).first
        else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        return URL(string: "http://127.0.0.1:\(port)\(target)")
    }

    private static func sendHTTP(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let successHTML = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Heyday</title>
    <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#f7f7f9;color:#1d1d1f}.card{background:#fff;border-radius:16px;padding:32px 36px;box-shadow:0 8px 28px rgba(0,0,0,.08);text-align:center;max-width:360px}h1{font-size:20px;margin:0 0 8px}p{font-size:14px;color:#6e6e73;margin:0}</style>
    </head><body><div class="card"><h1>Signed in to Heyday</h1><p>You can close this tab and return to Heyday.</p></div></body></html>
    """

    private static let failureHTML = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Heyday</title></head><body><p>Invalid sign-in callback.</p></body></html>
    """
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ action: () -> Void) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        action()
    }
}
#else
// MARK: - iOS ASWebAuthenticationSession Runner

@MainActor
private final class IOSWebAuthRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    static func run(url: URL, callbackScheme: String) async throws(OAuth2Error) -> URL {
        let runner = IOSWebAuthRunner()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                    let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callbackURL, error in
                        runner.session = nil
                        if let callbackURL {
                            cont.resume(returning: callbackURL)
                        } else if let authError = error as? ASWebAuthenticationSessionError,
                                  authError.code == .canceledLogin {
                            cont.resume(throwing: OAuth2Error(.cancelled))
                        } else {
                            cont.resume(throwing: OAuth2Error(.network, error?.localizedDescription ?? "Sign-in did not complete."))
                        }
                    }
                    session.presentationContextProvider = runner
                    session.prefersEphemeralWebBrowserSession = false
                    runner.session = session
                    if !session.start() {
                        runner.session = nil
                        cont.resume(throwing: OAuth2Error(.network, "Could not start sign-in session."))
                    }
                }
            } onCancel: {
                Task { @MainActor in runner.session?.cancel() }
            }
        } catch let error as OAuth2Error {
            throw error
        } catch {
            throw OAuth2Error(.network, error.localizedDescription)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
#endif
