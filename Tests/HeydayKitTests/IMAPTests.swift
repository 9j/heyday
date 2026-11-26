import Foundation
import Testing
@testable import HeydayKit

/// A server played back from a script. Each `expect` entry is what the client should
/// send next (matched by prefix after the tag); the bytes paired with it are the reply.
final class ScriptedServer: ByteStream, ByteStreamConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data]
    private var replies: [(expects: String, reply: String)]
    private var received = Data()
    private var lastTag = ""
    private(set) var didStartTLS = false
    private(set) var isClosed = false

    /// - Parameter greeting: sent before the client says anything.
    init(greeting: String, _ replies: [(expects: String, reply: String)]) {
        inbox = [Data(greeting.utf8)]
        self.replies = replies
    }

    var transcript: String { lock.withLock { String(decoding: received, as: UTF8.self) } }

    func connect(to endpoint: ServerEndpoint) async throws(StreamError) -> any ByteStream { self }

    func read(timeout: TimeInterval) async throws(StreamError) -> Data {
        let next: Data? = lock.withLock { inbox.isEmpty ? nil : inbox.removeFirst() }
        guard let next else { throw StreamError("The server closed the connection.") }
        return next
    }

    func write(_ data: Data) async throws(StreamError) {
        lock.withLock {
            received.append(data)
            let text = String(decoding: data, as: UTF8.self)
            if let tag = text.firstMatch(of: #/^(A\d+) /#) { lastTag = String(tag.1) }
            guard let next = replies.first, text.contains(next.expects) else { return }
            replies.removeFirst()
            // `{tag}` in a reply stands for the tag of the command being answered. The
            // bytes after a literal's go-ahead continue that command and carry no tag.
            inbox.append(Data(next.reply.replacingOccurrences(of: "{tag}", with: lastTag).utf8))
        }
    }

    func startTLS() async throws(StreamError) {
        lock.withLock { didStartTLS = true }
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}

private let endpoint = ServerEndpoint(host: "127.0.0.1", port: 1143, security: .startTLS)

private func loggedIn(_ replies: [(expects: String, reply: String)]) async throws -> (IMAPSession, ScriptedServer) {
    let server = ScriptedServer(greeting: "* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n", [
        ("STARTTLS", "{tag} OK begin TLS\r\n"),
        ("LOGIN", "{tag} OK logged in\r\n"),
        ("CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE MOVE UIDPLUS\r\n{tag} OK done\r\n"),
    ] + replies)
    let session = try await IMAPSession.open(endpoint, username: "me@example.com", password: "p\"w", using: server)
    return (session, server)
}

@Suite struct IMAPValueTests {
    private func parse(_ text: String) throws -> [IMAPValue] {
        var parser = IMAPValueParser(Data(text.utf8))
        return try parser.values()
    }

    @Test func listsStringsAtomsAndNilAreRead() throws {
        #expect(try parse(#"(\Seen $Label) "a \"b\"" NIL 42"#) == [
            .list([.atom("\\Seen"), .atom("$Label")]),
            .string(Data(#"a "b""#.utf8)),
            .null,
            .atom("42"),
        ])
    }

    @Test func aLiteralIsReadByLengthEvenWhenItContainsSyntax() throws {
        #expect(try parse("{7}\r\na (b\r\n\" tail") == [.string(Data("a (b\r\n\"".utf8)), .atom("tail")])
    }

    @Test func aBodySectionWithSpacesIsOneAtom() throws {
        #expect(try parse("BODY[HEADER.FIELDS (FROM TO)] x") == [.atom("BODY[HEADER.FIELDS (FROM TO)]"), .atom("x")])
    }

    @Test func anUnclosedListIsAnError() {
        #expect(throws: IMAPSyntaxError.self) { try parse("(a b") }
    }
}

@Suite struct IMAPResponseTests {
    private func response(_ text: String) throws -> IMAPResponse {
        try IMAPResponse(Data(text.utf8))
    }

    @Test func statusAndDataResponsesAreRecognised() throws {
        #expect(try response("+ go ahead") == .continuation)
        #expect(try response("A7 NO [TRYCREATE] no such mailbox") == .tagged(tag: "A7", status: .no, text: "[TRYCREATE] no such mailbox"))
        #expect(try response("* OK [UIDNEXT 42] it's (fine") == .status(.ok, text: "[UIDNEXT 42] it's (fine"))
        #expect(try response("* 23 EXISTS") == .exists(23))
        #expect(try response("* SEARCH 3 1 2") == .search([3, 1, 2]))
        #expect(try response(#"* LIST (\HasNoChildren \Sent) "/" "Sent Mail""#) == .list(attributes: ["\\hasnochildren", "\\sent"], delimiter: "/", name: "Sent Mail"))
    }

    @Test func aFetchResponseBecomesItemsWithNormalisedBodyKeys() throws {
        let fetched = try response("* 5 FETCH (UID 77 FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM)] {11}\r\nFrom: a@b\r\n BODY[TEXT]<0> \"hi\")")

        #expect(fetched == .fetch([
            "UID": .atom("77"),
            "FLAGS": .list([.atom("\\Seen")]),
            "BODY[HEADER]": .string(Data("From: a@b\r\n".utf8)),
            "BODY[TEXT]": .string(Data("hi".utf8)),
        ]))
    }

    @Test func mailboxNamesInModifiedUTF7AreReadable() {
        #expect(IMAPMailboxName.decode("~peter/mail/&U,BTFw-/&ZeVnLIqe-") == "~peter/mail/台北/日本語")
        #expect(IMAPMailboxName.decode("R&-D") == "R&D")
        #expect(IMAPMailboxName.decode("INBOX") == "INBOX")
    }
}

@Suite struct IMAPSessionTests {
    @Test func openingUpgradesToTLSBeforeSendingThePassword() async throws {
        let (_, server) = try await loggedIn([])

        #expect(server.didStartTLS)
        let transcript = server.transcript
        let startTLS = try #require(transcript.range(of: "STARTTLS"))
        let login = try #require(transcript.range(of: #"LOGIN "me@example.com" "p\"w""#))
        #expect(startTLS.upperBound <= login.lowerBound)
    }

    @Test func aRefusedLoginIsReportedAsSuchAndTheConnectionClosed() async {
        let server = ScriptedServer(greeting: "* OK ready\r\n", [
            ("STARTTLS", "{tag} OK\r\n"),
            ("LOGIN", "{tag} NO invalid credentials\r\n"),
        ])

        await #expect(throws: MailError(.loginRefused, "invalid credentials")) {
            _ = try await IMAPSession.open(endpoint, username: "me", password: "wrong", using: server)
        }
        #expect(server.isClosed)
    }

    @Test func mailboxesAreListedWithTheirSpecialUses() async throws {
        let (session, _) = try await loggedIn([
            ("LIST", "* LIST (\\HasNoChildren) \"/\" INBOX\r\n* LIST (\\Trash) \"/\" Trash\r\n{tag} OK\r\n"),
        ])

        #expect(try await session.mailboxes() == [
            .init(name: "INBOX", delimiter: "/", attributes: ["\\hasnochildren"]),
            .init(name: "Trash", delimiter: "/", attributes: ["\\trash"]),
        ])
    }

    @Test func fetchingReadsHeadersThatArriveAsLiterals() async throws {
        let (session, server) = try await loggedIn([
            ("EXAMINE", "* 2 EXISTS\r\n{tag} OK [READ-ONLY]\r\n"),
            ("UID FETCH", "* 1 FETCH (UID 4 FLAGS () BODY[HEADER.FIELDS (SUBJECT)] {14}\r\nSubject: One\r\n)\r\n* 2 FETCH (UID 5 FLAGS (\\Seen) BODY[HEADER.FIELDS (SUBJECT)] {14}\r\nSubject: Two\r\n)\r\n{tag} OK\r\n"),
        ])

        #expect(try await session.select("INBOX", readOnly: true) == 2)
        let messages = try await session.fetch([4, 5], items: "BODY.PEEK[HEADER.FIELDS (SUBJECT)]")

        #expect(messages.map(\.uid) == [4, 5])
        #expect(messages.map(\.flags) == [[], ["\\seen"]])
        #expect(messages.last?.header == Data("Subject: Two\r\n".utf8))
        #expect(server.transcript.contains("UID FETCH 4:5 (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (SUBJECT)])"))
    }

    @Test func aNonASCIIArgumentWaitsForTheGoAheadBeforeSendingItsBytes() async throws {
        let (session, server) = try await loggedIn([
            ("{6}", "+ go ahead\r\n"),
            ("한글", "* SEARCH 9\r\n{tag} OK\r\n"),
        ])

        let found = try await session.search([.text("CHARSET UTF-8 TEXT "), .string("한글")])

        #expect(found == [9])
        #expect(server.transcript.contains("UID SEARCH CHARSET UTF-8 TEXT {6}\r\n한글\r\n"))
    }

    @Test func movingUsesTheMoveExtension() async throws {
        let (session, server) = try await loggedIn([("UID MOVE", "{tag} OK\r\n")])

        try await session.move([3, 4, 9], to: "Folders/Set Aside")

        #expect(server.transcript.contains(#"UID MOVE 3:4,9 "Folders/Set Aside""#))
    }

    @Test func waitingEndsIdleWhenTheServerReportsNewMail() async throws {
        let (session, server) = try await loggedIn([
            ("IDLE", "+ idling\r\n* 24 EXISTS\r\n"),
            ("DONE", "A4 OK IDLE terminated\r\n"),
        ])

        try await session.waitForChange(patience: 5)

        #expect(server.transcript.hasSuffix("A4 IDLE\r\nDONE\r\n"))
    }

    @Test func aServerThatHangsUpIsReportedAsUnreachable() async throws {
        let (session, _) = try await loggedIn([("LIST", "* BYE shutting down\r\n")])

        await #expect(throws: MailError(.unreachable, "shutting down")) {
            _ = try await session.mailboxes()
        }
    }

    @Test func uidsCollapseIntoRanges() {
        #expect(IMAPSession.sequenceSet([5, 1, 2, 3, 9, 10]) == "1:3,5,9:10")
    }
}
