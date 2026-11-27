import Foundation
import Testing
@testable import HeydayKit

/// A mail account held in memory: mailboxes of raw messages, read back through the
/// app's own MIME parser as a real server's would be.
private actor MemoryAccount: MailService {
    private var mailboxes: [String: [(uid: UInt32, raw: Data)]]
    private var nextUID: UInt32 = 1
    private(set) var created: [String] = []
    private(set) var deleted: [MessageSummary.ID] = []

    init(mailboxes: [String] = ["INBOX"]) {
        self.mailboxes = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0, []) })
    }

    func count(in mailbox: String) -> Int { mailboxes[mailbox]?.count ?? 0 }

    func raw(in mailbox: String) -> [Data] { mailboxes[mailbox]?.map(\.raw) ?? [] }

    func directory() async throws(MailError) -> MailboxDirectory {
        let roles: [String: Mailbox.Role] = ["INBOX": .inbox, "Trash": .trash]
        return MailboxDirectory(mailboxes: mailboxes.keys.sorted().map { Mailbox(path: $0, name: $0, role: roles[$0]) })
    }

    func summaries(in mailbox: String, olderThan uid: UInt32?, limit: Int) async throws(MailError) -> SummaryPage {
        guard let messages = mailboxes[mailbox] else { throw MailError(.refused, "no such mailbox") }
        let summaries = messages.map { message in
            MessageSummary(id: .init(mailbox: mailbox, uid: message.uid), flags: [], received: nil, headers: MIMEMessage(message.raw).headers, partialBody: Data())
        }
        return SummaryPage(messages: Array(summaries.sorted { $0.id.uid > $1.id.uid }.prefix(limit)), hasMore: false)
    }

    func messages(_ ids: [MessageSummary.ID]) async throws(MailError) -> [FullMessage] {
        ids.compactMap { id in
            guard let message = mailboxes[id.mailbox]?.first(where: { $0.uid == id.uid }) else { return nil }
            let parsed = MIMEMessage(message.raw)
            return FullMessage(
                summary: MessageSummary(id: id, flags: [], received: nil, headers: parsed.headers, partialBody: Data()),
                html: parsed.html,
                attachments: parsed.attachments
            )
        }
    }

    func createMailbox(_ path: String) async throws(MailError) {
        guard mailboxes[path] == nil else { throw MailError(.refused, "already exists") }
        mailboxes[path] = []
        created.append(path)
    }

    func append(_ message: Data, to mailbox: String) async throws(MailError) {
        guard mailboxes[mailbox] != nil else { throw MailError(.refused, "no such mailbox") }
        mailboxes[mailbox]?.append((nextUID, message))
        nextUID += 1
    }

    func delete(_ ids: [MessageSummary.ID]) async throws(MailError) {
        for id in ids {
            mailboxes[id.mailbox]?.removeAll { $0.uid == id.uid }
            deleted.append(id)
        }
    }

    /// As on a real server, a moved message gets a new number where it lands.
    func move(_ ids: [MessageSummary.ID], to mailbox: String) async throws(MailError) {
        guard mailboxes[mailbox] != nil else { throw MailError(.refused, "no such mailbox") }
        for id in ids {
            guard let index = mailboxes[id.mailbox]?.firstIndex(where: { $0.uid == id.uid }) else { continue }
            let raw = mailboxes[id.mailbox]!.remove(at: index).raw
            mailboxes[mailbox]?.append((nextUID, raw))
            nextUID += 1
        }
    }

    func setSeen(_ seen: Bool, for ids: [MessageSummary.ID]) async throws(MailError) {}
    func search(_ query: String, in mailbox: String, limit: Int) async throws(MailError) -> [MessageSummary] { [] }
    func find(messageIDs: [String], in mailbox: String) async throws(MailError) -> [String: [MessageSummary.ID]] { [:] }
    func send(_ mail: OutgoingMail) async throws(MailError) { throw MailError(.refused, "not used") }
    func waitForChange(in mailbox: String) async throws(MailError) { throw MailError(.refused, "not used") }
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let jane = EmailAddress(address: "jane@example.com")
private let news = EmailAddress(address: "news@example.com")
private let owner = EmailAddress(name: "Me", address: "me@example.com")

private func rules(since: Date = start, _ decisions: (EmailAddress, SenderDecision, TimeInterval)...) -> SenderRules {
    var rules = SenderRules(screeningSince: since)
    for (sender, decision, after) in decisions {
        rules.decide(decision, for: sender, at: start.addingTimeInterval(after))
    }
    return rules
}

private func folders(_ assignments: (MailboxDirectory.AppFolder, String?, TimeInterval)...) -> FolderAssignments {
    var folders = FolderAssignments()
    for (folder, path, after) in assignments {
        folders.assign(path, to: folder, at: start.addingTimeInterval(after))
    }
    return folders
}

@Suite struct SenderRulesMergeTests {
    @Test func eachMacEndsUpWithEverySenderEitherDecidedAbout() {
        let here = rules((jane, .approved(.mebox), 10))
        let there = rules((news, .approved(.feed), 20))

        let merged = here.merged(with: there)

        #expect(merged.decisions == ["jane@example.com": .approved(.mebox), "news@example.com": .approved(.feed)])
        #expect(merged == there.merged(with: here))
    }

    @Test func whereTheyDisagreeTheLaterDecisionStandsWhicheverWayRound() {
        let earlier = rules((jane, .approved(.mebox), 10))
        let later = rules((jane, .screenedOut, 20))

        #expect(earlier.merged(with: later).decisions == ["jane@example.com": .screenedOut])
        #expect(later.merged(with: earlier).decisions == ["jane@example.com": .screenedOut])
    }

    @Test func decisionsMadeInTheSameSecondComeOutTheSameOnBothMacs() {
        let here = rules((jane, .approved(.feed), 10))
        let there = rules((jane, .approved(.paperTrail), 10.4))

        #expect(here.merged(with: there) == there.merged(with: here))
    }

    @Test func aDecisionTakenBackLaterLeavesTheSenderUndecidedOnBothMacs() {
        var here = rules((jane, .screenedOut, 10))
        let there = here
        here.withdrawDecision(for: jane, at: start.addingTimeInterval(20))

        #expect(here.decision(for: jane) == nil)
        #expect(here.merged(with: there).decision(for: jane) == nil)
        #expect(there.merged(with: here).decision(for: jane) == nil)
        #expect(here.merged(with: there) == there.merged(with: here))
    }

    @Test func aDecisionTakenBackInTheSameSecondItWasMadeStillCountsAsLater() {
        var here = rules((jane, .screenedOut, 10))
        let there = here
        here.withdrawDecision(for: jane, at: start.addingTimeInterval(10.4))

        #expect(here.merged(with: there).decision(for: jane) == nil)
        #expect(there.merged(with: here).decision(for: jane) == nil)
    }

    @Test func aDecisionChangedBackInTheSameSecondStandsAsLastSaid() {
        var here = rules((jane, .approved(.mebox), 5), (jane, .screenedOut, 10))
        let there = here
        here.decide(.approved(.mebox), for: jane, at: start.addingTimeInterval(10.2))

        #expect(here.merged(with: there).decision(for: jane) == .approved(.mebox))
        #expect(there.merged(with: here).decision(for: jane) == .approved(.mebox))
    }

    @Test func aDecisionMadeAfterOneWasTakenBackStands() {
        var here = rules((jane, .screenedOut, 10))
        here.withdrawDecision(for: jane, at: start.addingTimeInterval(20))
        let there = rules((jane, .approved(.feed), 30))

        #expect(here.merged(with: there).decision(for: jane) == .approved(.feed))
        #expect(there.merged(with: here).decision(for: jane) == .approved(.feed))
    }

    @Test func aDecisionTakenBackSurvivesBeingSavedAndRead() throws {
        var saved = rules((jane, .screenedOut, 10), (news, .approved(.feed), 11))
        saved.withdrawDecision(for: jane, at: start.addingTimeInterval(20))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let read = try decoder.decode(SenderRules.self, from: encoder.encode(saved))

        #expect(read == saved)
        #expect(read.merged(with: rules((jane, .screenedOut, 10))).decision(for: jane) == nil)
    }

    @Test func screeningStartedWhenTheFirstMacStartedIt() {
        let first = rules(since: start)
        let second = rules(since: start.addingTimeInterval(86_400))

        #expect(first.merged(with: second).screeningSince == start)
        #expect(second.merged(with: first).screeningSince == start)
    }

    @Test func mergingTheSameThingAgainChangesNothing() {
        let here = rules((jane, .approved(.mebox), 10))
        let there = rules((news, .screenedOut, 20))
        let merged = here.merged(with: there)

        #expect(merged.merged(with: there) == merged)
        #expect(merged.merged(with: here) == merged)
    }

    @Test func aDecisionSavedBeforeTimesWereKeptCountsAsTheOldest() throws {
        let saved = Data(#"{"decisions":{"jane@example.com":{"approved":{"_0":"imbox"}}},"screeningSince":"2027-01-15T08:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(SenderRules.self, from: saved)

        #expect(old.decisions == ["jane@example.com": .approved(.mebox)])
        #expect(old.merged(with: rules((jane, .screenedOut, 0))).decisions == ["jane@example.com": .screenedOut])
    }

    @Test func timesAreKeptToTheSecondSoACopyReadBackIsTheSame() throws {
        let precise = Date(timeIntervalSince1970: 1_800_000_000.75)
        var written = SenderRules(screeningSince: precise)
        written.decide(.approved(.feed), for: jane, at: precise)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(try decoder.decode(SenderRules.self, from: encoder.encode(written)) == written)
    }
}

@Suite struct FolderAssignmentsMergeTests {
    @Test func aFolderIsWhereTheMacThatSettledItLastLeftIt() {
        let here = folders((.replyLater, "Folders/Later", 10))
        let there = folders((.replyLater, "Labels/Reply Later", 20), (.setAside, "Folders/Aside", 5))

        let merged = here.merged(with: there)

        #expect(merged[.replyLater] == "Labels/Reply Later")
        #expect(merged[.setAside] == "Folders/Aside")
        #expect(merged == there.merged(with: here))
    }

    @Test func goingBackToAutomaticIsAChoiceOtherMacsFollow() {
        let here = folders((.replyLater, "Folders/Later", 10))
        let there = folders((.replyLater, "Folders/Later", 10), (.replyLater, nil, 30))

        #expect(here.merged(with: there)[.replyLater] == nil)
        #expect(there.merged(with: here)[.replyLater] == nil)
    }

    @Test func aFolderSettledBeforeTimesWereKeptStandsUntilItIsSettledAgain() throws {
        let old = try JSONDecoder().decode(FolderAssignments.self, from: Data(#"{"paths":{"Reply Later":"Labels/Reply Later"}}"#.utf8))

        #expect(FolderAssignments().merged(with: old)[.replyLater] == "Labels/Reply Later")
        #expect(old.merged(with: folders((.replyLater, "Folders/Later", 10)))[.replyLater] == "Folders/Later")
    }
}

@Suite struct RemoteChangesTests {
    @Test func whatAnotherMacDecidedJoinsTheDecisionsHereAndIsSaved() {
        let feature = RulesFeature()
        var state = RulesFeature.State()
        _ = feature.reduce(&state, .loaded(rules((jane, .approved(.mebox), 10)), at: start))

        let effects = feature.reduce(&state, .remoteArrived(rules((news, .screenedOut, 20))))

        #expect(state.rules?.decisions.count == 2)
        #expect(effects == state.rules.map { [.save($0)] })
        #expect(feature.reduce(&state, .remoteArrived(rules((news, .screenedOut, 20)))).isEmpty)
    }

    @Test func nothingFromAnotherMacIsTakenBeforeThisMacsOwnIsLoaded() {
        let feature = RulesFeature()
        var state = RulesFeature.State()

        #expect(feature.reduce(&state, .remoteArrived(rules((news, .screenedOut, 20)))).isEmpty)
        #expect(state.rules == nil)
    }

    @Test func whereAnotherMacKeepsAFolderIsFollowedHere() {
        let feature = AppFoldersFeature()
        var state = AppFoldersFeature.State()
        _ = feature.reduce(&state, .loaded(nil))
        let remote = folders((.replyLater, "Labels/Reply Later", 10))

        #expect(feature.reduce(&state, .remoteArrived(remote)) == [.save(remote)])
        #expect(state.assignments?[.replyLater] == "Labels/Reply Later")
        #expect(feature.reduce(&state, .remoteArrived(remote)).isEmpty)
    }
}

@Suite struct MailDocumentStoreTests {
    private func store(_ account: MemoryAccount, uuid: UUID = UUID()) -> MailDocumentStore<SyncedState> {
        MailDocumentStore(service: account, mailbox: "Heyday", name: "state", owner: owner, now: { start }, uuid: { uuid })
    }

    private let state = SyncedState(rules: rules((jane, .approved(.feed), 10)), folders: folders((.setAside, "Folders/Aside", 5)))

    @Test func anAccountNothingWasSavedInHoldsNothingAndIsLeftAlone() async throws {
        let account = MemoryAccount()

        #expect(try await store(account).load() == nil)
        #expect(await account.created.isEmpty)
    }

    @Test func whatOneMacSavesAnotherReads() async throws {
        let account = MemoryAccount()

        try await store(account).save(state)

        #expect(await account.created == ["Heyday"])
        #expect(await account.count(in: "Heyday") == 1)
        #expect(try await store(account).load() == state)
    }

    @Test func theMessageSaysWhatItIsAndCarriesTheDataAsAnAttachment() async throws {
        let account = MemoryAccount()
        try await store(account, uuid: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!).save(state)

        let raw = try #require(await account.raw(in: "Heyday").first)
        let message = MIMEMessage(raw)

        #expect(message.headers.messageIDs("message-id") == ["<state.00000000-0000-0000-0000-00000000000a@sync.heyday.invalid>"])
        #expect(message.headers.text("subject") == "Heyday data (state)")
        #expect(message.headers.addresses("from").map(\.address) == ["me@example.com"])
        #expect(message.html.contains("Deleting it does no harm."))
        #expect(message.attachments.map(\.filename) == ["heyday-state.json"])
    }

    @Test func savingAgainLeavesOneCopy() async throws {
        let account = MemoryAccount()
        var changed = state
        changed.rules = state.rules?.merged(with: rules((news, .screenedOut, 30)))

        try await store(account).save(state)
        try await store(account).save(changed)

        #expect(await account.count(in: "Heyday") == 1)
        #expect(await account.deleted.count == 1)
        #expect(try await store(account).load() == changed)
    }

    @Test func anEarlierCopyLeavesTheAccountThroughTheTrash() async throws {
        let account = MemoryAccount(mailboxes: ["INBOX", "Trash"])
        var changed = state
        changed.rules = state.rules?.merged(with: rules((news, .screenedOut, 30)))
        let other = Data("From: someone@example.com\r\nSubject: Thrown away\r\nMessage-ID: <abc@example.com>\r\n\r\nHi.\r\n".utf8)
        try await account.append(other, to: "Trash")

        try await store(account).save(state)
        try await store(account).save(changed)

        #expect(await account.count(in: "Heyday") == 1)
        // Removed from the trash too, and nothing else there was touched.
        #expect(await account.raw(in: "Trash") == [other])
        #expect(await account.deleted.map(\.mailbox) == ["Trash"])
        #expect(try await store(account).load() == changed)
    }

    @Test func copiesLeftByTwoMacsSavingAtOnceAreReadTogether() async throws {
        let account = MemoryAccount()
        let fromThisMac = SyncedState(rules: rules((jane, .approved(.feed), 10)), folders: nil)
        let fromTheOther = SyncedState(rules: rules((news, .screenedOut, 20)), folders: folders((.replyLater, "Folders/Later", 5)))
        try await store(account).save(fromThisMac)
        // The other Mac listed the mailbox before this copy arrived, so its own
        // save removed nothing: its message is written elsewhere and added as it is.
        let elsewhere = MemoryAccount(mailboxes: ["INBOX", "Heyday"])
        try await store(elsewhere).save(fromTheOther)
        try await account.append(try #require(await elsewhere.raw(in: "Heyday").first), to: "Heyday")

        #expect(await account.count(in: "Heyday") == 2)
        #expect(try await store(account).load() == fromThisMac.merged(with: fromTheOther))
    }

    @Test func mailThatIsNotACopyIsNeitherReadNorRemoved() async throws {
        let account = MemoryAccount(mailboxes: ["INBOX", "Heyday"])
        let stray = Data("From: someone@example.com\r\nSubject: Hello\r\nMessage-ID: <abc@example.com>\r\n\r\nHi.\r\n".utf8)
        try await account.append(stray, to: "Heyday")

        #expect(try await store(account).load() == nil)
        try await store(account).save(state)
        try await store(account).save(state)

        #expect(await account.raw(in: "Heyday").contains(stray))
        #expect(await account.count(in: "Heyday") == 2)
    }

    @Test func aCopyWrittenByANewerVersionIsNotReadAsNothing() async throws {
        let account = MemoryAccount()
        try await store(account).save(state)
        let raw = try #require(await account.raw(in: "Heyday").first)
        let json = try #require(MIMEMessage(raw).attachments.first?.data)
        let newer = String(decoding: json, as: UTF8.self).replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        let rewritten = String(decoding: raw, as: UTF8.self).replacingOccurrences(
            of: TransferEncoding.encodeBase64(json), with: TransferEncoding.encodeBase64(Data(newer.utf8))
        )
        let other = MemoryAccount(mailboxes: ["INBOX", "Heyday"])
        try await other.append(Data(rewritten.utf8), to: "Heyday")

        do throws(MailError) {
            _ = try await store(other).load()
            Issue.record("a newer copy was read")
        } catch {
            #expect(error.kind == .garbled)
        }
    }

    @Test func theAppsOwnMessagesAreToldFromMail() {
        let copy = MessageSummary(id: .init(mailbox: "All Mail", uid: 1), messageID: "<state.abc@sync.heyday.invalid>")
        let mail = MessageSummary(id: .init(mailbox: "All Mail", uid: 2), messageID: "<abc@example.com>")

        #expect(copy.isAppData)
        #expect(!mail.isAppData)
        #expect(!MessageSummary(id: .init(mailbox: "All Mail", uid: 3)).isAppData)
    }
}

@Suite struct SyncFeatureTests {
    private let feature = SyncFeature()
    private let here = SyncedState(rules: rules((jane, .approved(.mebox), 10)), folders: FolderAssignments())
    private let there = SyncedState(rules: rules((news, .screenedOut, 20)), folders: FolderAssignments())
    private let later = start.addingTimeInterval(600)

    @Test func theFirstMacWritesWhatItHoldsToTheAccount() {
        var state = SyncFeature.State()

        #expect(feature.reduce(&state, .requested(here)) == [.pull])
        #expect(state.status == .running)
        #expect(feature.reduce(&state, .pulled(.success(nil), at: later)) == [.push(here)])
        #expect(feature.reduce(&state, .pushed(nil, at: later)).isEmpty)
        #expect(state.status == .upToDate(later))
    }

    @Test func aNewMacTakesWhatTheAccountHoldsAndWritesNothingBack() {
        var state = SyncFeature.State()
        let fresh = SyncedState(rules: rules(since: later), folders: FolderAssignments())
        let kept = SyncedState(rules: rules((news, .screenedOut, 20)), folders: FolderAssignments())
        _ = feature.reduce(&state, .requested(fresh))

        #expect(feature.reduce(&state, .pulled(.success(kept), at: later)) == [.adopt(kept)])
        #expect(state.status == .upToDate(later))
    }

    @Test func whenBothHaveSomethingNewEachGetsTheOthers() {
        var state = SyncFeature.State()
        let merged = here.merged(with: there)
        _ = feature.reduce(&state, .requested(here))

        #expect(feature.reduce(&state, .pulled(.success(there), at: later)) == [.adopt(merged), .push(merged)])
        #expect(state.status == .running)
    }

    @Test func whenTheyHoldTheSameNothingIsWrittenOrHandedOn() {
        var state = SyncFeature.State()
        _ = feature.reduce(&state, .requested(here))

        #expect(feature.reduce(&state, .pulled(.success(here), at: later)).isEmpty)
        #expect(state.status == .upToDate(later))
    }

    @Test func aChangeMadeDuringARoundTripGoesRoundNext() {
        var state = SyncFeature.State()
        let changed = SyncedState(rules: here.rules?.merged(with: rules((news, .approved(.feed), 30))), folders: FolderAssignments())
        _ = feature.reduce(&state, .requested(here))

        #expect(feature.reduce(&state, .requested(changed)).isEmpty)
        #expect(feature.reduce(&state, .pulled(.success(here), at: later)) == [.pull])
        #expect(state.status == .running)
        #expect(feature.reduce(&state, .pulled(.success(here), at: later)) == [.push(changed)])
    }

    @Test func aFailureIsReportedAndTheNextRequestTriesAgain() {
        var state = SyncFeature.State()
        let offline = MailError(.unreachable, "offline")
        _ = feature.reduce(&state, .requested(here))

        #expect(feature.reduce(&state, .pulled(.failure(offline), at: later)).isEmpty)
        #expect(state.status == .failed(offline))
        #expect(feature.reduce(&state, .requested(here)) == [.pull])

        _ = feature.reduce(&state, .pulled(.success(nil), at: later))
        _ = feature.reduce(&state, .pushed(MailError(.refused, "no"), at: later))
        #expect(state.status == .failed(MailError(.refused, "no")))
    }

    @Test func twoMacsThatEachDecidedEndUpHoldingTheSame() async throws {
        let account = MemoryAccount()
        let store = MailDocumentStore<SyncedState>(service: account, mailbox: "Heyday", name: "state", owner: owner)

        // What each Mac holds, and one round trip for it: pull, merge, push if the account lacks anything.
        func roundTrip(_ local: SyncedState) async throws -> SyncedState {
            let remote = try await store.load()
            let merged = remote.map(local.merged) ?? local
            if merged != remote { try await store.save(merged) }
            return merged
        }

        var first = here
        var second = there
        first = try await roundTrip(first)
        second = try await roundTrip(second)
        first = try await roundTrip(first)

        #expect(first == second)
        #expect(first.rules?.decisions.count == 2)
        #expect(await account.count(in: "Heyday") == 1)
    }
}

@Suite struct NotificationRulesTests {
    private func mail(_ uid: UInt32, from sender: EmailAddress, root: String, seen: Bool = false) -> MessageSummary {
        MessageSummary(id: .init(mailbox: "INBOX", uid: uid), messageID: "<\(uid)@example.com>", threadRoot: root, from: sender, isSeen: seen)
    }

    private func conversation(_ messages: MessageSummary...) -> Conversation {
        Conversation.group(messages)[0]
    }

    @Test func mailIsQuietUnlessNotificationsWereTurnedOn() {
        let rules = NotificationRules()

        #expect(!rules.announces(conversation(mail(1, from: jane, root: "<a>"))))
        #expect(rules.notifyingSenders.isEmpty)
    }

    @Test func aSenderCanBeTurnedOnAndOffAgain() {
        var rules = NotificationRules()
        rules.setNotifying(true, about: EmailAddress(address: "Jane@Example.com"), at: start)

        #expect(rules.notifies(about: jane))
        #expect(rules.announces(conversation(mail(1, from: jane, root: "<a>"))))
        #expect(!rules.announces(conversation(mail(2, from: news, root: "<b>"))))
        #expect(rules.notifyingSenders == ["jane@example.com"])

        rules.setNotifying(false, about: jane, at: start.addingTimeInterval(60))
        #expect(!rules.announces(conversation(mail(1, from: jane, root: "<a>"))))
        #expect(rules.notifyingSenders.isEmpty)
    }

    @Test func aConversationCanBeFollowedWhoeverWritesInIt() {
        var rules = NotificationRules()
        rules.setNotifying(true, aboutConversation: "<a>", at: start)

        #expect(rules.announces(conversation(mail(1, from: news, root: "<a>"))))
        #expect(!rules.announces(conversation(mail(2, from: news, root: "<b>"))))
        #expect(rules.notifyingConversationCount == 1)

        rules.silenceConversations(at: start.addingTimeInterval(60))
        #expect(!rules.announces(conversation(mail(1, from: news, root: "<a>"))))
        #expect(rules.notifyingConversationCount == 0)
    }

    @Test func aSendersMailThatWasAlreadyReadIsNotWhatMakesAConversationNews() {
        var rules = NotificationRules()
        rules.setNotifying(true, about: jane, at: start)

        // Jane's message was read; the unread one is from someone nobody asked about.
        let thread = conversation(mail(1, from: jane, root: "<a>", seen: true), mail(2, from: news, root: "<a>"))

        #expect(!rules.announces(thread))
    }

    @Test func twoDevicesAgreeOnWhicheverSwitchWasThrownLast() {
        var here = NotificationRules()
        here.setNotifying(true, about: jane, at: start)
        var there = NotificationRules()
        there.setNotifying(true, about: jane, at: start)
        there.setNotifying(false, about: jane, at: start.addingTimeInterval(60))
        there.setNotifying(true, aboutConversation: "<a>", at: start)

        let merged = here.merged(with: there)

        #expect(!merged.notifies(about: jane))
        #expect(merged.notifies(aboutConversation: "<a>"))
        #expect(merged == there.merged(with: here))
        #expect(merged.merged(with: here) == merged)
    }

    @Test func theChoicesTravelWithTheRestOfWhatIsSynced() {
        var asked = NotificationRules()
        asked.setNotifying(true, about: jane, at: start)
        let here = SyncedState(rules: rules(), folders: FolderAssignments(), notifications: NotificationRules())
        let there = SyncedState(rules: rules(), folders: FolderAssignments(), notifications: asked)

        #expect(here.merged(with: there).notifications == asked)
        // A copy written before notifications were kept leaves this device's own alone.
        #expect(there.merged(with: SyncedState(rules: rules(), folders: nil)).notifications == asked)
    }
}

@Suite struct NotificationsFeatureTests {
    private let feature = NotificationsFeature()

    private var loaded: NotificationsFeature.State {
        var state = NotificationsFeature.State()
        _ = feature.reduce(&state, .loaded(nil))
        return state
    }

    @Test func turningOneOnIsSavedAndAsksForLeaveToNotify() {
        var state = loaded

        let effects = feature.reduce(&state, .senderSwitched(jane, isOn: true, at: start))

        #expect(state.rules?.notifies(about: jane) == true)
        #expect(effects == state.rules.map { [.save($0), .askToNotify] })
    }

    @Test func turningOneOffIsSavedWithoutAsking() {
        var state = loaded
        _ = feature.reduce(&state, .conversationSwitched("<a>", isOn: true, at: start))

        let effects = feature.reduce(&state, .conversationSwitched("<a>", isOn: false, at: start.addingTimeInterval(60)))

        #expect(state.rules?.notifies(aboutConversation: "<a>") == false)
        #expect(effects == state.rules.map { [.save($0)] })
    }

    @Test func nothingIsChosenBeforeTheSavedChoicesAreLoaded() {
        var state = NotificationsFeature.State()

        #expect(feature.reduce(&state, .loadRequested) == [.load])
        #expect(feature.reduce(&state, .senderSwitched(jane, isOn: true, at: start)).isEmpty)
        #expect(state.rules == nil)
    }

    @Test func whatAnotherDeviceChoseIsTakenInAndSaved() {
        var state = loaded
        var remote = NotificationRules()
        remote.setNotifying(true, about: news, at: start)

        #expect(feature.reduce(&state, .remoteArrived(remote)) == [.save(remote)])
        #expect(feature.reduce(&state, .remoteArrived(remote)).isEmpty)
    }
}

@Suite struct BoxVisitsTests {
    @Test func markVisitedAdvancesMonotonicallyAndMergesByLatestTime() {
        var here = BoxVisits()
        here.markVisited(.paperTrail, at: start.addingTimeInterval(60.7))
        // An older timestamp must not move the watermark backward.
        here.markVisited(.paperTrail, at: start.addingTimeInterval(10))
        #expect(here.lastVisited(.paperTrail) == start.addingTimeInterval(60))
        #expect(here.lastVisited(.feed) == nil)

        var there = BoxVisits()
        there.markVisited(.paperTrail, at: start.addingTimeInterval(180))
        there.markVisited(.feed, at: start.addingTimeInterval(30))

        let merged = here.merged(with: there)
        #expect(merged.lastVisited(.paperTrail) == start.addingTimeInterval(180))
        #expect(merged.lastVisited(.feed) == start.addingTimeInterval(30))
        #expect(merged == there.merged(with: here))
        #expect(merged.merged(with: here) == merged)
    }

    @Test func visitsTravelWithSyncedStateAndStayCompatibleWithOlderCopies() {
        var visited = BoxVisits()
        visited.markVisited(.paperTrail, at: start.addingTimeInterval(120))
        let here = SyncedState(rules: rules(), folders: FolderAssignments(), visits: BoxVisits())
        let there = SyncedState(rules: rules(), folders: FolderAssignments(), visits: visited)

        #expect(here.merged(with: there).visits == visited)
        #expect(there.merged(with: SyncedState(rules: rules(), folders: nil)).visits == visited)
    }
}

@Suite struct BoxVisitsFeatureTests {
    private let feature = BoxVisitsFeature()

    private var loaded: BoxVisitsFeature.State {
        var state = BoxVisitsFeature.State()
        _ = feature.reduce(&state, .loaded(nil))
        return state
    }

    @Test func visitingAdvancesAndSavesOnlyWhenNewer() {
        var state = loaded

        let first = feature.reduce(&state, .visited(.paperTrail, at: start.addingTimeInterval(60)))
        #expect(first == state.visits.map { [.save($0)] })

        // Same or older timestamp does not rewrite disk or trigger sync.
        #expect(feature.reduce(&state, .visited(.paperTrail, at: start.addingTimeInterval(60))).isEmpty)
        #expect(feature.reduce(&state, .visited(.paperTrail, at: start.addingTimeInterval(30))).isEmpty)
    }

    @Test func remoteVisitsMergeAndSaveOnlyWhenNewer() {
        var state = loaded
        var remote = BoxVisits()
        remote.markVisited(.feed, at: start.addingTimeInterval(90))

        #expect(feature.reduce(&state, .remoteArrived(remote)) == [.save(remote)])
        #expect(feature.reduce(&state, .remoteArrived(remote)).isEmpty)
    }
}

@Suite struct BubbleUpRulesTests {
    @Test func schedulingAndDismissingTrackTheNextFutureDueDateAndPersist() throws {
        var rules = BubbleUpRules()
        let past = BubbleUp(dueAt: start.addingTimeInterval(-60), scheduledAt: start.addingTimeInterval(-120))
        let sooner = BubbleUp(dueAt: start.addingTimeInterval(300), scheduledAt: start)
        let later = BubbleUp(dueAt: start.addingTimeInterval(900), scheduledAt: start)

        rules.schedule(past, for: "<past>", at: start)
        rules.schedule(later, for: "<later>", at: start)
        rules.schedule(sooner, for: "<sooner>", at: start)

        #expect(rules.nextDueDate(after: start) == start.addingTimeInterval(300))

        rules.dismiss(for: "<sooner>", at: start.addingTimeInterval(10))
        #expect(rules.bubbleUp(for: "<sooner>") == nil)
        #expect(rules.nextDueDate(after: start) == start.addingTimeInterval(900))

        let url = FileManager.default.temporaryDirectory.appending(path: "heyday-tests-\(UUID().uuidString)/bubbleups.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFileStore<BubbleUpRules>(url: url)
        try store.save(rules)
        #expect(try store.load() == rules)
    }

    @Test func twoDevicesAgreeOnLastScheduleOrDismissEvenInTheSameSecond() {
        let due = start.addingTimeInterval(3600)
        var here = BubbleUpRules()
        here.schedule(BubbleUp(dueAt: due, condition: .always, scheduledAt: start), for: "<a>", at: start)

        var dismissed = here
        dismissed.dismiss(for: "<a>", at: start.addingTimeInterval(20))

        #expect(here.merged(with: dismissed).bubbleUp(for: "<a>") == nil)
        #expect(dismissed.merged(with: here).bubbleUp(for: "<a>") == nil)

        var rescheduled = dismissed
        let laterEntry = BubbleUp(dueAt: due.addingTimeInterval(3600), condition: .ifNoReply, baselineMessageCount: 2, scheduledAt: start.addingTimeInterval(30))
        rescheduled.schedule(laterEntry, for: "<a>", at: start.addingTimeInterval(30))
        #expect(dismissed.merged(with: rescheduled).bubbleUp(for: "<a>") == laterEntry)
        #expect(rescheduled.merged(with: dismissed).bubbleUp(for: "<a>") == laterEntry)

        // Same-second conflict with identical dueAt but differing conditions stays commutative.
        var one = BubbleUpRules()
        one.schedule(BubbleUp(dueAt: due, condition: .always, scheduledAt: start), for: "<b>", at: start)
        var two = BubbleUpRules()
        two.schedule(BubbleUp(dueAt: due, condition: .ifNoReply, baselineMessageCount: 1, scheduledAt: start), for: "<b>", at: start)

        let ab = one.merged(with: two)
        let ba = two.merged(with: one)
        #expect(ab == ba)
        #expect(ab.merged(with: one) == ab)
        #expect(ab.merged(with: two) == ab)
    }

    @Test func bubbleUpsTravelWithSyncedStateAndStayCompatibleWithOlderCopies() {
        var scheduled = BubbleUpRules()
        scheduled.schedule(BubbleUp(dueAt: start.addingTimeInterval(3600), scheduledAt: start), for: "<a>", at: start)
        let here = SyncedState(rules: rules(), folders: FolderAssignments(), bubbleUps: BubbleUpRules())
        let there = SyncedState(rules: rules(), folders: FolderAssignments(), bubbleUps: scheduled)

        #expect(here.merged(with: there).bubbleUps == scheduled)
        #expect(there.merged(with: SyncedState(rules: rules(), folders: nil)).bubbleUps == scheduled)
    }
}

@Suite struct BubbleUpFeatureTests {
    private let feature = BubbleUpFeature()

    private var loaded: BubbleUpFeature.State {
        var state = BubbleUpFeature.State()
        _ = feature.reduce(&state, .loaded(nil))
        return state
    }

    @Test func schedulingAndDismissingSaveImmediatelyOnceLoaded() {
        var unloaded = BubbleUpFeature.State()
        let entry = BubbleUp(dueAt: start.addingTimeInterval(3600), scheduledAt: start)
        #expect(feature.reduce(&unloaded, .loadRequested) == [.load])
        #expect(feature.reduce(&unloaded, .scheduled("<a>", entry, at: start)).isEmpty)

        var state = loaded
        let scheduledEffects = feature.reduce(&state, .scheduled("<a>", entry, at: start))
        #expect(state.rules?.bubbleUp(for: "<a>") == entry)
        #expect(scheduledEffects == state.rules.map { [.save($0)] })

        let dismissedEffects = feature.reduce(&state, .dismissed("<a>", at: start.addingTimeInterval(10)))
        #expect(state.rules?.bubbleUp(for: "<a>") == nil)
        #expect(dismissedEffects == state.rules.map { [.save($0)] })

        // Dismissing a conversation with no active Bubble Up does nothing.
        #expect(feature.reduce(&state, .dismissed("<a>", at: start.addingTimeInterval(20))).isEmpty)
    }

    @Test func remoteBubbleUpsMergeAndSaveOnlyWhenChanged() {
        var state = loaded
        var remote = BubbleUpRules()
        remote.schedule(BubbleUp(dueAt: start.addingTimeInterval(1800), scheduledAt: start), for: "<a>", at: start)

        #expect(feature.reduce(&state, .remoteArrived(remote)) == [.save(remote)])
        #expect(feature.reduce(&state, .remoteArrived(remote)).isEmpty)
    }
}
