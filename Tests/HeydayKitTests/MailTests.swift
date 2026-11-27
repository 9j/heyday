import Foundation
import Testing
@testable import HeydayKit

private let jane = EmailAddress(name: "Jane", address: "jane@example.com")
private let news = EmailAddress(name: "Weekly", address: "news@example.com")
private let shop = EmailAddress(name: "Shop", address: "receipts@example.com")
private let stranger = EmailAddress(address: "Stranger@Example.com")

/// The moment the Screener started in these tests.
private let screeningStart = Date(timeIntervalSince1970: 1_800_000_000)

/// - Parameter arrived: seconds after the Screener started; negative for mail that was already there.
private func message(
    _ uid: UInt32,
    from: EmailAddress?,
    root: String? = nil,
    seen: Bool = true,
    daysAgo: Double = 0,
    arrived: TimeInterval = 60
) -> MessageSummary {
    MessageSummary(
        id: .init(mailbox: "INBOX", uid: uid),
        messageID: "<\(uid)@x>",
        threadRoot: root,
        from: from,
        subject: "Subject \(uid)",
        date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
        received: screeningStart.addingTimeInterval(arrived),
        isSeen: seen
    )
}

@Suite struct SenderRulesTests {
    private var rules: SenderRules {
        var rules = SenderRules(screeningSince: screeningStart)
        rules.decide(.approved(.mebox), for: jane, at: screeningStart)
        rules.decide(.approved(.feed), for: news, at: screeningStart)
        rules.decide(.approved(.paperTrail), for: shop, at: screeningStart)
        return rules
    }

    @Test func mailFromAnUndecidedSenderWaitsInTheScreener() {
        #expect(rules.placement(for: message(1, from: stranger)) == .screener)
        #expect(rules.placement(for: message(2, from: jane)) == .box(.mebox))
        #expect(rules.placement(for: message(3, from: news)) == .box(.feed))
    }

    @Test func mailThatHadArrivedBeforeScreeningStartedIsLetIn() {
        #expect(rules.placement(for: message(1, from: stranger, arrived: -1)) == .box(.mebox))
        #expect(rules.placement(for: message(2, from: stranger, arrived: 0)) == .screener)
    }

    @Test func aSenderOfOldMailCanStillBeScreenedOut() {
        var rules = rules
        rules.decide(.screenedOut, for: stranger, at: screeningStart)

        #expect(rules.placement(for: message(1, from: stranger, arrived: -86_400)) == .screenedOut)
    }

    @Test func mailWhoseArrivalTimeIsUnknownIsLetIn() {
        let undated = MessageSummary(id: .init(mailbox: "INBOX", uid: 1), from: stranger)

        #expect(rules.placement(for: undated) == .box(.mebox))
    }

    @Test func decisionsIgnoreTheCaseOfTheAddress() {
        var rules = rules
        rules.decide(.screenedOut, for: EmailAddress(address: "stranger@example.com"), at: screeningStart)

        #expect(rules.placement(for: message(1, from: stranger)) == .screenedOut)
    }

    @Test func mailWithNoSenderIsNotHeldBack() {
        #expect(rules.placement(for: message(1, from: nil)) == .box(.mebox))
    }

    @Test func eachBoxShowsOnlyItsSendersMail() {
        let inbox = [message(1, from: jane), message(2, from: news), message(3, from: shop), message(4, from: stranger)]

        #expect(rules.conversations(in: inbox, placed: .box(.mebox)).flatMap(\.messageIDs).map(\.uid) == [1])
        #expect(rules.conversations(in: inbox, placed: .box(.feed)).flatMap(\.messageIDs).map(\.uid) == [2])
        #expect(rules.conversations(in: inbox, placed: .screener).flatMap(\.messageIDs).map(\.uid) == [4])
    }

    @Test func theScreenerListsEachWaitingSenderOnceNewestFirstWithAllTheyHaveSent() {
        let other = EmailAddress(address: "other@example.com")
        let inbox = [
            message(9, from: stranger), message(7, from: other), message(4, from: stranger),
            message(2, from: stranger, arrived: -60), message(1, from: jane),
        ]

        let waiting = rules.waitingSenders(in: inbox)

        #expect(waiting.map(\.id) == ["stranger@example.com", "other@example.com"])
        #expect(waiting.map(\.latest.latest.id.uid) == [9, 7])
        #expect(waiting[0].conversations.flatMap(\.messageIDs).map(\.uid).sorted() == [4, 9])
    }

    @Test func unreadMailInFeedPaperTrailAndScreenedOutIsMarkedRead() {
        var rules = rules
        rules.decide(.screenedOut, for: stranger, at: screeningStart)
        let newcomer = EmailAddress(address: "newcomer@example.com")
        let inbox = [
            message(8, from: news, seen: false),
            message(7, from: shop, seen: false),
            message(6, from: stranger, seen: false),
            message(5, from: stranger, seen: true),
            // Mail that was there before the Screener started is screened out with its sender.
            message(4, from: stranger, seen: false, arrived: -60),
            // Mebox stays unread until the person opens it.
            message(3, from: jane, seen: false),
            // Mail waiting in the Screener stays unread, so it is new if its sender is let in.
            message(2, from: newcomer, seen: false),
            message(1, from: nil, seen: false),
        ]

        #expect(rules.unreadKeptRead(in: inbox).map(\.uid) == [8, 7, 6, 4])
        #expect(SenderDecision.approved(.feed).marksMailRead)
        #expect(SenderDecision.approved(.paperTrail).marksMailRead)
        #expect(SenderDecision.screenedOut.marksMailRead)
        #expect(!SenderDecision.approved(.mebox).marksMailRead)
    }

    @Test func rulesSurviveBeingSavedAndLoaded() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "heyday-tests-\(UUID().uuidString)/rules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFileStore<SenderRules>(url: url)

        #expect(try store.load() == nil)
        try store.save(rules)

        #expect(try store.load() == rules)
    }
}

@Suite struct ConversationTests {
    @Test func repliesJoinTheMessageTheyAnswerOldestFirst() {
        let conversations = Conversation.group([
            message(3, from: jane, root: "<1@x>", daysAgo: 0),
            message(2, from: news, daysAgo: 1),
            message(1, from: jane, root: "<1@x>", daysAgo: 2),
        ])

        #expect(conversations.map { $0.messageIDs.map(\.uid) } == [[1, 3], [2]])
        #expect(conversations.first?.latest.id.uid == 3)
    }

    @Test func aConversationIsUnseenWhileAnyMessageInItIs() {
        let conversation = Conversation.group([
            message(1, from: jane, root: "<1@x>", seen: true),
            message(2, from: jane, root: "<1@x>", seen: false),
        ])[0]

        #expect(!conversation.isSeen)
    }

    @Test func sendersAreListedMostRecentFirstWithoutRepeats() {
        let conversation = Conversation.group([
            message(1, from: jane, root: "<1@x>", daysAgo: 2),
            message(2, from: news, root: "<1@x>", daysAgo: 1),
            message(3, from: jane, root: "<1@x>", daysAgo: 0),
        ])[0]

        #expect(conversation.senders == [jane, news])
    }
}

@Suite struct BubbleUpTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func thread(_ uids: UInt32...) -> Conversation {
        Conversation.group(uids.map { message($0, from: jane, root: "<thread@x>") })[0]
    }

    @Test func aBubbleUpBecomesDueAtItsScheduledSecond() {
        let conversation = thread(1)
        let due = base.addingTimeInterval(3600)
        let bubble = BubbleUp(dueAt: due, condition: .always, baselineMessageCount: 1, scheduledAt: base)

        #expect(!bubble.isDue(for: conversation, at: due.addingTimeInterval(-1)))
        #expect(bubble.isDue(for: conversation, at: due))
        #expect(bubble.isDue(for: conversation, at: due.addingTimeInterval(60)))
    }

    @Test func anIfNoReplyBubbleUpStandsDownOnceAReplyArrives() {
        let beforeReply = thread(1)
        let afterReply = thread(1, 2)
        let due = base.addingTimeInterval(3600)
        let bubble = BubbleUp(dueAt: due, condition: .ifNoReply, baselineMessageCount: 1, scheduledAt: base)

        #expect(!bubble.isSatisfiedByReply(in: beforeReply))
        #expect(bubble.isDue(for: beforeReply, at: due))

        #expect(bubble.isSatisfiedByReply(in: afterReply))
        #expect(!bubble.isDue(for: afterReply, at: due))
    }
}

@Suite struct BubbleUpScheduleTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func quickPresetsLandOnTheExpectedDaysAndHours() {
        // Friday, Nov 27, 2026 at 11:00 UTC
        let fridayMorning = utc(2026, 11, 27, 11, 0)

        #expect(BubbleUpSchedule.date(for: .now, now: fridayMorning, calendar: utcCalendar) == fridayMorning)
        #expect(BubbleUpSchedule.date(for: .laterToday, now: fridayMorning, calendar: utcCalendar) == utc(2026, 11, 27, 18, 0))
        #expect(BubbleUpSchedule.date(for: .tomorrow, now: fridayMorning, calendar: utcCalendar) == utc(2026, 11, 28, 8, 0))
        #expect(BubbleUpSchedule.date(for: .thisWeekend, now: fridayMorning, calendar: utcCalendar) == utc(2026, 11, 28, 8, 0))
        #expect(BubbleUpSchedule.date(for: .nextWeek, now: fridayMorning, calendar: utcCalendar) == utc(2026, 11, 30, 8, 0))
        #expect(BubbleUpSchedule.defaultCustomDate(now: fridayMorning, calendar: utcCalendar) == utc(2026, 11, 28, 8, 0))
    }

    @Test func laterTodayAfterFivePmPushesThreeHoursAhead() {
        let fridayEvening = utc(2026, 11, 27, 17, 30)

        #expect(BubbleUpSchedule.date(for: .laterToday, now: fridayEvening, calendar: utcCalendar) == utc(2026, 11, 27, 20, 0))
    }

    @Test func weekendAndNextWeekAdvanceProperlyOnSaturdaySundayAndMonday() {
        let satEarly = utc(2026, 11, 28, 7, 0)
        let satLate = utc(2026, 11, 28, 9, 0)
        let sunday = utc(2026, 11, 29, 10, 0)
        let monday = utc(2026, 11, 30, 9, 0)

        #expect(BubbleUpSchedule.date(for: .thisWeekend, now: satEarly, calendar: utcCalendar) == utc(2026, 11, 28, 8, 0))
        #expect(BubbleUpSchedule.date(for: .thisWeekend, now: satLate, calendar: utcCalendar) == utc(2026, 12, 5, 8, 0))
        #expect(BubbleUpSchedule.date(for: .thisWeekend, now: sunday, calendar: utcCalendar) == utc(2026, 12, 5, 8, 0))
        #expect(BubbleUpSchedule.date(for: .nextWeek, now: monday, calendar: utcCalendar) == utc(2026, 12, 7, 8, 0))
    }

    @Test func surpriseMeUsesTheInjectedOffsetAndClampsToTwoThroughFourteenDays() {
        let friday = utc(2026, 11, 27, 11, 0)

        #expect(BubbleUpSchedule.date(for: .surpriseMe, now: friday, calendar: utcCalendar, randomDayOffset: 0) == utc(2026, 11, 29, 8, 0))
        #expect(BubbleUpSchedule.date(for: .surpriseMe, now: friday, calendar: utcCalendar, randomDayOffset: 1) == utc(2026, 11, 30, 14, 0))
        #expect(BubbleUpSchedule.date(for: .surpriseMe, now: friday, calendar: utcCalendar, randomDayOffset: 99) == utc(2026, 12, 11, 8, 0))
    }

    @Test func shortLabelFormatsWeekdayWithinSevenDaysAndMonthDateBeyond() {
        let friday = utc(2026, 11, 27, 11, 0)
        let locale = Locale(identifier: "en_US_POSIX")

        #expect(BubbleUpSchedule.shortLabel(for: utc(2026, 11, 27, 18, 0), now: friday, calendar: utcCalendar, locale: locale) == "Fri, 6pm")
        #expect(BubbleUpSchedule.shortLabel(for: utc(2026, 11, 28, 8, 30), now: friday, calendar: utcCalendar, locale: locale) == "Sat, 8:30am")
        #expect(BubbleUpSchedule.shortLabel(for: utc(2026, 12, 6, 8, 0), now: friday, calendar: utcCalendar, locale: locale) == "Dec 6, 8am")
    }
}

@Suite struct MailboxDirectoryTests {
    @Test func appFoldersGoUnderBridgesFoldersContainerWhenThereIsOne() {
        let bridge = MailboxDirectory(mailboxes: [
            Mailbox(path: "INBOX", name: "INBOX", role: .inbox),
            Mailbox(path: "Folders", name: "Folders", role: nil, isSelectable: false),
            Mailbox(path: "Folders/Work", name: "Work", role: nil),
        ])
        let plain = MailboxDirectory(mailboxes: [Mailbox(path: "INBOX", name: "INBOX", role: .inbox)])

        #expect(bridge.path(for: .setAside) == "Folders/Set Aside")
        #expect(plain.path(for: .setAside) == "Set Aside")
    }

    @Test func userFoldersAreGroupedUnderTheContainersTheServerKeepsThemIn() {
        let directory = MailboxDirectory(mailboxes: [
            Mailbox(path: "INBOX", name: "INBOX", role: .inbox),
            Mailbox(path: "Folders", name: "Folders", role: nil, isSelectable: false),
            Mailbox(path: "Folders/Work", name: "Work", role: nil),
            Mailbox(path: "Labels", name: "Labels", role: nil, isSelectable: false),
            Mailbox(path: "Labels/Urgent", name: "Urgent", role: nil),
            Mailbox(path: "Starred", name: "Starred", role: nil),
        ])

        let groups = directory.userFolderGroups()

        #expect(groups.map(\.title) == [nil, "Folders", "Labels"])
        #expect(groups.map { $0.mailboxes.map(\.path) } == [["Starred"], ["Folders/Work"], ["Labels/Urgent"]])
    }

    @Test func aServerWithNoContainersHasOneUnnamedGroup() {
        let directory = MailboxDirectory(mailboxes: [
            Mailbox(path: "INBOX", name: "INBOX", role: .inbox),
            Mailbox(path: "Work", name: "Work", role: nil),
            Mailbox(path: "Work/Project", name: "Project", role: nil),
        ])

        #expect(directory.userFolderGroups() == [MailboxGroup(title: nil, mailboxes: Array(directory.mailboxes.dropFirst()))])
    }

    @Test func userFoldersLeaveOutStandardMailboxesAndTheOnesTheAppUses() {
        let directory = MailboxDirectory(mailboxes: [
            Mailbox(path: "INBOX", name: "INBOX", role: .inbox),
            Mailbox(path: "Trash", name: "Trash", role: .trash),
            Mailbox(path: "Folders", name: "Folders", role: nil, isSelectable: false),
            Mailbox(path: "Folders/Reply Later", name: "Reply Later", role: nil),
            Mailbox(path: "Folders/Work", name: "Work", role: nil),
        ])

        #expect(directory.userFolders().map(\.path) == ["Folders/Reply Later", "Folders/Work"])
        #expect(directory.userFolders(excluding: ["Folders/Reply Later"]).map(\.path) == ["Folders/Work"])
    }

    @Test func aNewFolderGoesUnderBridgesContainerWhenThereIsOne() {
        let bridge = MailboxDirectory(mailboxes: [Mailbox(path: "Folders", name: "Folders", role: nil, isSelectable: false)])
        let plain = MailboxDirectory(mailboxes: [Mailbox(path: "INBOX", name: "INBOX", role: .inbox)])

        #expect(bridge.path(forNewFolderNamed: "Later") == "Folders/Later")
        #expect(plain.path(forNewFolderNamed: "Later") == "Later")
    }
}

@Suite struct OutgoingMailTests {
    private let mail = OutgoingMail(
        from: EmailAddress(name: "박찬희", address: "me@example.kr"),
        to: [jane],
        bcc: [EmailAddress(address: "secret@example.com")],
        subject: "점심 어때요?",
        textBody: "금요일?",
        htmlBody: "<div>금요일?</div>",
        inReplyTo: "<1@x>",
        references: ["<0@x>", "<1@x>"]
    )

    @Test func theMessageHasThreadingHeadersAndBothBodiesButNoBlindCopies() throws {
        let raw = mail.rfc5322(messageID: "<abc@example.kr>", date: Date(timeIntervalSince1970: 1_795_624_357))
        let text = String(decoding: raw, as: UTF8.self)

        #expect(!text.contains("secret@example.com"))
        #expect(text.contains("In-Reply-To: <1@x>\r\n"))
        #expect(text.contains("References: <0@x> <1@x>\r\n"))
        #expect(text.contains("To: \"Jane\" <jane@example.com>\r\n"))

        // Reading it back gives what was written, non-ASCII headers included.
        let parsed = MIMEMessage(raw)
        #expect(parsed.headers.text("subject") == "점심 어때요?")
        #expect(parsed.headers.addresses("from") == [EmailAddress(name: "박찬희", address: "me@example.kr")])
        #expect(parsed.html == "<div>금요일?</div>")
    }

    @Test func blindCopiesAreStillDelivered() {
        #expect(mail.recipients.map(\.address) == ["jane@example.com", "secret@example.com"])
    }

    @Test func aLineStartingWithADotIsStuffed() {
        let stuffed = SMTPClient.dotStuffed(Data("one\r\n.two\r\n..\r\n".utf8))

        #expect(String(decoding: stuffed, as: UTF8.self) == "one\r\n..two\r\n...")
    }

    @Test func sendingAuthenticatesAfterSTARTTLSAndNamesEveryRecipient() async throws {
        let server = ScriptedServer(greeting: "220 ready\r\n", [
            ("EHLO", "250-hello\r\n250 STARTTLS\r\n"),
            ("STARTTLS", "220 go\r\n"),
            ("EHLO", "250 AUTH PLAIN\r\n"),
            ("AUTH PLAIN", "235 ok\r\n"),
            ("MAIL FROM", "250 ok\r\n"),
            ("RCPT TO:<jane@example.com>", "250 ok\r\n"),
            ("RCPT TO:<secret@example.com>", "250 ok\r\n"),
            ("DATA", "354 go\r\n"),
            ("\r\n.\r\n", "250 queued\r\n"),
            ("QUIT", "221 bye\r\n"),
        ])

        try await SMTPClient.send(
            Data("Subject: x\r\n\r\nbody\r\n".utf8),
            from: "me@example.kr",
            to: ["jane@example.com", "secret@example.com"],
            via: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .startTLS),
            username: "me",
            password: "pw",
            using: server
        )

        #expect(server.didStartTLS)
        #expect(server.transcript.contains("AUTH PLAIN \(Data("\u{0}me\u{0}pw".utf8).base64EncodedString())\r\n"))
        #expect(server.transcript.contains("Subject: x\r\n\r\nbody\r\n.\r\n"))
    }

    @Test func aRefusedRecipientStopsTheSend() async {
        let server = ScriptedServer(greeting: "220 ready\r\n", [
            ("EHLO", "250 ok\r\n"),
            ("AUTH PLAIN", "235 ok\r\n"),
            ("MAIL FROM", "250 ok\r\n"),
            ("RCPT TO", "550 no such user\r\n"),
        ])

        await #expect(throws: MailError(.refused, "550 no such user")) {
            try await SMTPClient.send(
                Data("x".utf8), from: "me@example.kr", to: ["nobody@example.com"],
                via: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .none),
                username: "me", password: "pw", using: server
            )
        }
        #expect(!server.transcript.contains("DATA"))
    }
}

@Suite struct IMAPMailServiceTests {
    private let account = MailAccount(
        sender: EmailAddress(name: "Me", address: "me@example.com"),
        username: "me@example.com",
        imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .none),
        smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .none),
        serverSavesSentMail: true
    )

    private func service(_ replies: [(expects: String, reply: String)]) -> (IMAPMailService, ScriptedServer) {
        let server = ScriptedServer(greeting: "* OK ready\r\n", [
            ("LOGIN", "{tag} OK\r\n"),
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 MOVE\r\n{tag} OK\r\n"),
        ] + replies)
        return (IMAPMailService(account: account, password: "pw", connector: server), server)
    }

    @Test func requestsMadeAtTheSameTimeEachRunInTheirOwnMailbox() async throws {
        let service = IMAPMailService(account: account, password: "pw", connector: SelectingServer())
        let mailboxes = (1...12).map { "Folder \($0)" }

        let subjects = try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            for mailbox in mailboxes {
                group.addTask {
                    (mailbox, try await service.summaries(in: mailbox, olderThan: nil, limit: 10).messages.map(\.subject))
                }
            }
            var found: [String: [String]] = [:]
            for try await (mailbox, subjects) in group { found[mailbox] = subjects }
            return found
        }

        #expect(subjects == Dictionary(uniqueKeysWithValues: mailboxes.map { ($0, [$0]) }))
    }

    @Test func foldersGetRolesFromFlagsAndFromConventionalNames() async throws {
        let (service, _) = service([
            ("LIST", "* LIST () \"/\" INBOX\r\n* LIST (\\Sent) \"/\" \"Sent Mail\"\r\n* LIST () \"/\" Trash\r\n* LIST (\\Noselect) \"/\" Folders\r\n* LIST () \"/\" \"Folders/Work\"\r\n{tag} OK\r\n"),
        ])

        let directory = try await service.directory()

        #expect(directory.mailboxes.map(\.role) == [.inbox, .sent, .trash, nil, nil])
        #expect(directory.mailboxes.last?.name == "Work")
        #expect(directory.path(for: .replyLater) == "Folders/Reply Later")
        #expect(directory.userFolders().map(\.path) == ["Folders/Work"])
    }

    @Test func movedMailIsFoundAgainByItsMessageIDEveryCopyOfIt() async throws {
        let (service, server) = service([
            ("EXAMINE", "* 9 EXISTS\r\n{tag} OK\r\n"),
            ("UID SEARCH HEADER Message-ID \"<lunch@x>\"", "* SEARCH 41\r\n{tag} OK\r\n"),
            ("UID SEARCH HEADER Message-ID \"<gone@x>\"", "* SEARCH\r\n{tag} OK\r\n"),
            ("UID SEARCH HEADER Message-ID \"<twice@x>\"", "* SEARCH 12 44\r\n{tag} OK\r\n"),
        ])

        let found = try await service.find(messageIDs: ["<lunch@x>", "<gone@x>", "<twice@x>"], in: "Archive")

        #expect(found == [
            "<lunch@x>": [MessageSummary.ID(mailbox: "Archive", uid: 41)],
            "<twice@x>": [MessageSummary.ID(mailbox: "Archive", uid: 12), MessageSummary.ID(mailbox: "Archive", uid: 44)],
        ])
        #expect(server.transcript.contains("EXAMINE Archive") || server.transcript.contains("EXAMINE \"Archive\""))
    }

    @Test func aPageIsTheNewestMessagesWithSenderSubjectAndPreview() async throws {
        let header = "From: Jane <jane@example.com>\r\nSubject: Lunch\r\nMessage-ID: <5@x>\r\nContent-Type: text/plain\r\n\r\n"
        let (service, server) = service([
            ("EXAMINE", "* 3 EXISTS\r\n{tag} OK\r\n"),
            ("UID SEARCH ALL", "* SEARCH 3 4 5\r\n{tag} OK\r\n"),
            ("UID FETCH 4:5", "* 3 FETCH (UID 5 FLAGS () INTERNALDATE \"26-Nov-2026 01:32:37 +0900\" BODY[HEADER.FIELDS (FROM)] {\(header.utf8.count)}\r\n\(header) BODY[TEXT]<0> {12}\r\nAre you free)\r\n{tag} OK\r\n"),
        ])

        let page = try await service.summaries(in: "INBOX", olderThan: nil, limit: 2)

        #expect(page.hasMore)
        let message = try #require(page.messages.first)
        #expect(message.id == .init(mailbox: "INBOX", uid: 5))
        #expect(message.from == EmailAddress(name: "Jane", address: "jane@example.com"))
        #expect(message.subject == "Lunch")
        #expect(message.received == Date(timeIntervalSince1970: 1_795_624_357))
        #expect(message.preview == "Are you free")
        #expect(!message.isSeen)
        // Reading a list must never mark anything read.
        #expect(server.transcript.contains("BODY.PEEK[TEXT]<0.2048>"))
        #expect(!server.transcript.contains("SELECT"))
    }

    @Test func aFolderIsCreatedByItsPath() async throws {
        let (service, server) = service([("CREATE", "{tag} OK\r\n")])

        try await service.createMailbox("Folders/Set Aside")

        #expect(server.transcript.contains(#"CREATE "Folders/Set Aside""#))
    }

    @Test func aFolderTheServerWillNotMakeIsReportedWithItsReason() async {
        let (service, _) = service([("CREATE", "{tag} NO Label or folder with this name already exists\r\n")])

        await #expect(throws: MailError(.refused, "Label or folder with this name already exists")) {
            try await service.createMailbox("Folders/Reply Later")
        }
    }

    @Test func movingDoesNotTryToCreateTheDestination() async throws {
        let (service, server) = service([
            ("SELECT", "* 1 EXISTS\r\n{tag} OK\r\n"),
            ("UID MOVE", "{tag} OK\r\n"),
        ])

        try await service.move([.init(mailbox: "INBOX", uid: 7)], to: "Set Aside")

        #expect(server.transcript.contains(#"UID MOVE 7 "Set Aside""#))
        #expect(!server.transcript.contains("CREATE"))
    }

    @Test func aDroppedConnectionIsRedialledOnce() async throws {
        let first = ScriptedServer(greeting: "* OK ready\r\n", [
            ("LOGIN", "{tag} OK\r\n"),
            ("CAPABILITY", "{tag} OK\r\n"),
            ("LIST", "* LIST () \"/\" INBOX\r\n{tag} OK\r\n"),
        ])
        let second = ScriptedServer(greeting: "* OK ready\r\n", [
            ("LOGIN", "{tag} OK\r\n"),
            ("CAPABILITY", "{tag} OK\r\n"),
            ("LIST", "* LIST () \"/\" INBOX\r\n* LIST () \"/\" Archive\r\n{tag} OK\r\n"),
        ])
        let connector = SequentialConnector([first, second])
        let service = IMAPMailService(account: account, password: "pw", connector: connector)

        #expect(try await service.directory().mailboxes.count == 1)
        // The first server has nothing more to say: the next command finds it gone.
        #expect(try await service.directory().mailboxes.count == 2)
    }
}

/// A server that remembers which mailbox is selected, as a real one does, and answers
/// a fetch with a message whose subject is that mailbox's name. A summary's subject
/// therefore shows which mailbox its fetch really ran in.
final class SelectingServer: ByteStream, ByteStreamConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var outbox = [Data("* OK ready\r\n".utf8)]
    private var selected = ""

    func connect(to endpoint: ServerEndpoint) async throws(StreamError) -> any ByteStream { self }

    func read(timeout: TimeInterval) async throws(StreamError) -> Data {
        let next: Data? = lock.withLock { outbox.isEmpty ? nil : outbox.removeFirst() }
        guard let next else { throw StreamError("nothing to read: a reply went to another reader") }
        return next
    }

    func write(_ data: Data) async throws(StreamError) {
        let text = String(decoding: data, as: UTF8.self)
        guard let command = text.firstMatch(of: #/^(A\d+) (.*)\r\n$/#) else { return }
        let (tag, body) = (String(command.1), String(command.2))
        lock.withLock {
            var reply = ""
            if let mailbox = body.firstMatch(of: #/^EXAMINE "(.*)"$/#) {
                selected = String(mailbox.1)
                reply = "* 1 EXISTS\r\n"
            } else if body.hasPrefix("UID SEARCH") {
                reply = "* SEARCH 1\r\n"
            } else if body.hasPrefix("UID FETCH") {
                let header = "Subject: \(selected)\r\n\r\n"
                reply = "* 1 FETCH (UID 1 FLAGS () BODY[HEADER.FIELDS (SUBJECT)] {\(header.utf8.count)}\r\n\(header) BODY[TEXT]<0> \"\")\r\n"
            } else if body.hasPrefix("CAPABILITY") {
                reply = "* CAPABILITY IMAP4rev1\r\n"
            }
            outbox.append(Data("\(reply)\(tag) OK\r\n".utf8))
        }
    }

    func startTLS() async throws(StreamError) {}

    func close() {}
}

/// Hands out one scripted server per connection, in order.
final class SequentialConnector: ByteStreamConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [ScriptedServer]

    init(_ servers: [ScriptedServer]) {
        self.servers = servers
    }

    func connect(to endpoint: ServerEndpoint) async throws(StreamError) -> any ByteStream {
        let next: ScriptedServer? = lock.withLock { servers.isEmpty ? nil : servers.removeFirst() }
        guard let next else { throw StreamError("no server left") }
        return next
    }
}
