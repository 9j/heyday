import Foundation
import Testing
@testable import HeydayKit

/// Checks against a real Proton Mail Bridge on this Mac, over real sockets: that the
/// connection is upgraded with STARTTLS, that Bridge's self-signed certificate is
/// accepted for a loopback host, and that its answers parse.
///
/// They log in with an address that cannot exist, so nothing in any mailbox is read
/// or changed. Skipped unless asked for:
///
///     HEYDAY_BRIDGE_TESTS=1 swift test --filter LocalBridgeTests
///
/// Bridge counts failed logins. After a handful in a row it answers "too many login
/// attempts" to everyone for a while, real mail clients included, so run these
/// sparingly.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HEYDAY_BRIDGE_TESTS"] != nil))
struct LocalBridgeTests {
    private let nobody = "heyday-connection-test@example.invalid"

    @Test func imapReachesTheLoginStepOverSTARTTLS() async {
        do {
            _ = try await IMAPSession.open(
                AccountSetup.protonBridge.imap,
                username: nobody,
                password: "not-a-real-password",
                using: URLSessionStreamConnector()
            )
            Issue.record("Bridge accepted a login that cannot exist")
        } catch {
            // Being told "wrong login" means the TLS upgrade and the protocol both worked.
            #expect(error.kind == .loginRefused, "\(error)")
        }
    }

    @Test func smtpReachesTheLoginStepOverSTARTTLS() async {
        do {
            try await SMTPClient.send(
                Data("Subject: never sent\r\n\r\n".utf8),
                from: nobody,
                to: [nobody],
                via: AccountSetup.protonBridge.smtp,
                username: nobody,
                password: "not-a-real-password",
                using: URLSessionStreamConnector()
            )
            Issue.record("Bridge accepted a login that cannot exist")
        } catch {
            #expect(error.kind == .loginRefused, "\(error)")
        }
    }
}
