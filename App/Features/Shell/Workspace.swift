import HeydayKit
import Observation
import os
import SwiftUI

/// The connected app: what the window's columns show, the state machine behind each
/// mailbox, and the HEY-style sorting laid over the account's plain IMAP folders.
@MainActor
@Observable
final class Workspace {
    /// Where a conversation can be sent from a list or a thread.
    enum MoveTarget {
        case inbox
        case appFolder(MailboxDirectory.AppFolder)
        case role(Mailbox.Role)
        case folder(path: String)
    }

    let account: MailAccount
    let directory: MailboxDirectory
    let navigation = Store(initialState: NavigationFeature.State(), feature: NavigationFeature()) { _, _ in }
    let rules: Store<RulesFeature>
    /// Which senders and conversations the person asked to be told about.
    let notifications: Store<NotificationsFeature>
    /// When Paper Trail and The Feed were last visited, for the "new since last visited" divider.
    let visits: Store<BoxVisitsFeature>
    /// Scheduled and active Bubble Up reminders, synced across devices.
    let bubbleUps: Store<BubbleUpFeature>
    /// Advances when a scheduled Bubble Up becomes due (or when returning to the app)
    /// so Mebox updates at the exact scheduled time without polling.
    var bubbleUpClock = Date()
    /// The translation service and language chosen. Shared with Settings.
    let translation: Store<TranslationSettingsFeature>
    /// Keeping the Screener's decisions and the folder choices the same on every Mac.
    let sync: Store<SyncFeature>
    /// The last thing done to the mail, and the chance to take it back.
    let recentAction: Store<RecentActionFeature>

    @ObservationIgnored private let service: any MailService
    @ObservationIgnored private let imageLoader: any RemoteImageLoader
    @ObservationIgnored private let translationKeys: any TranslationKeyStore
    @ObservationIgnored private let translationTransport: any HTTPTransport
    @ObservationIgnored private let foldersStore: JSONFileStore<FolderAssignments>
    @ObservationIgnored private var liveUpdates: Task<Void, Never>?
    @ObservationIgnored private var regularSync: Task<Void, Never>?
    @ObservationIgnored private var bubbleUpWakeTask: Task<Void, Never>?
    /// Where the app keeps its own data in the account. Not a folder of mail.
    @ObservationIgnored private let dataMailbox: String
    @ObservationIgnored private var mailboxes: [String: Store<MailboxFeature>] = [:]
    @ObservationIgnored private var appFoldersStore: Store<AppFoldersFeature>?
    /// The search on screen. Only one is kept: a new query replaces it.
    @ObservationIgnored private var currentSearch: (query: String, store: Store<SearchFeature>)?
    /// Loaded thread stores kept for The Feed so scrolling back does not re-fetch bodies.
    @ObservationIgnored private var feedThreads: [ThreadRef: Store<ThreadFeature>] = [:]
    /// The moves the server has yet to answer for, oldest first.
    @ObservationIgnored private var movesAwaitingAnswer: [PendingMove] = []
    /// Quiet-box mail (The Feed, Paper Trail, Screened Out) this device has asked
    /// the server to mark read. Each message is asked about once while the app runs:
    /// a refusal is not retried over and over, and one marked unread by hand stays so.
    @ObservationIgnored private var markedReadAutomatically: Set<MessageSummary.ID> = []

    init(
        account: MailAccount,
        directory: MailboxDirectory,
        service: any MailService,
        imageLoader: any RemoteImageLoader,
        translation: Store<TranslationSettingsFeature>,
        translationKeys: any TranslationKeyStore,
        translationTransport: any HTTPTransport,
        rulesStore: JSONFileStore<SenderRules>,
        foldersStore: JSONFileStore<FolderAssignments>,
        notificationsStore: JSONFileStore<NotificationRules>,
        visitsStore: JSONFileStore<BoxVisits>,
        bubbleUpsStore: JSONFileStore<BubbleUpRules>
    ) {
        self.account = account
        self.directory = directory
        self.service = service
        self.imageLoader = imageLoader
        self.translation = translation
        self.translationKeys = translationKeys
        self.translationTransport = translationTransport
        self.foldersStore = foldersStore
        rules = Store(initialState: RulesFeature.State(), feature: RulesFeature(), runEffect: RulesFeature.effects(store: rulesStore))
        notifications = Store(
            initialState: NotificationsFeature.State(),
            feature: NotificationsFeature(),
            runEffect: NotificationsFeature.effects(store: notificationsStore) { await NewMail.askToNotify() }
        )
        visits = Store(
            initialState: BoxVisitsFeature.State(),
            feature: BoxVisitsFeature(),
            runEffect: BoxVisitsFeature.effects(store: visitsStore)
        )
        bubbleUps = Store(
            initialState: BubbleUpFeature.State(),
            feature: BubbleUpFeature(),
            runEffect: BubbleUpFeature.effects(store: bubbleUpsStore)
        )

        let document = MailDocumentStore<SyncedState>(
            service: service,
            mailbox: directory.path(forNewFolderNamed: Self.dataFolderName),
            name: "state",
            owner: account.sender
        )
        dataMailbox = document.mailbox
        // These two reach back into the workspace, which does not exist yet: it
        // is handed to them just below.
        let owner = Owner()
        sync = Store(
            initialState: SyncFeature.State(),
            feature: SyncFeature(),
            runEffect: SyncFeature.effects(store: document) { state in await owner.workspace?.adopt(state) }
        )
        recentAction = Store(
            initialState: RecentActionFeature.State(),
            feature: RecentActionFeature(),
            runEffect: RecentActionFeature.effects(lifetime: Self.noticeLifetime) { action in
                await owner.workspace?.takeBack(action)
            }
        )
        owner.workspace = self

        rules.send(.loadRequested)
        notifications.send(.loadRequested)
        visits.send(.loadRequested)
        bubbleUps.send(.loadRequested)
        syncWhenThisMacChanges()
        keepQuietMailRead()
        observeBubbleUpSchedule()
        regularSync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                self?.syncNow()
            }
        }

        let inboxPath = directory.inbox
        liveUpdates = Task { [weak self] in
            var pause = Duration.seconds(5)
            while !Task.isCancelled {
                do throws(MailError) {
                    try await service.waitForChange(in: inboxPath)
                    pause = .seconds(5)
                    self?.inbox.send(.refreshRequested)
                } catch {
                    // The wait could not continue (network gone, server restarted, or
                    // simply the periodic re-dial). Back off, then listen again.
                    try? await Task.sleep(for: pause)
                    pause = min(pause * 2, .seconds(60))
                    self?.inbox.send(.refreshRequested)
                }
            }
        }
    }

    deinit {
        liveUpdates?.cancel()
        regularSync?.cancel()
        bubbleUpWakeTask?.cancel()
    }

    // MARK: Stores

    var inbox: Store<MailboxFeature> { mailbox(directory.inbox) }

    func mailbox(_ path: String) -> Store<MailboxFeature> {
        if let store = mailboxes[path] { return store }
        let store = Store(
            initialState: MailboxFeature.State(mailbox: path),
            feature: MailboxFeature(),
            runEffect: MailboxFeature.effects(service: service) { [weak self] destination, succeeded in
                await self?.moveAnswered(from: path, to: destination, succeeded: succeeded)
            }
        )
        mailboxes[path] = store
        return store
    }

    /// Where Reply Later and Set Aside live, and the setting-up of them. Built on
    /// first use, since delivering waiting mail needs the workspace itself.
    var appFolders: Store<AppFoldersFeature> {
        if let appFoldersStore { return appFoldersStore }
        let store = Store(
            initialState: AppFoldersFeature.State(),
            feature: AppFoldersFeature(),
            runEffect: AppFoldersFeature.effects(store: foldersStore, service: service) { [weak self] ids, destination in
                await self?.deliver(ids, to: destination)
            }
        )
        appFoldersStore = store
        store.send(.loadRequested)
        return store
    }

    func search(_ query: String) -> Store<SearchFeature> {
        if let currentSearch, currentSearch.query == query { return currentSearch.store }
        let store = Store(
            initialState: SearchFeature.State(query: query),
            feature: SearchFeature(),
            runEffect: SearchFeature.effects(service: service, mailbox: directory.path(for: .all) ?? directory.inbox)
        )
        currentSearch = (query, store)
        return store
    }

    /// A thread's own state. The view showing the thread keeps it.
    func makeThread(_ thread: ThreadRef) -> Store<ThreadFeature> {
        Store(
            initialState: ThreadFeature.State(thread: thread),
            feature: ThreadFeature(),
            runEffect: ThreadFeature.effects(service: service, images: imageLoader)
        )
    }

    /// The cached thread store for a card in The Feed, starting its load once so
    /// scrolling back past a newsletter does not fetch its body from the server again.
    func feedThread(for conversation: Conversation) -> Store<ThreadFeature> {
        let ref = ThreadRef(conversation)
        if let cached = feedThreads[ref] { return cached }
        if feedThreads.count >= 50 {
            let visible = Set(placed(.box(.feed)).prefix(40).map(ThreadRef.init))
            feedThreads = feedThreads.filter { visible.contains($0.key) }
        }
        let store = makeThread(ref)
        feedThreads[ref] = store
        store.send(.opened)
        return store
    }

    /// The translations of one open conversation. The view showing it keeps them.
    /// Each is made by whichever service is chosen at the moment it is asked for.
    func makeTranslations() -> Store<TranslationFeature> {
        let translation = translation
        let keys = translationKeys
        return Store(
            initialState: TranslationFeature.State(),
            feature: TranslationFeature(),
            runEffect: TranslationFeature.effects(
                route: {
                    let settings = await translation.state.settings
                    // Off the main actor: reading a key can wait on the keychain.
                    return settings.route(readingKeyFrom: keys)
                },
                transport: translationTransport
            )
        )
    }

    /// Makes a language the one mail is translated into, as Settings does.
    func translate(into languageCode: String) {
        var settings = translation.state.settings
        settings.language = languageCode
        translation.send(.changed(settings))
    }

    /// A draft's own state. The window holding the draft keeps it.
    func makeComposer(_ intent: ComposeIntent, draft: ComposeFeature.Draft = .init()) -> Store<ComposeFeature> {
        Store(
            initialState: ComposeFeature.State(intent: intent, sender: account.sender, draft: draft),
            feature: ComposeFeature(),
            runEffect: ComposeFeature.effects(service: service)
        )
    }

    // MARK: Reply Later and Set Aside

    /// The mailbox a folder is kept in: wherever it was settled, or else where the
    /// app would find or make one under the folder's own name.
    func folderPath(_ folder: MailboxDirectory.AppFolder) -> String {
        appFolders.state.assignments?[folder] ?? directory.path(for: folder)
    }

    /// Whether a folder has a mailbox yet. One that has never been used has none
    /// until something is put in it.
    func isSetUp(_ folder: MailboxDirectory.AppFolder) -> Bool {
        if appFolders.state.assignments?[folder] != nil { return true }
        let path = directory.path(for: folder)
        return directory.mailboxes.contains { $0.path == path }
    }

    /// The person's own folders and labels, without the ones kept for the app's use.
    var userFolders: [Mailbox] {
        directory.userFolders(excluding: appFolderPaths)
    }

    var userFolderGroups: [MailboxGroup] {
        directory.userFolderGroups(excluding: appFolderPaths)
    }

    /// The mailboxes the app shows as something of its own, or not at all.
    private var appFolderPaths: Set<String> {
        Set(MailboxDirectory.AppFolder.allCases.map(folderPath)).union([dataMailbox])
    }

    /// Message-IDs of the mail in Reply Later and Set Aside. Where one of those is
    /// a label rather than a folder (as Proton has them), mail put there is still in
    /// the inbox too, and has to be kept out of the boxes drawn from it.
    private var heldForLater: Set<String> {
        Set(MailboxDirectory.AppFolder.allCases.filter(isSetUp).flatMap { folder in
            mailbox(folderPath(folder)).state.messages.compactMap(\.messageID)
        })
    }

    // MARK: HEY's sorting, over IMAP

    /// The server mailbox a list is drawn from.
    func mailboxPath(for listing: Listing) -> String {
        switch listing {
        case .box, .screener, .screenedOut: directory.inbox
        case .appFolder(let folder): folderPath(folder)
        case .mailbox(let path): path
        }
    }

    /// Whether a list's mailbox exists on the server.
    func hasMailbox(for listing: Listing) -> Bool {
        switch listing {
        case .appFolder(let folder): isSetUp(folder)
        case .box, .screener, .screenedOut, .mailbox: true
        }
    }

    /// The conversations a list shows, in the order it shows them.
    func conversations(for listing: Listing) -> [Conversation] {
        switch listing {
        case .box(.mebox): meboxSections.all
        case .box(let destination): placed(.box(destination))
        case .screener: waitingSenders.map(\.latest)
        case .screenedOut: placed(.screenedOut)
        case .appFolder, .mailbox: Conversation.group(mailbox(mailboxPath(for: listing)).state.messages.filter { !$0.isAppData })
        }
    }

    var meboxSections: MeboxSections {
        MeboxSections(
            placed(.box(.mebox)),
            readThisVisit: navigation.state.readThisVisit,
            bubbledUp: dueBubbledUpConversations
        )
    }

    /// Conversations pinned to Set Aside, shown both in the Set Aside list and in the
    /// floating pile at the bottom of Mebox.
    var setAsideConversations: [Conversation] {
        guard isSetUp(.setAside) else { return [] }
        return conversations(for: .appFolder(.setAside))
    }

    /// Opens a Set Aside conversation directly from the floating pile.
    func openSetAsideConversation(_ conversation: Conversation) {
        navigation.send(.listingChosen(.appFolder(.setAside)))
        navigation.send(.selectionChanged([conversation.id]))
    }

    /// Conversations whose Bubble Up time has arrived and whose condition still holds,
    /// ordered most recently due first.
    private var dueBubbledUpConversations: [Conversation] {
        guard let rules = bubbleUps.state.rules else { return [] }
        let now = bubbleUpClock
        var seen = Set<Conversation.ID>()
        var due: [(Conversation, BubbleUp)] = []

        func consider(_ conversations: [Conversation]) {
            for conversation in conversations where seen.insert(conversation.id).inserted {
                if let entry = rules.bubbleUp(for: conversation.id), entry.isDue(for: conversation, at: now) {
                    due.append((conversation, entry))
                }
            }
        }

        consider(placed(.box(.mebox)))
        consider(Conversation.group(sortableInbox))
        if isSetUp(.setAside) { consider(conversations(for: .appFolder(.setAside))) }
        if isSetUp(.replyLater) { consider(conversations(for: .appFolder(.replyLater))) }

        return due
            .sorted { lhs, rhs in
                if lhs.1.dueAt != rhs.1.dueAt { return lhs.1.dueAt > rhs.1.dueAt }
                return lhs.1.scheduledAt > rhs.1.scheduledAt
            }
            .map(\.0)
    }

    /// Paper Trail or The Feed split into what arrived since the previous visit and
    /// what was already there then.
    func visitedBoxSections(for destination: Destination) -> VisitedBoxSections {
        let conversations = placed(.box(destination))
        let cutoff: Date? = switch navigation.state.visitCutoff {
        case .captured(let date): date
        case .pending: visits.state.visits?.lastVisited(destination)
        }
        return VisitedBoxSections(conversations, lastVisited: cutoff)
    }

    /// Captures the previous-visit watermark for this visit (once per visit) and
    /// advances the saved watermark so the next visit knows what was seen now.
    func noteVisited(_ destination: Destination) {
        guard let saved = visits.state.visits,
              rules.state.rules != nil,
              case .loaded = inbox.state.content
        else { return }
        if navigation.state.visitCutoff == .pending {
            navigation.send(.visitCutoffCaptured(saved.lastVisited(destination)))
        }
        let watermark = VisitedBoxSections.watermark(for: placed(.box(destination)), now: .now)
        visits.send(.visited(destination, at: watermark))
    }

    /// Senders waiting for a yes or no, the most recent to write first.
    var waitingSenders: [WaitingSender] {
        rules.state.rules?.waitingSenders(in: sortableInbox) ?? []
    }

    /// Mebox's unread conversations, once the inbox has loaded and been sorted.
    /// Nil before that, so "nothing new" is never confused with "not known yet".
    var unseenMeboxConversations: [Conversation]? {
        guard rules.state.rules != nil, case .loaded = inbox.state.content else { return nil }
        return placed(.box(.mebox)).filter { !$0.isSeen }
    }

    /// The unread conversations the person asked to be told about: delivered to one
    /// of the boxes, and from a sender or in a conversation that notifications are
    /// on for. Nil until everything that decides it has loaded.
    var unseenToAnnounce: [Conversation]? {
        guard let rules = rules.state.rules, let asked = notifications.state.rules, case .loaded = inbox.state.content else { return nil }
        let delivered = sortableInbox.filter { message in
            if case .box = rules.placement(for: message) { true } else { false }
        }
        return Conversation.group(delivered).filter { !$0.isSeen && asked.announces($0) }
    }

    /// The number shown beside a list in the sidebar. Zero shows nothing.
    func badge(for listing: Listing) -> Int {
        switch listing {
        case .box(.mebox): unseenMeboxConversations?.count ?? 0
        case .screener: waitingSenders.count
        case .appFolder: conversations(for: listing).count
        case .box, .screenedOut, .mailbox: 0
        }
    }

    private func placed(_ placement: Placement) -> [Conversation] {
        rules.state.rules?.conversations(in: sortableInbox, placed: placement) ?? []
    }

    /// The inbox mail that the boxes and the Screener share out between them.
    private var sortableInbox: [MessageSummary] {
        let held = heldForLater
        guard !held.isEmpty else { return inbox.state.messages }
        return inbox.state.messages.filter { message in
            message.messageID.map { !held.contains($0) } ?? true
        }
    }

    // MARK: What is on screen

    /// The middle column's conversations, in the order shown.
    var visibleConversations: [Conversation] {
        guard let query = navigation.state.search else { return conversations(for: navigation.state.listing) }
        // A search of everything finds the app's own messages too.
        if case .found(let found) = search(query).state.results { return found.filter { !$0.latest.isAppData } }
        return []
    }

    var selectedConversations: [Conversation] {
        let selection = navigation.state.selection
        return selection.isEmpty ? [] : visibleConversations.filter { selection.contains($0.id) }
    }

    // MARK: Actions

    func setSeen(_ seen: Bool, _ conversations: [Conversation]) {
        for (path, ids) in Dictionary(grouping: conversations.flatMap(\.messageIDs), by: \.mailbox) {
            mailbox(path).send(.seenChangeRequested(seen, ids: ids))
        }
    }

    /// Asks the server for a list's newest mail, and returns when it has answered.
    func refresh(_ listing: Listing) async {
        guard hasMailbox(for: listing) else { return }
        let store = mailbox(mailboxPath(for: listing))
        store.send(.refreshRequested)
        await store.state { !$0.isRefreshing }
    }

    /// Opening a conversation is reading it.
    func read(_ conversation: Conversation) {
        guard !conversation.isSeen else { return }
        navigation.send(.conversationRead(conversation.id))
        setSeen(true, [conversation])
    }

    /// The server mailbox for a move, or nil when this account has no such folder
    /// (not every server has an Archive, say).
    func path(for target: MoveTarget) -> String? {
        switch target {
        case .inbox: directory.inbox
        case .appFolder(let folder): folderPath(folder)
        case .role(let role): directory.path(for: role)
        case .folder(let path): path
        }
    }

    /// Whether moving these conversations there would change anything: the account
    /// has such a mailbox, or the app can make it, and some of the mail is elsewhere.
    func canMove(_ conversations: [Conversation], to target: MoveTarget) -> Bool {
        if case .appFolder(let folder) = target, !isSetUp(folder) { return !conversations.isEmpty }
        guard let destination = path(for: target) else { return false }
        return conversations.contains { $0.messageIDs.contains { $0.mailbox != destination } }
    }

    func move(_ conversations: [Conversation], to target: MoveTarget) {
        if case .role(let role) = target, role == .trash || role == .spam {
            for conversation in conversations where bubbleUp(for: conversation) != nil {
                bubbleUps.send(.dismissed(conversation.id, at: .now))
            }
        }
        let ids = conversations.flatMap(\.messageIDs)
        if case .appFolder(let folder) = target, !isSetUp(folder) {
            // First use: the folder has to be made before anything can go into it.
            // The mail is delivered once it is, or once the person picks another.
            appFolders.send(.folderNeeded(folder, path: folderPath(folder), for: ids))
            return
        }
        guard let destination = path(for: target) else { return }
        deliver(ids, to: destination)
    }

    /// Moves messages into a mailbox that exists. Once the server has said they
    /// went, the move is on offer to be taken back.
    private func deliver(_ ids: [MessageSummary.ID], to destination: String) {
        let leaving = ids.filter { $0.mailbox != destination }
        guard !leaving.isEmpty else { return }
        // Noted before the move, which takes the messages off the lists they are read from.
        let allMail = directory.path(for: .all)
        let moved = leaving.map { id in
            // What a search finds under All Mail is in another mailbox as well, on
            // the servers that have one. Moved back to All Mail it would not be
            // there again, so that move is not offered to be taken back.
            MovedMessage(messageID: id.mailbox == allMail ? nil : summary(of: id)?.messageID, source: id.mailbox)
        }
        movesAwaitingAnswer.append(PendingMove(messages: moved, destination: destination, unanswered: Set(moved.map(\.source))))
        changingTheList {
            for (path, group) in Dictionary(grouping: leaving, by: \.mailbox) {
                mailbox(path).send(.moveRequested(ids: group, to: destination))
            }
        }
    }

    /// The server has answered a move out of one mailbox into another. When every
    /// mailbox an action took mail from has answered, what did move is put on
    /// offer to be taken back; a move that was refused is never claimed.
    private func moveAnswered(from source: String, to destination: String, succeeded: Bool) {
        if succeeded { mailArrived(in: destination) }
        // A mailbox answers its moves in the order they were asked for.
        guard let index = movesAwaitingAnswer.firstIndex(where: { $0.destination == destination && $0.unanswered.contains(source) }) else { return }
        movesAwaitingAnswer[index].unanswered.remove(source)
        if succeeded { movesAwaitingAnswer[index].left.insert(source) }
        guard movesAwaitingAnswer[index].unanswered.isEmpty else { return }
        let move = movesAwaitingAnswer.remove(at: index)
        let moved = move.messages.filter { move.left.contains($0.source) }
        if !moved.isEmpty { recentAction.send(.performed(.moved(moved, to: destination))) }
    }

    /// What is known of a message on screen: from its mailbox's list, or from the search.
    private func summary(of id: MessageSummary.ID) -> MessageSummary? {
        if let listed = mailboxes[id.mailbox]?.state.messages.first(where: { $0.id == id }) { return listed }
        guard case .found(let conversations) = currentSearch?.store.state.results else { return nil }
        return conversations.lazy.flatMap(\.messages).first { $0.id == id }
    }

    func decide(_ decision: SenderDecision, for sender: EmailAddress) {
        let previous = rules.state.rules?.decision(for: sender)
        guard decision != previous else { return }
        // Feed, Paper Trail, and Screened Out mail never counts as unread: mark what
        // was unread as read now, and note it so taking the answer back undoes that too.
        let markedRead = decision.marksMailRead ? unreadMail(from: sender) : []
        changingTheList {
            rules.send(.decided(decision, for: sender, at: .now))
        }
        markReadAutomatically(markedRead)
        recentAction.send(.performed(.senderDecided(sender, decision, previously: previous, markedRead: markedRead)))
    }

    // MARK: Quiet mail is kept read

    /// Keeps The Feed, Paper Trail, and Screened Out mail read on the server: as it
    /// arrives, when another device's answers are taken in, and for mail already
    /// there. Looks now, and again after every change to the inbox or to the answers.
    private func keepQuietMailRead() {
        let unread = withObservationTracking {
            guard let rules = rules.state.rules, case .loaded = inbox.state.content else { return [MessageSummary.ID]() }
            return rules.unreadKeptRead(in: sortableInbox)
        } onChange: { [weak self] in
            // Called just before the change; look again once it has been made.
            Task { @MainActor in self?.keepQuietMailRead() }
        }
        markReadAutomatically(unread)
    }

    /// Asks the server to mark quiet-box mail read, each message once.
    private func markReadAutomatically(_ ids: [MessageSummary.ID]) {
        let fresh = ids.filter { !markedReadAutomatically.contains($0) }
        guard !fresh.isEmpty else { return }
        markedReadAutomatically.formUnion(fresh)
        inbox.send(.seenChangeRequested(true, ids: fresh))
        Self.screenerLog.info("Marked \(fresh.count, privacy: .public) quiet-box messages read")
    }

    /// A sender's unread mail, among what the boxes and the Screener share out.
    private func unreadMail(from sender: EmailAddress) -> [MessageSummary.ID] {
        sortableInbox.filter { !$0.isSeen && $0.from?.key == sender.key }.map(\.id)
    }

    private static let screenerLog = Logger(subsystem: "app.heyday.mac", category: "screener")

    // MARK: Taking things back

    /// How long the offer to take an action back stays on screen.
    private static let noticeLifetime = Duration.seconds(6)

    /// Undoes an action. Returns why it could not, when it could not.
    private func takeBack(_ action: MailAction) async -> MailError? {
        switch action {
        case .senderDecided(let sender, _, let previous, let markedRead):
            changingTheList {
                if let previous {
                    rules.send(.decided(previous, for: sender, at: .now))
                } else {
                    rules.send(.decisionWithdrawn(for: sender, at: .now))
                }
            }
            // What the answer marked read is unread again, as it was before it. Should
            // the sender be placed in a quiet box again, it is marked read once more.
            if !markedRead.isEmpty {
                markedReadAutomatically.subtract(markedRead)
                inbox.send(.seenChangeRequested(false, ids: markedRead))
            }
            return nil

        case .bubbleUpChanged(let id, _, _, let previous):
            if let previous {
                bubbleUps.send(.scheduled(id, previous, at: .now))
            } else {
                bubbleUps.send(.dismissed(id, at: .now))
            }
            bubbleUpClock = .now
            return nil

        case .moved(let messages, let destination):
            do throws(MailError) {
                var copies = try await service.find(messageIDs: messages.compactMap(\.messageID), in: destination)
                var restored = 0
                for (source, group) in Dictionary(grouping: messages, by: \.source) {
                    // The newest copy of each is the one the move brought: an older
                    // one with the same Message-ID was there before, and stays.
                    let ids = group.compactMap { $0.messageID.flatMap { copies[$0]?.popLast() } }
                    try await service.move(ids, to: source)
                    restored += ids.count
                    mailArrived(in: source)
                }
                mailArrived(in: destination)
                // Whatever was found has gone back; say so if that was not all of it.
                return restored == messages.count ? nil : MailError(.missing)
            } catch {
                return error
            }
        }
    }

    // MARK: The same on every Mac

    /// The folder the app's own data is kept under in the account.
    private static let dataFolderName = "Heyday"
    /// How often to look for what other Macs changed, besides when this one changes
    /// something or comes to the front.
    private static let syncInterval = Duration.seconds(300)

    /// What this device holds that every device should: nil until every part is loaded.
    private var syncedState: SyncedState? {
        guard let rules = rules.state.rules,
              let folders = appFolders.state.assignments,
              let notifications = notifications.state.rules,
              let visits = visits.state.visits,
              let bubbleUps = bubbleUps.state.rules
        else { return nil }
        return SyncedState(rules: rules, folders: folders, notifications: notifications, visits: visits, bubbleUps: bubbleUps)
    }

    /// The app is in front again. Another device may have changed things meanwhile,
    /// and a phone that was put away has not been listening for new mail.
    func cameToTheFront() {
        bubbleUpClock = .now
        rescheduleBubbleUpWake()
        syncNow()
        inbox.send(.refreshRequested)
    }

    /// Brings this Mac and the account into line.
    func syncNow() {
        guard let syncedState else { return }
        sync.send(.requested(syncedState))
    }

    /// Syncs once this Mac's own state is loaded, and again each time it changes.
    private func syncWhenThisMacChanges() {
        withObservationTracking {
            _ = syncedState
        } onChange: { [weak self] in
            // Called just before the change; look again once it has been made.
            Task { @MainActor in
                self?.syncNow()
                self?.syncWhenThisMacChanges()
            }
        }
    }

    /// Takes in what other Macs changed.
    private func adopt(_ state: SyncedState) {
        changingTheList {
            if let rules = state.rules { self.rules.send(.remoteArrived(rules)) }
        }
        if let folders = state.folders { appFolders.send(.remoteArrived(folders)) }
        if let asked = state.notifications { notifications.send(.remoteArrived(asked)) }
        if let remoteVisits = state.visits { visits.send(.remoteArrived(remoteVisits)) }
        if let remoteBubbleUps = state.bubbleUps { bubbleUps.send(.remoteArrived(remoteBubbleUps)) }
    }

    // MARK: Bubble Up

    /// The active or scheduled Bubble Up on `conversation`, if any (ignoring `.ifNoReply`
    /// reminders that were already satisfied by a newer reply).
    func bubbleUp(for conversation: Conversation) -> BubbleUp? {
        guard let entry = bubbleUps.state.rules?.bubbleUp(for: conversation.id),
              !entry.isSatisfiedByReply(in: conversation)
        else { return nil }
        return entry
    }

    /// Whether `conversation` is currently due and floating at the top of Mebox.
    func isBubbledUp(_ conversation: Conversation) -> Bool {
        bubbleUp(for: conversation)?.isDue(for: conversation, at: bubbleUpClock) ?? false
    }

    /// A Bubble Up scheduled for a future time (not yet due).
    func scheduledBubbleUp(for conversation: Conversation) -> BubbleUp? {
        guard let entry = bubbleUp(for: conversation), !entry.isDue(for: conversation, at: bubbleUpClock) else { return nil }
        return entry
    }

    /// Schedules (or immediately activates) a Bubble Up on `conversation`.
    func scheduleBubbleUp(_ conversation: Conversation, dueAt: Date, condition: BubbleUp.Condition = .always) {
        let now = Date()
        let previous = bubbleUps.state.rules?.bubbleUp(for: conversation.id)
        let entry = BubbleUp(
            dueAt: dueAt,
            condition: condition,
            baselineMessageCount: conversation.messages.count,
            scheduledAt: now
        )
        bubbleUps.send(.scheduled(conversation.id, entry, at: now))
        bubbleUpClock = now
        recentAction.send(.performed(.bubbleUpChanged(
            conversation.id,
            subject: conversation.subject,
            entry,
            previously: previous
        )))
    }

    /// Pops an active Bubble Up or cancels a future scheduled one.
    func dismissBubbleUp(for conversation: Conversation) {
        guard let previous = bubbleUps.state.rules?.bubbleUp(for: conversation.id) else { return }
        let now = Date()
        bubbleUps.send(.dismissed(conversation.id, at: now))
        bubbleUpClock = now
        recentAction.send(.performed(.bubbleUpChanged(
            conversation.id,
            subject: conversation.subject,
            nil,
            previously: previous
        )))
    }

    /// Observes changes to saved/synced Bubble Up rules once, re-arming the wake timer.
    private func observeBubbleUpSchedule() {
        withObservationTracking {
            _ = bubbleUps.state.rules
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeBubbleUpSchedule() }
        }
        rescheduleBubbleUpWake()
    }

    /// Cancels any previous wake task and sleeps until the next future Bubble Up comes due.
    private func rescheduleBubbleUpWake() {
        bubbleUpWakeTask?.cancel()
        guard let nextDue = bubbleUps.state.rules?.nextDueDate(after: Date()) else {
            bubbleUpWakeTask = nil
            return
        }
        // Cap individual sleeps to 1 hour so Mac sleep/wake drift still catches up promptly.
        let delay = max(0.5, min(nextDue.timeIntervalSinceNow, 3600))
        bubbleUpWakeTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            self?.bubbleUpClock = Date()
            self?.rescheduleBubbleUpWake()
        }
    }

    // MARK: Notifications

    func notifies(about sender: EmailAddress) -> Bool {
        notifications.state.rules?.notifies(about: sender) ?? false
    }

    func notifies(about conversation: Conversation) -> Bool {
        notifications.state.rules?.notifies(aboutConversation: conversation.id) ?? false
    }

    func setNotifying(_ isOn: Bool, about sender: EmailAddress) {
        notifications.send(.senderSwitched(sender, isOn: isOn, at: .now))
    }

    func setNotifying(_ isOn: Bool, about conversation: Conversation) {
        notifications.send(.conversationSwitched(conversation.id, isOn: isOn, at: .now))
    }

    // MARK: Coordination

    /// Runs a change that may take conversations off the list on screen, then lets
    /// the selection move on from any selected one that went.
    private func changingTheList(_ change: () -> Void) {
        let before = visibleConversations.map(\.id)
        change()
        navigation.send(.conversationsLeft(listBefore: before, listAfter: visibleConversations.map(\.id)))
    }

    /// Mail has been moved into a mailbox, so any list of it is out of date.
    private func mailArrived(in path: String) {
        mailboxes[path]?.send(.refreshRequested)
    }

    // MARK: Problems saving

    /// Why the Screener's decisions or the folder choices could not be stored.
    var storageProblem: String? {
        rules.state.storageProblem
            ?? appFolders.state.storageProblem
            ?? notifications.state.storageProblem
            ?? visits.state.storageProblem
            ?? bubbleUps.state.storageProblem
    }

    func dismissStorageProblem() {
        rules.send(.storageProblemDismissed)
        appFolders.send(.storageProblemDismissed)
        notifications.send(.storageProblemDismissed)
        visits.send(.storageProblemDismissed)
        bubbleUps.send(.storageProblemDismissed)
    }
}

/// A move the server has yet to answer for. One action can take mail out of several
/// mailboxes, each of which answers for its own.
private struct PendingMove {
    let messages: [MovedMessage]
    let destination: String
    /// The mailboxes whose answer is still awaited.
    var unanswered: Set<String>
    /// The mailboxes the mail did leave.
    var left: Set<String> = []
}

/// Lets an effect reach the workspace that owns it, which is made after the effect is.
@MainActor
private final class Owner {
    weak var workspace: Workspace?
}
