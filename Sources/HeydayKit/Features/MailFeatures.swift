import Foundation

// MARK: - Mailbox

/// The messages of one server mailbox: loading them, paging back through them, and
/// changing them. Mebox, The Feed, Paper Trail and the Screener are all views
/// over the inbox's instance of this.
public struct MailboxFeature: Feature {
    public static let pageSize = 150

    public struct State: Equatable, Sendable {
        public let mailbox: String
        public var content: Content = .loading
        /// How many readings of the mailbox the server has yet to answer.
        fileprivate var loadsInFlight = 0
        /// The most recent change the server refused, shown until dismissed.
        public var failedAction: MailError?

        public init(mailbox: String) {
            self.mailbox = mailbox
        }

        /// Whether the mailbox is being read again and the answer has yet to come.
        public var isRefreshing: Bool { loadsInFlight > 0 }

        /// The loaded messages, newest first. Empty until the first page arrives.
        public var messages: [MessageSummary] {
            if case .loaded(let loaded) = content { loaded.messages } else { [] }
        }
    }

    public enum Content: Equatable, Sendable {
        case loading
        case unavailable(MailError)
        case loaded(Loaded)
    }

    public struct Loaded: Equatable, Sendable {
        /// Newest first.
        public var messages: [MessageSummary]
        public var hasMore: Bool
        public var paging: Paging = .idle
    }

    public enum Paging: Equatable, Sendable {
        case idle
        case loadingMore
        case failed(MailError)
    }

    public enum Event: Sendable {
        /// The mailbox came on screen, or the server said it changed.
        case refreshRequested
        case pageLoaded(Result<SummaryPage, MailError>)
        case moreRequested
        case olderPageLoaded(Result<SummaryPage, MailError>)
        case seenChangeRequested(Bool, ids: [MessageSummary.ID])
        case moveRequested(ids: [MessageSummary.ID], to: String)
        case seenChangeFinished(Result<Void, MailError>)
        case moveFinished(to: String, Result<Void, MailError>)
        case failedActionDismissed
    }

    public enum Effect: Equatable, Sendable {
        case load(mailbox: String, limit: Int)
        case loadOlder(mailbox: String, olderThan: UInt32)
        case setSeen(Bool, ids: [MessageSummary.ID])
        case move(ids: [MessageSummary.ID], to: String)
        /// Tell whoever shows that mailbox that mail has been moved into it.
        case reportMove(to: String, succeeded: Bool)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .refreshRequested:
            if case .unavailable = state.content { state.content = .loading }
            return [reload(&state)]

        case .pageLoaded(.success(let page)):
            state.loadsInFlight -= 1
            state.content = .loaded(Loaded(messages: page.messages, hasMore: page.hasMore))
            return []

        case .pageLoaded(.failure(let error)):
            state.loadsInFlight -= 1
            // A failed refresh leaves what is already on screen alone.
            if case .loading = state.content { state.content = .unavailable(error) }
            return []

        case .moreRequested:
            guard case .loaded(var loaded) = state.content, loaded.hasMore, loaded.paging != .loadingMore,
                  let oldest = loaded.messages.last
            else { return [] }
            loaded.paging = .loadingMore
            state.content = .loaded(loaded)
            return [.loadOlder(mailbox: state.mailbox, olderThan: oldest.id.uid)]

        case .olderPageLoaded(let result):
            guard case .loaded(var loaded) = state.content, loaded.paging == .loadingMore else { return [] }
            switch result {
            case .success(let page):
                let known = Set(loaded.messages.map(\.id))
                loaded.messages += page.messages.filter { !known.contains($0.id) }
                loaded.hasMore = page.hasMore
                loaded.paging = .idle
            case .failure(let error):
                loaded.paging = .failed(error)
            }
            state.content = .loaded(loaded)
            return []

        case .seenChangeRequested(let seen, let ids):
            let ids = ids.filter { $0.mailbox == state.mailbox }
            guard !ids.isEmpty else { return [] }
            // Show the result at once; `seenChangeFinished` reloads if the server disagrees.
            if case .loaded(var loaded) = state.content {
                let changing = Set(ids)
                for index in loaded.messages.indices where changing.contains(loaded.messages[index].id) {
                    loaded.messages[index].isSeen = seen
                }
                state.content = .loaded(loaded)
            }
            return [.setSeen(seen, ids: ids)]

        case .moveRequested(let ids, let destination):
            let ids = ids.filter { $0.mailbox == state.mailbox }
            guard !ids.isEmpty, destination != state.mailbox else { return [] }
            if case .loaded(var loaded) = state.content {
                let leaving = Set(ids)
                loaded.messages.removeAll { leaving.contains($0.id) }
                state.content = .loaded(loaded)
            }
            return [.move(ids: ids, to: destination)]

        case .seenChangeFinished(.success):
            return []

        case .moveFinished(let destination, .success):
            return [.reportMove(to: destination, succeeded: true)]

        case .moveFinished(let destination, .failure(let error)):
            // The list was changed ahead of the server's answer; put back what is true.
            state.failedAction = error
            return [.reportMove(to: destination, succeeded: false), reload(&state)]

        case .seenChangeFinished(.failure(let error)):
            state.failedAction = error
            return [reload(&state)]

        case .failedActionDismissed:
            state.failedAction = nil
            return []
        }
    }

    /// Reads the mailbox again, as far back as is already on screen so that nothing
    /// loaded vanishes. Each reading is counted until its page comes back.
    private func reload(_ state: inout State) -> Effect {
        state.loadsInFlight += 1
        return .load(mailbox: state.mailbox, limit: max(Self.pageSize, state.messages.count))
    }

    /// - Parameter onMoveAnswered: called with a destination mailbox's path once the
    ///   server has answered a move into it, and whether the mail went.
    public static func effects(
        service: any MailService,
        onMoveAnswered: @escaping @Sendable (String, Bool) async -> Void
    ) -> EffectRunner<MailboxFeature> {
        { effect, send in
            switch effect {
            case .load(let mailbox, let limit):
                await send(.pageLoaded(await outcome { () throws(MailError) in
                    try await service.summaries(in: mailbox, olderThan: nil, limit: limit)
                }))
            case .loadOlder(let mailbox, let uid):
                await send(.olderPageLoaded(await outcome { () throws(MailError) in
                    try await service.summaries(in: mailbox, olderThan: uid, limit: pageSize)
                }))
            case .setSeen(let seen, let ids):
                await send(.seenChangeFinished(await outcome { () throws(MailError) in
                    try await service.setSeen(seen, for: ids)
                }))
            case .move(let ids, let destination):
                await send(.moveFinished(to: destination, await outcome { () throws(MailError) in
                    try await service.move(ids, to: destination)
                }))
            case .reportMove(let destination, let succeeded):
                await onMoveAnswered(destination, succeeded)
            }
        }
    }
}

/// Runs a throwing call and packages its outcome for an event.
func outcome<Value: Sendable>(of operation: () async throws(MailError) -> Value) async -> Result<Value, MailError> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}

// MARK: - Screener rules

/// The Screener's decisions, loaded from and saved to this Mac, and joined with what
/// other Macs decided when that is read from the account.
public struct RulesFeature: Feature {
    public struct State: Equatable, Sendable {
        /// Nil until loaded. The inbox cannot be sorted into boxes before then.
        public var rules: SenderRules?
        /// Why the decisions could not be read or written, until it has been seen.
        public var storageProblem: String?

        public init() {}
    }

    public enum Event: Sendable {
        case loadRequested
        /// - Parameter at: when the load finished. An account with no saved decisions
        ///   starts screening from this moment.
        case loaded(SenderRules?, at: Date)
        case decided(SenderDecision, for: EmailAddress, at: Date)
        /// A decision was taken back, leaving its sender undecided again.
        case decisionWithdrawn(for: EmailAddress, at: Date)
        /// What other Macs decided has been read from the account.
        case remoteArrived(SenderRules)
        case storageFailed(String)
        case storageProblemDismissed
    }

    public enum Effect: Equatable, Sendable {
        case load
        case save(SenderRules)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .loadRequested:
            return state.rules == nil ? [.load] : []

        case .loaded(let saved?, _):
            state.rules = saved
            return []

        case .loaded(nil, let now):
            let fresh = SenderRules(screeningSince: now)
            state.rules = fresh
            // Saved at once: the starting moment must be the same on the next launch.
            return [.save(fresh)]

        case .decided(let decision, let sender, let time):
            guard var rules = state.rules else { return [] }
            rules.decide(decision, for: sender, at: time)
            state.rules = rules
            return [.save(rules)]

        case .decisionWithdrawn(let sender, let time):
            guard var rules = state.rules else { return [] }
            rules.withdrawDecision(for: sender, at: time)
            state.rules = rules
            return [.save(rules)]

        case .remoteArrived(let remote):
            guard let rules = state.rules else { return [] }
            let merged = rules.merged(with: remote)
            guard merged != rules else { return [] }
            state.rules = merged
            return [.save(merged)]

        case .storageFailed(let message):
            state.storageProblem = message
            return []

        case .storageProblemDismissed:
            state.storageProblem = nil
            return []
        }
    }

    public static func effects(
        store: JSONFileStore<SenderRules>,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> EffectRunner<RulesFeature> {
        { effect, send in
            switch effect {
            case .load:
                do throws(StorageError) {
                    await send(.loaded(try store.load(), at: now()))
                } catch {
                    // Unreadable decisions are reported and then treated as none, so
                    // the account starts screening afresh instead of showing no mail.
                    await send(.storageFailed(error.message))
                    await send(.loaded(nil, at: now()))
                }
            case .save(let rules):
                do throws(StorageError) {
                    try store.save(rules)
                } catch {
                    await send(.storageFailed(error.message))
                }
            }
        }
    }
}

// MARK: - Thread

/// The conversation a screen is about.
public struct ThreadRef: Hashable, Sendable {
    public let messageIDs: [MessageSummary.ID]
    /// Shown while the messages themselves are still loading.
    public let subject: String

    public init(messageIDs: [MessageSummary.ID], subject: String) {
        self.messageIDs = messageIDs
        self.subject = subject
    }

    public init(_ conversation: Conversation) {
        self.init(messageIDs: conversation.messageIDs, subject: conversation.subject)
    }
}

/// One remote image in one message of a conversation.
public struct ImageRef: Hashable, Sendable {
    public let message: MessageSummary.ID
    /// The image's position in the message's `ProtectedBody.images`.
    public let index: Int

    public init(message: MessageSummary.ID, index: Int) {
        self.message = message
        self.index = index
    }
}

/// How fetching a remote image the person asked for is going.
public enum ImageLoad: Equatable, Sendable {
    case loading
    case loaded(RemoteImage)
    case failed(ImageLoadError)
}

/// One open conversation: its messages, which of them are expanded, and which of
/// their remote images have been asked for.
public struct ThreadFeature: Feature {
    public struct State: Equatable, Sendable {
        public let thread: ThreadRef
        public var content: Content = .loading

        public init(thread: ThreadRef) {
            self.thread = thread
        }
    }

    public enum Content: Equatable, Sendable {
        case loading
        case unavailable(MailError)
        case loaded(Loaded)
    }

    public struct Loaded: Equatable, Sendable {
        /// Oldest first.
        public let messages: [FullMessage]
        public var expanded: Set<MessageSummary.ID>
        /// Each message's body with its trackers dealt with.
        public let bodies: [MessageSummary.ID: ProtectedBody]
        /// The remote images being fetched or fetched. One that is absent has not
        /// been fetched: its address could be a mark for this reader, and it waits
        /// to be asked for.
        public var images: [ImageRef: ImageLoad] = [:]
        /// The messages the person asked to see exactly as they were sent, tracking
        /// and all. Every other message is shown with its trackers dealt with. The
        /// choice lasts while the conversation is open.
        public var shownAsSent: Set<MessageSummary.ID> = []

        public init(messages: [FullMessage]) {
            self.messages = messages
            // A thread opens on its newest message with the earlier ones folded.
            expanded = Set(messages.last.map { [$0.id] } ?? [])
            bodies = Dictionary(messages.map { ($0.id, MailBodyProtector.protect($0.html)) }) { first, _ in first }
        }

        /// The state of one message's images, by their position in its body.
        public func images(in message: MessageSummary.ID) -> [Int: ImageLoad] {
            Dictionary(uniqueKeysWithValues: images.filter { $0.key.message == message }.map { ($0.key.index, $0.value) })
        }
    }

    public enum Event: Sendable {
        case opened
        case loaded(Result<[FullMessage], MailError>)
        case messageToggled(MessageSummary.ID)
        /// The person asked to see one held-back image.
        case imageRequested(ImageRef)
        /// The person asked to see every held-back image in a message.
        case allImagesRequested(MessageSummary.ID)
        case imageFetched(ImageRef, Result<RemoteImage, ImageLoadError>)
        /// The person asked to see a message as it was sent, accepting its tracking.
        case asSentRequested(MessageSummary.ID)
        /// The person asked for a message's trackers to be dealt with again.
        case protectionRequested(MessageSummary.ID)
    }

    public enum Effect: Equatable, Sendable {
        case load([MessageSummary.ID])
        case fetchImage(ImageRef, from: URL)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .opened:
            state.content = .loading
            return [.load(state.thread.messageIDs)]
        case .loaded(.success(let messages)):
            var loaded = Loaded(messages: messages)
            let effects = Self.startFetching(loaded.expanded.flatMap { Self.sharedImages(of: $0, in: loaded) }, in: &loaded)
            state.content = .loaded(loaded)
            return effects
        case .loaded(.failure(let error)):
            state.content = .unavailable(error)
            return []
        case .messageToggled(let id):
            guard case .loaded(var loaded) = state.content else { return [] }
            var effects: [Effect] = []
            if loaded.expanded.remove(id) == nil {
                loaded.expanded.insert(id)
                effects = Self.startFetching(Self.sharedImages(of: id, in: loaded), in: &loaded)
            }
            state.content = .loaded(loaded)
            return effects

        case .imageRequested(let ref):
            guard case .loaded(var loaded) = state.content else { return [] }
            let effects = Self.startFetching([ref], in: &loaded)
            state.content = .loaded(loaded)
            return effects

        case .allImagesRequested(let message):
            guard case .loaded(var loaded) = state.content, let body = loaded.bodies[message] else { return [] }
            let effects = Self.startFetching(body.images.indices.map { ImageRef(message: message, index: $0) }, in: &loaded)
            state.content = .loaded(loaded)
            return effects

        case .asSentRequested(let id):
            guard case .loaded(var loaded) = state.content, loaded.bodies[id] != nil else { return [] }
            loaded.shownAsSent.insert(id)
            state.content = .loaded(loaded)
            return []

        case .protectionRequested(let id):
            guard case .loaded(var loaded) = state.content else { return [] }
            loaded.shownAsSent.remove(id)
            state.content = .loaded(loaded)
            return []

        case .imageFetched(let ref, let result):
            guard case .loaded(var loaded) = state.content, loaded.images[ref] == .loading else { return [] }
            switch result {
            case .success(let image): loaded.images[ref] = .loaded(image)
            case .failure(let error): loaded.images[ref] = .failed(error)
            }
            state.content = .loaded(loaded)
            return []
        }
    }

    /// The images of a message that may be fetched without asking, as it comes on screen.
    private static func sharedImages(of message: MessageSummary.ID, in loaded: Loaded) -> [ImageRef] {
        let images = loaded.bodies[message]?.images ?? []
        return images.indices.filter { images[$0].looksShared }.map { ImageRef(message: message, index: $0) }
    }

    /// Marks images as loading and returns the fetches to run. One already shown or
    /// on its way is left alone; one that failed is tried again.
    private static func startFetching(_ refs: [ImageRef], in loaded: inout Loaded) -> [Effect] {
        refs.compactMap { ref in
            guard let images = loaded.bodies[ref.message]?.images, images.indices.contains(ref.index) else { return nil }
            switch loaded.images[ref] {
            case .loading, .loaded: return nil
            case nil, .failed: break
            }
            loaded.images[ref] = .loading
            return .fetchImage(ref, from: images[ref.index].url)
        }
    }

    public static func effects(service: any MailService, images: any RemoteImageLoader) -> EffectRunner<ThreadFeature> {
        { effect, send in
            switch effect {
            case .load(let ids):
                await send(.loaded(await outcome { () throws(MailError) in try await service.messages(ids) }))
            case .fetchImage(let ref, let url):
                let result: Result<RemoteImage, ImageLoadError>
                do throws(ImageLoadError) {
                    result = .success(try await images.image(at: url))
                } catch {
                    result = .failure(error)
                }
                await send(.imageFetched(ref, result))
            }
        }
    }
}

// MARK: - Search

public struct SearchFeature: Feature {
    public struct State: Equatable, Sendable {
        public let query: String
        public var results: Results = .searching

        public init(query: String) {
            self.query = query
        }
    }

    public enum Results: Equatable, Sendable {
        case searching
        case unavailable(MailError)
        case found([Conversation])
    }

    public enum Event: Sendable {
        case opened
        case finished(Result<[MessageSummary], MailError>)
    }

    public enum Effect: Equatable, Sendable {
        case search(String)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .opened:
            state.results = .searching
            return [.search(state.query)]
        case .finished(.success(let messages)):
            state.results = .found(Conversation.group(messages))
            return []
        case .finished(.failure(let error)):
            state.results = .unavailable(error)
            return []
        }
    }

    /// - Parameter mailbox: where to look. "All Mail" where the server has one, since
    ///   it holds sent and filed messages too; the inbox otherwise.
    public static func effects(service: any MailService, mailbox: String) -> EffectRunner<SearchFeature> {
        { effect, send in
            switch effect {
            case .search(let query):
                await send(.finished(await outcome { () throws(MailError) in
                    try await service.search(query, in: mailbox, limit: 100)
                }))
            }
        }
    }
}
