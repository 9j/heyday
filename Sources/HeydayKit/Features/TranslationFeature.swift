import Foundation

// MARK: - Settings

/// What the person has chosen about translation: the service, the language, and
/// which services have a key.
public struct TranslationSettingsFeature: Feature {
    public struct State: Equatable, Sendable {
        public var settings: TranslationSettings
        /// The services a key is stored for. The keys themselves stay in the keychain.
        public var servicesWithKey: Set<String> = []
        /// Why the choices or a key could not be read or written, until it has been seen.
        public var storageProblem: String?

        /// - Parameter settings: what to start with until the saved choices are read.
        public init(settings: TranslationSettings) {
            self.settings = settings
        }
    }

    public enum Event: Sendable {
        case loadRequested
        /// - Parameter saved: nil when nothing has been saved yet.
        case loaded(TranslationSettings?, servicesWithKey: Set<String>)
        case changed(TranslationSettings)
        /// The person entered a key for a service. An empty one forgets the stored key.
        case keyEntered(String, service: String)
        case keyStored(service: String, isStored: Bool)
        case storageFailed(String)
        case storageProblemDismissed
    }

    public enum Effect: Equatable, Sendable {
        case load
        case save(TranslationSettings)
        case storeKey(String, service: String)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .loadRequested:
            return [.load]

        case .loaded(let saved, let servicesWithKey):
            if let saved { state.settings = saved }
            state.servicesWithKey = servicesWithKey
            return []

        case .changed(let settings):
            guard settings != state.settings else { return [] }
            state.settings = settings
            return [.save(settings)]

        case .keyEntered(let key, let service):
            return [.storeKey(key.trimmingCharacters(in: .whitespacesAndNewlines), service: service)]

        case .keyStored(let service, let isStored):
            if isStored {
                state.servicesWithKey.insert(service)
            } else {
                state.servicesWithKey.remove(service)
            }
            return []

        case .storageFailed(let message):
            state.storageProblem = message
            return []

        case .storageProblemDismissed:
            state.storageProblem = nil
            return []
        }
    }

    public static func effects(
        store: JSONFileStore<TranslationSettings>,
        keys: any TranslationKeyStore
    ) -> EffectRunner<TranslationSettingsFeature> {
        { effect, send in
            switch effect {
            case .load:
                let withKey = Set(TranslationServices.all.map(\.id).filter { keys.hasKey(for: $0) })
                do throws(StorageError) {
                    await send(.loaded(try store.load(), servicesWithKey: withKey))
                } catch {
                    // Unreadable choices are reported, and the defaults stand in.
                    await send(.storageFailed(error.message))
                    await send(.loaded(nil, servicesWithKey: withKey))
                }
            case .save(let settings):
                do throws(StorageError) {
                    try store.save(settings)
                } catch {
                    await send(.storageFailed(error.message))
                }
            case .storeKey(let key, let service):
                do throws(StorageError) {
                    try keys.save(key, for: service)
                    await send(.keyStored(service: service, isStored: !key.isEmpty))
                } catch {
                    await send(.storageFailed(error.message))
                }
            }
        }
    }
}

// MARK: - Translating the messages of a conversation

/// How far the translation of one message is.
public struct MessageTranslation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Asked for. The page showing the message has yet to say what text it holds.
        case reading
        case translating
        case finished
        case failed(TranslationError)
    }

    /// Who is translating, and into what.
    public struct Credit: Equatable, Sendable {
        public let service: String
        public let language: TranslationLanguage

        public init(service: String, language: TranslationLanguage) {
            self.service = service
            self.language = language
        }
    }

    /// Which request for this message's translation this is, counting from one.
    /// Asking again (in another language, or after a failure) starts a new one, and
    /// what an earlier one still sends back is no longer wanted.
    public let run: Int
    public var phase: Phase = .reading
    /// The message's paragraphs as the page gave them, with inline markup as numbered tags.
    public var paragraphs: [String] = []
    /// The translations that have arrived, by paragraph.
    public var translations: [Int: String] = [:]
    /// Whether the translation is on screen, rather than the message as written.
    public var isShown = true
    /// Known once a request is on its way.
    public var credit: Credit?

    public init(run: Int = 1) {
        self.run = run
    }

    /// Whether the finished translation says what the message already said, as a
    /// message written in the reader's language does. There is then nothing to show.
    public var readsAsWritten: Bool {
        guard phase == .finished, !translations.isEmpty else { return false }
        return translations.allSatisfy { index, translation in
            paragraphs.indices.contains(index) && Self.words(of: translation) == Self.words(of: paragraphs[index])
        }
    }

    /// A paragraph's text without the tags that stand for its markup.
    private static func words(of text: String) -> String {
        text.replacing(/<\/?[gx]\d+\s*\/?>/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Translates messages on request, paragraph by paragraph.
///
/// The text comes from the page that shows the message, which knows what its
/// paragraphs are: asking for a translation first asks the page (`reading`), and
/// the request to the service starts when the page has answered.
public struct TranslationFeature: Feature {
    public struct State: Equatable, Sendable {
        /// Messages nobody asked to have translated have no entry.
        public var messages: [MessageSummary.ID: MessageTranslation] = [:]

        public init() {}
    }

    public enum Event: Sendable {
        /// The person asked for a message's translation: to make one, or to see the
        /// one already made.
        case requested(MessageSummary.ID)
        /// The person asked for the translation to be made afresh, as after choosing
        /// another language for it.
        case retranslationRequested(MessageSummary.ID)
        case paragraphsRead(MessageSummary.ID, [String])
        case started(MessageSummary.ID, run: Int, MessageTranslation.Credit)
        case partTranslated(MessageSummary.ID, run: Int, [Int: String])
        /// - Parameter error: why it stopped short, or nil when every request was answered.
        case finished(MessageSummary.ID, run: Int, TranslationError?)
        /// The person asked to see the message as written.
        case originalRequested(MessageSummary.ID)
    }

    public enum Effect: Equatable, Sendable {
        case translate(MessageSummary.ID, run: Int, paragraphs: [String])
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .requested(let id):
            switch state.messages[id]?.phase {
            case nil, .failed:
                startOver(id, in: &state)
            case .reading, .translating, .finished:
                state.messages[id]?.isShown = true
            }
            return []

        case .retranslationRequested(let id):
            startOver(id, in: &state)
            return []

        case .paragraphsRead(let id, let paragraphs):
            guard var translation = state.messages[id], translation.phase == .reading else { return [] }
            translation.paragraphs = paragraphs
            translation.phase = paragraphs.isEmpty ? .finished : .translating
            state.messages[id] = translation
            return paragraphs.isEmpty ? [] : [.translate(id, run: translation.run, paragraphs: paragraphs)]

        case .started(let id, let run, let credit):
            guard isUnderWay(id, run, in: state) else { return [] }
            state.messages[id]?.credit = credit
            return []

        case .partTranslated(let id, let run, let translations):
            guard isUnderWay(id, run, in: state) else { return [] }
            state.messages[id]?.translations.merge(translations) { _, new in new }
            return []

        case .finished(let id, let run, let error):
            guard isUnderWay(id, run, in: state), var translation = state.messages[id] else { return [] }
            if let error {
                translation.phase = .failed(error)
            } else if translation.translations.isEmpty {
                translation.phase = .failed(TranslationError(.missing, ""))
            } else {
                translation.phase = .finished
            }
            state.messages[id] = translation
            return []

        case .originalRequested(let id):
            state.messages[id]?.isShown = false
            return []
        }
    }

    /// Begins a new request for a message's translation, shown from the start.
    private func startOver(_ id: MessageSummary.ID, in state: inout State) {
        state.messages[id] = MessageTranslation(run: (state.messages[id]?.run ?? 0) + 1)
    }

    /// Whether a request is the one this message is waiting on.
    private func isUnderWay(_ id: MessageSummary.ID, _ run: Int, in state: State) -> Bool {
        state.messages[id]?.run == run && state.messages[id]?.phase == .translating
    }

    /// How many requests to a service run at once.
    private static let concurrentRequests = 3

    /// - Parameter route: the service and language chosen at the moment a
    ///   translation is asked for, or why none can be reached.
    public static func effects(
        route: @escaping @Sendable () async -> Result<TranslationRoute, TranslationError>,
        transport: any HTTPTransport
    ) -> EffectRunner<TranslationFeature> {
        { effect, send in
            switch effect {
            case .translate(let id, let run, let paragraphs):
                let chosen: TranslationRoute
                switch await route() {
                case .success(let route): chosen = route
                case .failure(let error):
                    await send(.finished(id, run: run, error))
                    return
                }
                await send(.started(id, run: run, .init(service: chosen.service.name, language: chosen.language)))

                let translator = chosen.translator(transport: transport)
                let batches = planBatches(sizes: paragraphs.map(\.count), limits: chosen.batchLimits)
                var failure: TranslationError?
                // A few batches at a time, each shown as it arrives. The first
                // failure stops what has not started; what arrived stays.
                for start in stride(from: 0, to: batches.count, by: concurrentRequests) where failure == nil {
                    let wave = batches[start..<min(start + concurrentRequests, batches.count)]
                    await withTaskGroup(of: Result<[Int: String], TranslationError>.self) { group in
                        for batch in wave {
                            group.addTask {
                                do throws(TranslationError) {
                                    let translated = try await translator.translate(Array(paragraphs[batch]), into: chosen.language)
                                    let byParagraph = zip(batch, translated).compactMap { index, text in text.map { (index, $0) } }
                                    return .success(Dictionary(uniqueKeysWithValues: byParagraph))
                                } catch {
                                    return .failure(error)
                                }
                            }
                        }
                        for await outcome in group {
                            switch outcome {
                            case .success(let translations): await send(.partTranslated(id, run: run, translations))
                            case .failure(let error): failure = failure ?? error
                            }
                        }
                    }
                }
                await send(.finished(id, run: run, failure))
            }
        }
    }
}
