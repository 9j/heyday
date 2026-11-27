import Foundation
import Testing
@testable import HeydayKit

private func message(_ uid: UInt32, seen: Bool = true) -> MessageSummary {
    MessageSummary(id: .init(mailbox: "INBOX", uid: uid), from: EmailAddress(address: "a\(uid)@example.com"), subject: "S\(uid)", isSeen: seen)
}

private func page(_ uids: [UInt32], hasMore: Bool = false) -> SummaryPage {
    SummaryPage(messages: uids.map { message($0) }, hasMore: hasMore)
}

@Suite struct NavigationFeatureTests {
    private let feature = NavigationFeature()

    @Test func theAppStartsOnMeboxWithNothingSelected() {
        let state = NavigationFeature.State()

        #expect(state.listing == .box(.mebox))
        #expect(state.search == nil)
        #expect(state.selection.isEmpty)
    }

    @Test func choosingAnotherListDropsTheSelectionAndTheSearch() {
        var state = NavigationFeature.State()
        _ = feature.reduce(&state, .searched("invoice"))
        _ = feature.reduce(&state, .selectionChanged(["a"]))
        _ = feature.reduce(&state, .conversationRead("a"))

        _ = feature.reduce(&state, .listingChosen(.box(.feed)))

        #expect(state.listing == .box(.feed))
        #expect(state.search == nil)
        #expect(state.selection.isEmpty)
        #expect(state.readThisVisit.isEmpty)
    }

    @Test func choosingTheListAlreadyShownKeepsTheSelection() {
        var state = NavigationFeature.State()
        _ = feature.reduce(&state, .selectionChanged(["a"]))

        _ = feature.reduce(&state, .listingChosen(.box(.mebox)))

        #expect(state.selection == ["a"])
    }

    @Test func aSearchCoversTheListUntilItIsDismissedOrEmptied() {
        var state = NavigationFeature.State()
        _ = feature.reduce(&state, .listingChosen(.box(.paperTrail)))

        _ = feature.reduce(&state, .searched("  receipt "))
        #expect(state.search == "receipt")
        #expect(state.listing == .box(.paperTrail))

        _ = feature.reduce(&state, .searched(" "))
        #expect(state.search == nil)
    }

    @Test func whenTheSelectedRowLeavesTheOneBelowIsSelected() {
        var state = NavigationFeature.State()
        _ = feature.reduce(&state, .selectionChanged(["b"]))

        _ = feature.reduce(&state, .conversationsLeft(listBefore: ["a", "b", "c"], listAfter: ["a", "c"]))

        #expect(state.selection == ["c"])
    }

    @Test func whenTheLastRowLeavesTheOneAboveIsSelected() {
        var state = NavigationFeature.State()
        _ = feature.reduce(&state, .selectionChanged(["b", "c"]))

        _ = feature.reduce(&state, .conversationsLeft(listBefore: ["a", "b", "c"], listAfter: ["a"]))

        #expect(state.selection == ["a"])
    }

    @Test func rowsLeavingElsewhereDoNotMoveTheSelection() {
        var state = NavigationFeature.State()
        _ = feature.reduce(&state, .selectionChanged(["a"]))

        _ = feature.reduce(&state, .conversationsLeft(listBefore: ["a", "b"], listAfter: ["a"]))

        #expect(state.selection == ["a"])
    }

    @Test func visitCutoffIsCapturedOncePerVisitAndClearedOnLeaving() {
        var state = NavigationFeature.State()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_600)

        #expect(state.visitCutoff == .pending)
        _ = feature.reduce(&state, .visitCutoffCaptured(first))
        #expect(state.visitCutoff == .captured(first))

        // A later update during the same visit must not move the divider.
        _ = feature.reduce(&state, .visitCutoffCaptured(later))
        #expect(state.visitCutoff == .captured(first))

        _ = feature.reduce(&state, .listingChosen(.box(.paperTrail)))
        #expect(state.visitCutoff == .pending)
    }
}

@Suite struct MeboxSectionsTests {
    private func conversation(_ uid: UInt32, seen: Bool) -> Conversation {
        Conversation.group([message(uid, seen: seen)])[0]
    }

    @Test func aConversationReadThisVisitStaysUnderNew() {
        let unread = conversation(3, seen: false)
        let justRead = conversation(2, seen: true)
        let old = conversation(1, seen: true)

        let sections = MeboxSections([unread, justRead, old], readThisVisit: [justRead.id])

        #expect(sections.new == [unread, justRead])
        #expect(sections.seen == [old])
        #expect(sections.all == [unread, justRead, old])
    }
}

@Suite struct VisitedBoxSectionsTests {
    private let cutoff = Date(timeIntervalSince1970: 1_700_000_000)

    private func conversation(_ uid: UInt32, receivedOffset: TimeInterval) -> Conversation {
        let summary = MessageSummary(
            id: .init(mailbox: "INBOX", uid: uid),
            from: EmailAddress(address: "a\(uid)@example.com"),
            subject: "S\(uid)",
            received: cutoff.addingTimeInterval(receivedOffset),
            isSeen: true
        )
        return Conversation.group([summary])[0]
    }

    @Test func firstVisitHasNoNewSectionYet() {
        let recent = conversation(2, receivedOffset: 60)
        let older = conversation(1, receivedOffset: -60)

        let sections = VisitedBoxSections([recent, older], lastVisited: nil)

        #expect(sections.new.isEmpty)
        #expect(sections.earlier == [recent, older])
    }

    @Test func subsequentVisitSplitsStrictlyAfterTheSavedSecond() {
        let fresh = conversation(3, receivedOffset: 10)
        // Same second as the cutoff (even with fractional seconds) was already seen.
        let sameSecond = conversation(2, receivedOffset: 0.4)
        let older = conversation(1, receivedOffset: -120)

        let sections = VisitedBoxSections([fresh, sameSecond, older], lastVisited: cutoff)

        #expect(sections.new == [fresh])
        #expect(sections.earlier == [sameSecond, older])
        #expect(sections.all == [fresh, sameSecond, older])
    }

    @Test func watermarkAdvancesPastServerClockSkew() {
        let aheadOfClock = conversation(2, receivedOffset: 45)
        let now = cutoff.addingTimeInterval(10)

        let watermark = VisitedBoxSections.watermark(for: [aheadOfClock], now: now)

        #expect(watermark == aheadOfClock.latest.received)
        #expect(VisitedBoxSections([aheadOfClock], lastVisited: watermark).new.isEmpty)
    }
}

@Suite struct MailboxFeatureTests {
    private let feature = MailboxFeature()

    /// A mailbox that asked for its mail and got these messages.
    private func loaded(_ uids: [UInt32], hasMore: Bool = false) -> MailboxFeature.State {
        var state = MailboxFeature.State(mailbox: "INBOX")
        _ = feature.reduce(&state, .refreshRequested)
        _ = feature.reduce(&state, .pageLoaded(.success(page(uids, hasMore: hasMore))))
        return state
    }

    @Test func aFailedFirstLoadIsShownButAFailedRefreshKeepsTheList() {
        var empty = MailboxFeature.State(mailbox: "INBOX")
        _ = feature.reduce(&empty, .refreshRequested)
        _ = feature.reduce(&empty, .pageLoaded(.failure(MailError(.unreachable))))
        #expect(empty.content == .unavailable(MailError(.unreachable)))

        var full = loaded([2, 1])
        _ = feature.reduce(&full, .refreshRequested)
        _ = feature.reduce(&full, .pageLoaded(.failure(MailError(.unreachable))))
        #expect(full.messages.map(\.id.uid) == [2, 1])
    }

    @Test func refreshingReReadsAsFarBackAsIsOnScreen() {
        var state = loaded(Array((1...200).reversed()), hasMore: true)

        #expect(feature.reduce(&state, .refreshRequested) == [.load(mailbox: "INBOX", limit: 200)])
    }

    @Test func aRefreshIsUnderWayUntilItsPageComesBackOrFails() {
        var state = loaded([3, 2, 1])
        #expect(!state.isRefreshing)

        _ = feature.reduce(&state, .refreshRequested)
        #expect(state.isRefreshing)
        _ = feature.reduce(&state, .pageLoaded(.success(page([4, 3, 2, 1]))))
        #expect(!state.isRefreshing)

        _ = feature.reduce(&state, .refreshRequested)
        _ = feature.reduce(&state, .pageLoaded(.failure(MailError(.unreachable))))
        #expect(!state.isRefreshing)
        #expect(state.messages.count == 4)
    }

    @Test func twoRefreshesAtOnceAreUnderWayUntilBothHaveAnswered() {
        var state = loaded([1])
        _ = feature.reduce(&state, .refreshRequested)
        _ = feature.reduce(&state, .refreshRequested)

        _ = feature.reduce(&state, .pageLoaded(.success(page([1]))))
        #expect(state.isRefreshing)
        _ = feature.reduce(&state, .pageLoaded(.success(page([2, 1]))))
        #expect(!state.isRefreshing)
    }

    @Test func theReloadAfterARefusedChangeCountsAsARefresh() {
        var state = loaded([2, 1])
        _ = feature.reduce(&state, .seenChangeRequested(false, ids: [.init(mailbox: "INBOX", uid: 2)]))

        _ = feature.reduce(&state, .seenChangeFinished(.failure(MailError(.refused, "no"))))
        #expect(state.isRefreshing)
        _ = feature.reduce(&state, .pageLoaded(.success(page([2, 1]))))
        #expect(!state.isRefreshing)
    }

    @Test func olderMailIsAskedForFromTheOldestMessageAndAppended() {
        var state = loaded([9, 8], hasMore: true)

        #expect(feature.reduce(&state, .moreRequested) == [.loadOlder(mailbox: "INBOX", olderThan: 8)])
        #expect(feature.reduce(&state, .moreRequested).isEmpty)

        _ = feature.reduce(&state, .olderPageLoaded(.success(page([8, 7]))))
        #expect(state.messages.map(\.id.uid) == [9, 8, 7])
    }

    @Test func movingAMessageTakesItOffTheListAtOnce() {
        var state = loaded([3, 2, 1])
        let ids = [MessageSummary.ID(mailbox: "INBOX", uid: 2)]

        let effects = feature.reduce(&state, .moveRequested(ids: ids, to: "Set Aside"))

        #expect(state.messages.map(\.id.uid) == [3, 1])
        #expect(effects == [.move(ids: ids, to: "Set Aside")])
    }

    @Test func aMessageFromAnotherMailboxIsNotThisOnesToChange() {
        var state = loaded([1])

        #expect(feature.reduce(&state, .seenChangeRequested(true, ids: [.init(mailbox: "Sent", uid: 1)])).isEmpty)
    }

    @Test func markingSeenFlipsTheMessageBeforeTheServerAnswers() {
        var state = MailboxFeature.State(mailbox: "INBOX")
        _ = feature.reduce(&state, .pageLoaded(.success(SummaryPage(messages: [message(1, seen: false)], hasMore: false))))

        _ = feature.reduce(&state, .seenChangeRequested(true, ids: [.init(mailbox: "INBOX", uid: 1)]))

        #expect(state.messages.first?.isSeen == true)
    }

    @Test func aRefusedChangeIsReportedAndTheListReloaded() {
        var state = loaded([1])

        let effects = feature.reduce(&state, .seenChangeFinished(.failure(MailError(.refused, "no"))))

        #expect(state.failedAction == MailError(.refused, "no"))
        #expect(effects == [.load(mailbox: "INBOX", limit: MailboxFeature.pageSize)])
    }

    @Test func aMoveThatWorkedAnnouncesTheMailWhereItWent() {
        var state = loaded([1])

        #expect(feature.reduce(&state, .moveFinished(to: "Set Aside", .success(()))) == [.reportMove(to: "Set Aside", succeeded: true)])
    }

    @Test func aRefusedMoveAnnouncesNothingAndPutsTheListBack() {
        var state = loaded([2, 1])
        _ = feature.reduce(&state, .moveRequested(ids: [.init(mailbox: "INBOX", uid: 2)], to: "Set Aside"))

        let effects = feature.reduce(&state, .moveFinished(to: "Set Aside", .failure(MailError(.refused, "no"))))

        #expect(state.failedAction == MailError(.refused, "no"))
        #expect(effects == [.reportMove(to: "Set Aside", succeeded: false), .load(mailbox: "INBOX", limit: MailboxFeature.pageSize)])
    }

    @Test func aMoveToTheMailboxItselfAsksTheServerNothing() {
        var state = loaded([1])

        #expect(feature.reduce(&state, .moveRequested(ids: [.init(mailbox: "INBOX", uid: 1)], to: "INBOX")).isEmpty)
    }
}

@Suite struct RulesFeatureTests {
    private let feature = RulesFeature()
    private let jane = EmailAddress(address: "jane@example.com")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func anAccountWithNoSavedDecisionsStartsScreeningNowAndSavesWhen() {
        var state = RulesFeature.State()
        #expect(feature.reduce(&state, .loadRequested) == [.load])

        let effects = feature.reduce(&state, .loaded(nil, at: now))

        #expect(state.rules == SenderRules(screeningSince: now))
        #expect(effects == [.save(SenderRules(screeningSince: now))])
    }

    @Test func savedDecisionsKeepTheMomentScreeningStarted() {
        let saved = SenderRules(screeningSince: now.addingTimeInterval(-86_400))
        var state = RulesFeature.State()

        let effects = feature.reduce(&state, .loaded(saved, at: now))

        #expect(state.rules == saved)
        #expect(effects.isEmpty)
        #expect(feature.reduce(&state, .loadRequested).isEmpty)
    }

    @Test func aDecisionIsSavedStraightAway() {
        var state = RulesFeature.State()
        _ = feature.reduce(&state, .loaded(SenderRules(screeningSince: now), at: now))

        let effects = feature.reduce(&state, .decided(.approved(.feed), for: jane, at: now))

        #expect(state.rules?.decisions == ["jane@example.com": .approved(.feed)])
        #expect(effects == state.rules.map { [.save($0)] })
    }

    @Test func aStorageProblemIsKeptUntilItHasBeenSeen() {
        var state = RulesFeature.State()

        _ = feature.reduce(&state, .storageFailed("disk full"))
        #expect(state.storageProblem == "disk full")

        _ = feature.reduce(&state, .storageProblemDismissed)
        #expect(state.storageProblem == nil)
    }

    @Test func aDecisionBeforeTheRulesAreLoadedIsNotSavedOverThem() {
        var state = RulesFeature.State()

        #expect(feature.reduce(&state, .decided(.screenedOut, for: jane, at: now)).isEmpty)
    }

    @Test func takingADecisionBackLeavesTheSenderUndecidedAndIsSaved() {
        var state = RulesFeature.State()
        _ = feature.reduce(&state, .loaded(SenderRules(screeningSince: now), at: now))
        _ = feature.reduce(&state, .decided(.screenedOut, for: jane, at: now))

        let effects = feature.reduce(&state, .decisionWithdrawn(for: jane, at: now.addingTimeInterval(5)))

        #expect(state.rules?.decision(for: jane) == nil)
        #expect(effects == [.save(state.rules!)])
    }
}

@Suite struct RecentActionFeatureTests {
    private let feature = RecentActionFeature()
    private let sender = EmailAddress(address: "jane@example.com")
    private var archived: MailAction { .moved([MovedMessage(messageID: "<1@x>", source: "INBOX")], to: "Archive") }
    private var trashed: MailAction { .moved([MovedMessage(messageID: "<2@x>", source: "INBOX")], to: "Trash") }

    @Test func anActionIsOnOfferUntilItsTimeIsUp() {
        var state = RecentActionFeature.State()

        let effects = feature.reduce(&state, .performed(archived))
        #expect(state.notice?.kind == .done(archived))
        #expect(effects == [.expire(1)])

        _ = feature.reduce(&state, .expired(1))
        #expect(state.notice == nil)
    }

    @Test func theNextActionTakesThePlaceAndTheEarlierTimerLeavesItAlone() {
        var state = RecentActionFeature.State()
        _ = feature.reduce(&state, .performed(archived))
        _ = feature.reduce(&state, .performed(trashed))

        _ = feature.reduce(&state, .expired(1))

        #expect(state.notice?.kind == .done(trashed))
    }

    @Test func takingAnActionBackIsSaidUntilTheServerAnswersAndCannotBePutAway() {
        var state = RecentActionFeature.State()
        _ = feature.reduce(&state, .performed(archived))

        let effects = feature.reduce(&state, .undoRequested(archived))
        #expect(effects == [.takeBack(archived)])
        #expect(state.notice?.kind == .takingBack(archived))

        // Neither the offer's own timer nor a swipe clears what is still owed an answer.
        _ = feature.reduce(&state, .expired(1))
        _ = feature.reduce(&state, .dismissed)
        #expect(state.notice?.kind == .takingBack(archived))

        _ = feature.reduce(&state, .undoFinished(nil))
        #expect(state.notice == nil)
    }

    @Test func actionsAreTakenBackOneAtATimeInTheOrderAsked() {
        var state = RecentActionFeature.State()
        _ = feature.reduce(&state, .performed(archived))
        _ = feature.reduce(&state, .performed(trashed))

        #expect(feature.reduce(&state, .undoRequested(trashed)) == [.takeBack(trashed)])
        // The second waits for the first, whose result it may depend on.
        #expect(feature.reduce(&state, .undoRequested(archived)).isEmpty)
        #expect(state.notice?.kind == .takingBack(trashed))

        #expect(feature.reduce(&state, .undoFinished(nil)) == [.takeBack(archived)])
        #expect(state.notice?.kind == .takingBack(archived))

        #expect(feature.reduce(&state, .undoFinished(nil)).isEmpty)
        #expect(state.notice == nil)
    }

    @Test func whenOneCannotBeTakenBackThoseWaitingBehindItAreNotTried() {
        var state = RecentActionFeature.State()
        _ = feature.reduce(&state, .undoRequested(trashed))
        _ = feature.reduce(&state, .undoRequested(archived))

        _ = feature.reduce(&state, .undoFinished(MailError(.missing)))
        #expect(state.notice?.kind == .notTakenBack(MailError(.missing)))

        // Nothing is left waiting: the next request starts at once.
        #expect(feature.reduce(&state, .undoRequested(archived)) == [.takeBack(archived)])
    }

    @Test func anActionThatCouldNotBeTakenBackSaysWhyForAWhile() {
        var state = RecentActionFeature.State()
        _ = feature.reduce(&state, .performed(archived))
        _ = feature.reduce(&state, .undoRequested(archived))

        let effects = feature.reduce(&state, .undoFinished(MailError(.refused, "no")))

        #expect(state.notice?.kind == .notTakenBack(MailError(.refused, "no")))
        #expect(effects == [.expire(3)])
    }

    @Test func anEarlierActionCanBeTakenBackAfterItsOfferHasGone() {
        var state = RecentActionFeature.State()
        _ = feature.reduce(&state, .performed(archived))
        _ = feature.reduce(&state, .expired(1))

        #expect(feature.reduce(&state, .undoRequested(archived)) == [.takeBack(archived)])
    }

    @Test func mailWithoutAMessageIDCannotBeTakenBack() {
        var state = RecentActionFeature.State()
        let unfindable = MailAction.moved([MovedMessage(messageID: nil, source: "INBOX")], to: "Archive")
        _ = feature.reduce(&state, .performed(unfindable))

        #expect(!unfindable.canBeTakenBack)
        #expect(feature.reduce(&state, .undoRequested(unfindable)).isEmpty)
        #expect(state.notice?.kind == .done(unfindable))
    }

    @Test func aDecisionAboutASenderCanAlwaysBeTakenBack() {
        #expect(MailAction.senderDecided(sender, .screenedOut, previously: nil, markedRead: []).canBeTakenBack)
        #expect(MailAction.senderDecided(sender, .screenedOut, previously: .approved(.mebox), markedRead: [.init(mailbox: "INBOX", uid: 4)]).canBeTakenBack)
    }

    @Test func puttingANoticeAwayClearsIt() {
        var state = RecentActionFeature.State()
        _ = feature.reduce(&state, .performed(archived))

        _ = feature.reduce(&state, .dismissed)

        #expect(state.notice == nil)
    }
}

@Suite struct AppFoldersFeatureTests {
    private let feature = AppFoldersFeature()
    private let waiting = [MessageSummary.ID(mailbox: "INBOX", uid: 7)]
    private let refusal = MailError(.refused, "Label or folder with this name already exists")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var loaded: AppFoldersFeature.State {
        var state = AppFoldersFeature.State()
        _ = feature.reduce(&state, .loaded(nil))
        return state
    }

    private func assigned(_ folder: MailboxDirectory.AppFolder, to path: String) -> FolderAssignments {
        var assignments = FolderAssignments()
        assignments.assign(path, to: folder, at: now)
        return assignments
    }

    @Test func theFirstUseMakesTheFolderThenDeliversTheMailThatWasWaiting() {
        var state = loaded

        #expect(feature.reduce(&state, .folderNeeded(.replyLater, path: "Reply Later", for: waiting)) == [.create(.replyLater, path: "Reply Later")])
        let effects = feature.reduce(&state, .creationFinished(.replyLater, .success(()), at: now))

        #expect(state.assignments == assigned(.replyLater, to: "Reply Later"))
        #expect(state.setups.isEmpty)
        #expect(effects == [.save(assigned(.replyLater, to: "Reply Later")), .deliver(ids: waiting, to: "Reply Later")])
    }

    @Test func mailPutAwayWhileTheFolderIsBeingMadeWaitsWithTheRest() {
        var state = loaded
        let later = [MessageSummary.ID(mailbox: "INBOX", uid: 9)]
        _ = feature.reduce(&state, .folderNeeded(.setAside, path: "Set Aside", for: waiting))

        #expect(feature.reduce(&state, .folderNeeded(.setAside, path: "Set Aside", for: later)).isEmpty)

        #expect(feature.reduce(&state, .creationFinished(.setAside, .success(()), at: now)).last == .deliver(ids: waiting + later, to: "Set Aside"))
    }

    @Test func aRefusedFolderAsksThePersonAndMovesNothing() {
        var state = loaded
        _ = feature.reduce(&state, .folderNeeded(.replyLater, path: "Folders/Reply Later", for: waiting))

        let effects = feature.reduce(&state, .creationFinished(.replyLater, .failure(refusal), at: now))

        #expect(effects.isEmpty)
        #expect(state.choice?.folder == .replyLater)
        #expect(state.choice?.refusedPath == "Folders/Reply Later")
        #expect(state.choice?.refusal == refusal)
        #expect(state.assignments == FolderAssignments())
    }

    @Test func choosingAnExistingMailboxSettlesTheFolderAndDeliversTheMail() {
        var state = loaded
        _ = feature.reduce(&state, .folderNeeded(.replyLater, path: "Folders/Reply Later", for: waiting))
        _ = feature.reduce(&state, .creationFinished(.replyLater, .failure(refusal), at: now))

        let effects = feature.reduce(&state, .existingChosen(.replyLater, path: "Labels/Reply Later", at: now))

        #expect(state.choice == nil)
        #expect(effects == [.save(assigned(.replyLater, to: "Labels/Reply Later")), .deliver(ids: waiting, to: "Labels/Reply Later")])
    }

    @Test func askingForAnotherNameTriesAgainAndCanBeRefusedAgain() {
        var state = loaded
        _ = feature.reduce(&state, .folderNeeded(.replyLater, path: "Folders/Reply Later", for: waiting))
        _ = feature.reduce(&state, .creationFinished(.replyLater, .failure(refusal), at: now))

        #expect(feature.reduce(&state, .newFolderChosen(.replyLater, path: "Folders/Later")) == [.create(.replyLater, path: "Folders/Later")])
        _ = feature.reduce(&state, .creationFinished(.replyLater, .failure(refusal), at: now))

        #expect(state.choice?.refusedPath == "Folders/Later")
    }

    @Test func cancellingLeavesTheMailWhereItIsAndNothingSettled() {
        var state = loaded
        _ = feature.reduce(&state, .folderNeeded(.replyLater, path: "Folders/Reply Later", for: waiting))
        _ = feature.reduce(&state, .creationFinished(.replyLater, .failure(refusal), at: now))

        #expect(feature.reduce(&state, .choiceCancelled(.replyLater)).isEmpty)

        #expect(state.setups.isEmpty)
        #expect(state.assignments == FolderAssignments())
    }

    @Test func aFolderCanBePointedSomewhereElseAndBack() {
        var state = loaded

        #expect(feature.reduce(&state, .reassigned(.setAside, path: "Labels/Set Aside", at: now)) == [.save(assigned(.setAside, to: "Labels/Set Aside"))])
        #expect(feature.reduce(&state, .reassigned(.setAside, path: "Labels/Set Aside", at: now)).isEmpty)
        // Going back to automatic is remembered as a choice, so other Macs follow it.
        #expect(feature.reduce(&state, .reassigned(.setAside, path: nil, at: now.addingTimeInterval(60))) == state.assignments.map { [.save($0)] })
        #expect(state.assignments?[.setAside] == nil)
        #expect(state.assignments != FolderAssignments())
    }

    @Test func nothingIsSettledBeforeTheSavedAssignmentsAreLoaded() {
        var state = AppFoldersFeature.State()

        #expect(feature.reduce(&state, .folderNeeded(.replyLater, path: "Reply Later", for: waiting)).isEmpty)
        #expect(feature.reduce(&state, .reassigned(.replyLater, path: "Elsewhere", at: now)).isEmpty)
    }

    @Test func assignmentsSurviveBeingSavedAndLoaded() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "heyday-tests-\(UUID().uuidString)/folders.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFileStore<FolderAssignments>(url: url)

        try store.save(assigned(.replyLater, to: "Labels/Reply Later"))

        #expect(try store.load() == assigned(.replyLater, to: "Labels/Reply Later"))
    }
}

@Suite struct AccountFeatureTests {
    private let feature = AccountFeature()
    private let directory = MailboxDirectory(mailboxes: [Mailbox(path: "INBOX", name: "INBOX", role: .inbox)])

    private var filledSetup: AccountSetup {
        var setup = AccountSetup.protonBridge
        setup.name = "Me"
        setup.address = "me@proton.me"
        setup.password = "bridge-password"
        return setup
    }

    @Test func aSavedAccountConnectsWithItsStoredPassword() throws {
        let account = try filledSetup.account().get()
        var state = AccountFeature.State.restoring
        #expect(feature.reduce(&state, .launched) == [.checkSavedAccount])

        #expect(feature.reduce(&state, .savedAccountChecked(account)) == [.connect(account, newPassword: nil)])
        _ = feature.reduce(&state, .connectionFinished(.success(directory)))

        #expect(state == .ready(account, directory))
    }

    @Test func withoutASavedAccountTheSetupFormIsShown() {
        var state = AccountFeature.State.restoring

        _ = feature.reduce(&state, .savedAccountChecked(nil))

        #expect(state == .settingUp(AccountSetup(), problem: nil))
    }

    @Test func theFormSaysWhatIsMissingBeforeTryingToConnect() {
        var setup = AccountSetup.protonBridge
        setup.address = "me@proton.me"
        var state = AccountFeature.State.settingUp(setup, problem: nil)

        #expect(feature.reduce(&state, .connectRequested).isEmpty)
        #expect(state == .settingUp(setup, problem: "Enter the password for this account."))
    }

    @Test func aCompleteFormConnectsAndTheUsernameDefaultsToTheAddress() throws {
        var state = AccountFeature.State.settingUp(filledSetup, problem: nil)

        let effects = feature.reduce(&state, .connectRequested)

        let account = try filledSetup.account().get()
        #expect(account.username == "me@proton.me")
        #expect(account.imap == ServerEndpoint(host: "127.0.0.1", port: 1143, security: .startTLS))
        #expect(effects == [.connect(account, newPassword: "bridge-password")])
    }

    @Test func aNewAccountThatFailsToConnectReturnsToTheFormAsTyped() throws {
        var state = AccountFeature.State.settingUp(filledSetup, problem: nil)
        _ = feature.reduce(&state, .connectRequested)

        _ = feature.reduce(&state, .connectionFinished(.failure(MailError(.loginRefused))))

        #expect(state == .settingUp(filledSetup, problem: MailError(.loginRefused).userMessage))
    }

    @Test func aServerThatDoesNotAnswerCanBeRetriedWithoutLosingTheAccount() throws {
        let account = try filledSetup.account().get()
        var state = AccountFeature.State.connecting(account, setup: nil)
        _ = feature.reduce(&state, .connectionFinished(.failure(MailError(.unreachable))))
        #expect(state == .unavailable(account, MailError(.unreachable)))

        #expect(feature.reduce(&state, .retryRequested) == [.connect(account, newPassword: nil)])
    }
}

@Suite struct ComposeFeatureTests {
    private let feature = ComposeFeature()
    private let me = EmailAddress(name: "Me", address: "me@example.com")
    private let original = FullMessage(
        summary: MessageSummary(
            id: .init(mailbox: "INBOX", uid: 9),
            messageID: "<9@x>",
            from: EmailAddress(name: "Jane", address: "jane@example.com"),
            subject: "Lunch"
        ),
        html: "<p>Friday?</p>",
        references: ["<1@x>"]
    )

    @Test func aReplyGoesToTheSenderInTheSameThread() {
        var state = ComposeFeature.State(intent: .reply(to: original.id), sender: me)
        #expect(feature.reduce(&state, .opened) == [.loadOriginal(original.id)])

        _ = feature.reduce(&state, .originalLoaded(.success(original)))

        #expect(state.draft.to == "jane@example.com")
        #expect(state.draft.subject == "Re: Lunch")
        #expect(state.draft.inReplyTo == "<9@x>")
        #expect(state.draft.references == ["<1@x>", "<9@x>"])
        #expect(state.draft.quotedHTML?.contains("<p>Friday?</p>") == true)
    }

    @Test func aReplyQuotesTheOriginalWithoutItsTrackingPixel() {
        let tracked = FullMessage(
            summary: original.summary,
            html: #"<p>Friday?</p><img src="https://acme.us1.list-manage.com/track/open.php?u=1" width="1" height="1">"#
        )
        var state = ComposeFeature.State(intent: .reply(to: tracked.id), sender: me)
        _ = feature.reduce(&state, .opened)

        _ = feature.reduce(&state, .originalLoaded(.success(tracked)))

        #expect(state.draft.quotedHTML?.contains("<p>Friday?</p>") == true)
        #expect(state.draft.quotedHTML?.contains("list-manage.com") == false)
    }

    @Test func replyingToAReplyDoesNotStackPrefixes() {
        #expect(ComposeFeature.prefixed("Re:", "RE: Lunch") == "RE: Lunch")
        #expect(ComposeFeature.prefixed("Fwd:", "Lunch") == "Fwd: Lunch")
    }

    @Test func aForwardCarriesTheOriginalAndHasNoRecipientYet() {
        var state = ComposeFeature.State(intent: .forward(original.id), sender: me)
        _ = feature.reduce(&state, .opened)
        _ = feature.reduce(&state, .originalLoaded(.success(original)))
        _ = feature.reduce(&state, .edited(.body, "FYI"))

        #expect(feature.reduce(&state, .sendRequested).isEmpty)
        #expect(state.phase == .editing(problem: .noRecipients))

        _ = feature.reduce(&state, .edited(.to, "Sam <sam@example.com>"))
        guard case .deliver(let mail) = feature.reduce(&state, .sendRequested).first else {
            Issue.record("expected the forward to be delivered")
            return
        }
        #expect(mail.to == [EmailAddress(name: "Sam", address: "sam@example.com")])
        #expect(mail.subject == "Fwd: Lunch")
        #expect(mail.htmlBody.hasPrefix("<div>FYI</div>"))
        #expect(mail.htmlBody.contains("<p>Friday?</p>"))
    }

    @Test func aRecipientThatIsNotAnAddressIsNamed() {
        var state = ComposeFeature.State(intent: .newMessage, sender: me)
        _ = feature.reduce(&state, .edited(.to, "jane@example.com, sam"))

        _ = feature.reduce(&state, .sendRequested)

        #expect(state.phase == .editing(problem: .invalidAddress("sam")))
    }

    @Test func aRefusedSendReturnsToEditingWithTheDraftIntact() {
        var state = ComposeFeature.State(intent: .newMessage, sender: me)
        _ = feature.reduce(&state, .edited(.to, "jane@example.com"))
        _ = feature.reduce(&state, .edited(.body, "Hello"))
        _ = feature.reduce(&state, .sendRequested)

        _ = feature.reduce(&state, .sendFinished(.failure(MailError(.refused, "550"))))

        #expect(state.phase == .editing(problem: .refused(MailError(.refused, "550"))))
        #expect(state.draft.body == "Hello")
    }

    @Test func aSentMessageEndsTheComposer() {
        var state = ComposeFeature.State(intent: .newMessage, sender: me)
        _ = feature.reduce(&state, .edited(.to, "jane@example.com"))
        _ = feature.reduce(&state, .sendRequested)

        _ = feature.reduce(&state, .sendFinished(.success(())))

        #expect(state.phase == .sent)
        #expect(feature.reduce(&state, .edited(.body, "too late")).isEmpty)
        #expect(state.draft.body.isEmpty)
    }
}

@Suite struct ThreadFeatureTests {
    private let feature = ThreadFeature()

    private func full(_ uid: UInt32) -> FullMessage {
        FullMessage(summary: message(uid), html: "")
    }

    @Test func aThreadOpensOnItsNewestMessageAndTogglesFoldOthers() {
        let ids = [MessageSummary.ID(mailbox: "INBOX", uid: 1), .init(mailbox: "INBOX", uid: 2)]
        var state = ThreadFeature.State(thread: ThreadRef(messageIDs: ids, subject: "Hi"))
        #expect(feature.reduce(&state, .opened) == [.load(ids)])

        _ = feature.reduce(&state, .loaded(.success([full(1), full(2)])))
        _ = feature.reduce(&state, .messageToggled(ids[0]))
        _ = feature.reduce(&state, .messageToggled(ids[1]))

        guard case .loaded(let loaded) = state.content else {
            Issue.record("expected a loaded thread")
            return
        }
        #expect(loaded.expanded == [ids[0]])
    }

    @Test func aMessageIsShownAsSentOnlyWhileThePersonAsksForIt() {
        let ids = [MessageSummary.ID(mailbox: "INBOX", uid: 1), .init(mailbox: "INBOX", uid: 2)]
        var state = ThreadFeature.State(thread: ThreadRef(messageIDs: ids, subject: "Hi"))
        _ = feature.reduce(&state, .loaded(.success([full(1), full(2)])))

        func shownAsSent() -> Set<MessageSummary.ID> {
            if case .loaded(let loaded) = state.content { loaded.shownAsSent } else { [] }
        }
        #expect(shownAsSent().isEmpty)

        #expect(feature.reduce(&state, .asSentRequested(ids[1])).isEmpty)
        #expect(shownAsSent() == [ids[1]])

        // Folding a message away and back does not change how it is shown.
        _ = feature.reduce(&state, .messageToggled(ids[1]))
        _ = feature.reduce(&state, .messageToggled(ids[1]))
        #expect(shownAsSent() == [ids[1]])

        _ = feature.reduce(&state, .protectionRequested(ids[1]))
        #expect(shownAsSent().isEmpty)
    }

    @Test func aMessageThatIsNotInTheThreadCannotBeShownAsSent() {
        let id = MessageSummary.ID(mailbox: "INBOX", uid: 1)
        var state = ThreadFeature.State(thread: ThreadRef(messageIDs: [id], subject: "Hi"))
        _ = feature.reduce(&state, .asSentRequested(id))
        #expect(state.content != .loaded(.init(messages: [])))

        _ = feature.reduce(&state, .loaded(.success([full(1)])))
        _ = feature.reduce(&state, .asSentRequested(.init(mailbox: "INBOX", uid: 9)))

        guard case .loaded(let loaded) = state.content else {
            Issue.record("expected a loaded thread")
            return
        }
        #expect(loaded.shownAsSent.isEmpty)
    }
}

@Suite struct ThreadImagesTests {
    private let feature = ThreadFeature()
    private let id = MessageSummary.ID(mailbox: "INBOX", uid: 1)
    private let picture = RemoteImage(data: Data([1]), mimeType: "image/png")
    /// Addresses that could each be a mark for one reader, so nothing fetches them unasked.
    private let marked = [URL(string: "https://cdn.example.com/a.png?uid=42")!, URL(string: "https://cdn.example.com/b.png?uid=42")!]

    private func message(_ id: MessageSummary.ID, images: [URL]) -> FullMessage {
        FullMessage(summary: MessageSummary(id: id), html: images.map { "<img src=\"\($0.absoluteString)\">" }.joined())
    }

    /// A thread of one message with two images that wait to be asked for.
    private var opened: ThreadFeature.State {
        var state = ThreadFeature.State(thread: ThreadRef(messageIDs: [id], subject: "News"))
        _ = feature.reduce(&state, .loaded(.success([message(id, images: marked)])))
        return state
    }

    private func images(_ state: ThreadFeature.State, in message: MessageSummary.ID? = nil) -> [Int: ImageLoad] {
        if case .loaded(let loaded) = state.content { loaded.images(in: message ?? id) } else { [:] }
    }

    @Test func openingAThreadFetchesNoImageWhoseAddressCouldMarkTheReader() {
        #expect(images(opened).isEmpty)
    }

    @Test func openingAThreadFetchesTheSharedLookingImagesOfTheMessageOnScreen() {
        let earlier = MessageSummary.ID(mailbox: "INBOX", uid: 0)
        let shared = URL(string: "https://cdn.example.com/logo.png")!
        var state = ThreadFeature.State(thread: ThreadRef(messageIDs: [earlier, id], subject: "News"))

        let effects = feature.reduce(&state, .loaded(.success([
            message(earlier, images: [shared]),
            message(id, images: [marked[0], shared]),
        ])))

        // Only the newest message is unfolded, and only its plain address is fetched.
        #expect(effects == [.fetchImage(ImageRef(message: id, index: 1), from: shared)])
        #expect(images(state) == [1: .loading])
        #expect(images(state, in: earlier).isEmpty)

        // Unfolding the earlier message fetches its plain image then; folding it does nothing more.
        #expect(feature.reduce(&state, .messageToggled(earlier)) == [.fetchImage(ImageRef(message: earlier, index: 0), from: shared)])
        #expect(feature.reduce(&state, .messageToggled(earlier)).isEmpty)
    }

    @Test func anImageIsFetchedWhenAskedForAndOnlyOnce() {
        var state = opened
        let ref = ImageRef(message: id, index: 1)

        #expect(feature.reduce(&state, .imageRequested(ref)) == [.fetchImage(ref, from: marked[1])])
        #expect(feature.reduce(&state, .imageRequested(ref)).isEmpty)
        #expect(images(state) == [1: .loading])

        _ = feature.reduce(&state, .imageFetched(ref, .success(picture)))
        #expect(images(state) == [1: .loaded(picture)])
        #expect(feature.reduce(&state, .imageRequested(ref)).isEmpty)
    }

    @Test func askingForAllFetchesTheOnesNotAlreadyShownOrOnTheirWay() {
        var state = opened
        _ = feature.reduce(&state, .imageRequested(ImageRef(message: id, index: 0)))

        let effects = feature.reduce(&state, .allImagesRequested(id))

        #expect(effects == [.fetchImage(ImageRef(message: id, index: 1), from: marked[1])])
    }

    @Test func anImageThatFailedCanBeAskedForAgain() {
        var state = opened
        let ref = ImageRef(message: id, index: 0)
        _ = feature.reduce(&state, .imageRequested(ref))
        _ = feature.reduce(&state, .imageFetched(ref, .failure(ImageLoadError("offline"))))
        #expect(images(state) == [0: .failed(ImageLoadError("offline"))])

        #expect(feature.reduce(&state, .imageRequested(ref)).count == 1)
    }

    @Test func anImageTheMessageDoesNotHaveIsNotFetched() {
        var state = opened

        #expect(feature.reduce(&state, .imageRequested(ImageRef(message: id, index: 9))).isEmpty)
    }
}

@Suite struct ThreadTimestampTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func todayShowsTheTimeThePastWeekTheWeekdayAndOlderTheDate() {
        let now = date(2026, 11, 26, 9)
        let locale = Locale(identifier: "en_US")
        func text(_ date: Date) -> String {
            // The time comes with a narrow no-break space before "AM" in this locale.
            ThreadTimestamp.text(for: date, now: now, calendar: calendar, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ")
        }

        #expect(text(date(2026, 11, 26, 2, 11)) == "2:11 AM")
        #expect(text(date(2026, 11, 25, 23)) == "Wednesday")
        #expect(text(date(2026, 11, 20)) == "Friday")
        #expect(text(date(2026, 11, 19)) == "Nov 19")
        #expect(text(date(2022, 11, 2)) == "Nov 2, 2022")
    }
}
