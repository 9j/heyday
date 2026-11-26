import Foundation
import Testing
@testable import HeydayKit

/// A service that answers from a script and remembers what it was sent.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(status: Int, body: String)]
    private var sent: [URLRequest] = []

    init(_ replies: (status: Int, body: String)...) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws(TranslationError) -> (Data, HTTPURLResponse) {
        let reply: (status: Int, body: String)? = lock.withLock {
            sent.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else { throw TranslationError(.network, "No reply scripted.") }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }
}

/// Keys held in memory, counting how often one is read.
private final class MemoryKeys: TranslationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    private var readCount = 0

    init(_ keys: [String: String] = [:]) {
        self.keys = keys
    }

    var reads: Int { lock.withLock { readCount } }

    func hasKey(for service: String) -> Bool { lock.withLock { keys[service] != nil } }

    func key(for service: String) throws(StorageError) -> String? {
        lock.withLock {
            readCount += 1
            return keys[service]
        }
    }

    func save(_ key: String, for service: String) throws(StorageError) {
        lock.withLock { keys[service] = key.isEmpty ? nil : key }
    }
}

private let korean = TranslationLanguages.language(code: "ko")!

private func body(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
}

private func error(_ operation: () async throws(TranslationError) -> some Any) async -> TranslationError? {
    do throws(TranslationError) {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

@Suite struct TranslationLanguagesTests {
    @Test func aLocaleStartsOnItsOwnLanguage() {
        #expect(TranslationLanguages.code(forLocale: "ko-KR") == "ko")
        #expect(TranslationLanguages.code(forLocale: "pt_BR") == "pt")
        #expect(TranslationLanguages.code(forLocale: "zh-Hant-TW") == "zh-TW")
        #expect(TranslationLanguages.code(forLocale: "zh-Hans-CN") == "zh-CN")
    }

    @Test func aLocaleWhoseLanguageIsNotListedStartsOnEnglish() {
        #expect(TranslationLanguages.code(forLocale: "tlh-US") == "en")
        #expect(TranslationLanguages.code(forLocale: "") == "en")
    }
}

@Suite struct TranslationSettingsTests {
    @Test func aPersonStartsOnGoogleTranslateWhichNeedsNoKey() throws {
        let settings = TranslationSettings(language: "ko")

        let route = try settings.route(apiKey: nil)

        #expect(route.service == TranslationServices.google)
        #expect(route.access == .google)
        #expect(route.language == korean)
    }

    @Test func aServiceThatNeedsAKeySaysSoUntilItHasOne() async throws {
        var settings = TranslationSettings(language: "ko")
        settings.service = "deepl"

        let missing = await error { () throws(TranslationError) in try settings.route(apiKey: "  ") }
        #expect(missing == TranslationError(.notSetUp, "Enter an API key for DeepL in Settings."))
        #expect(try settings.route(apiKey: " abc:fx\n").access == .deepL(apiKey: "abc:fx"))
    }

    @Test func aModelServiceIsCalledWithItsOwnModelUnlessAnotherWasEntered() throws {
        var settings = TranslationSettings(language: "ko")
        settings.service = "anthropic"

        guard case .model(let standard) = try settings.route(apiKey: "key").access else { Issue.record("not a model route"); return }
        #expect(standard.model == "claude-opus-5-5")
        #expect(standard.address == URL(string: "https://api.anthropic.com")!)
        #expect(standard.modelProtocol == .anthropic)

        settings.models["anthropic"] = " claude-haiku-5-5 "
        guard case .model(let entered) = try settings.route(apiKey: "key").access else { Issue.record("not a model route"); return }
        #expect(entered.model == "claude-haiku-5-5")
    }

    @Test func theCustomServiceNeedsAnAddressAndAModelButNoKey() async throws {
        var settings = TranslationSettings(language: "ko")
        settings.service = "custom"

        let noAddress = await error { () throws(TranslationError) in try settings.route(apiKey: nil) }
        #expect(noAddress?.kind == .notSetUp)

        settings.customAddress = "http://localhost:11434/v1"
        let noModel = await error { () throws(TranslationError) in try settings.route(apiKey: nil) }
        #expect(noModel == TranslationError(.notSetUp, "Choose a model for Other (OpenAI-Compatible) in Settings."))

        settings.models["custom"] = "llama"
        guard case .model(let endpoint) = try settings.route(apiKey: nil).access else { Issue.record("not a model route"); return }
        #expect(endpoint.apiKey.isEmpty)
        #expect(endpoint.address == URL(string: "http://localhost:11434/v1")!)
    }

    @Test func aServiceThatIsNoLongerOfferedFallsBackToTheFirst() {
        var settings = TranslationSettings(language: "ko")
        settings.service = "gone"

        #expect(settings.chosenService == TranslationServices.google)
    }

    @Test func aKeyIsReadOnlyForAServiceThatTakesOne() throws {
        let keys = MemoryKeys(["deepl": "abc"])
        var settings = TranslationSettings(language: "ko")

        _ = try settings.route(readingKeyFrom: keys).get()
        #expect(keys.reads == 0)

        settings.service = "deepl"
        #expect(try settings.route(readingKeyFrom: keys).get().access == .deepL(apiKey: "abc"))
        #expect(keys.reads == 1)
    }
}

@Suite struct TranslationBatchTests {
    @Test func itemsAreGroupedInOrderWithinBothLimits() {
        let limits = BatchLimits(maxItems: 3, maxSize: 100)

        #expect(planBatches(sizes: [10, 10, 10, 10], limits: limits) == [0..<3, 3..<4])
        #expect(planBatches(sizes: [60, 60, 30], limits: limits) == [0..<1, 1..<3])
        #expect(planBatches(sizes: [], limits: limits).isEmpty)
    }

    @Test func anItemLargerThanTheLimitGetsABatchOfItsOwn() {
        #expect(planBatches(sizes: [10, 500, 10], limits: BatchLimits(maxItems: 5, maxSize: 100)) == [0..<1, 1..<2, 2..<3])
    }
}

@Suite struct GoogleTranslatorTests {
    @Test func everyTextTravelsInOneRequestAndComesBackInOrder() async throws {
        let transport = ScriptedTransport((200, #"[["안녕하세요","en"],["A&B는 <g0>여기</g0>","en"]]"#))

        let translations = try await GoogleTranslator(transport: transport).translate(["Hello there", "A&B is <g0>here</g0>"], into: korean)

        #expect(translations == ["안녕하세요", "A&B는 <g0>여기</g0>"])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(request.url?.host == "translate.googleapis.com")
        #expect(query.contains(URLQueryItem(name: "tl", value: "ko")))
        #expect(query.contains(URLQueryItem(name: "sl", value: "auto")))
        #expect(body(request) == "q=Hello%20there&q=A%26B%20is%20%3Cg0%3Ehere%3C%2Fg0%3E")
    }

    @Test func aReplyOfBareTranslationsIsReadToo() async throws {
        let transport = ScriptedTransport((200, #"["하나",""]"#))

        #expect(try await GoogleTranslator(transport: transport).translate(["one", "two"], into: korean) == ["하나", nil])
    }

    @Test func aReplyThatDoesNotMatchTheTextsIsTheServicesFault() async {
        let transport = ScriptedTransport((200, #"[["하나","en"]]"#))

        let failure = await error { () throws(TranslationError) in try await GoogleTranslator(transport: transport).translate(["one", "two"], into: korean) }
        #expect(failure?.kind == .server)
    }

    @Test func beingTurnedAwayIsReportedWithoutTheWebPageThatSaysSo() async {
        let transport = ScriptedTransport((429, "<html><body>Sorry…</body></html>"))

        let failure = await error { () throws(TranslationError) in try await GoogleTranslator(transport: transport).translate(["one"], into: korean) }
        #expect(failure == TranslationError(.rateLimit, "HTTP 429"))
    }
}

@Suite struct DeepLTranslatorTests {
    @Test func aFreePlanKeyGoesToTheFreeHostAndAnyOtherToThePaidOne() {
        #expect(DeepLTranslator.endpoint(for: "abc:fx").host == "api-free.deepl.com")
        #expect(DeepLTranslator.endpoint(for: "abc").host == "api.deepl.com")
    }

    @Test func languagesAreNamedTheWayDeepLNamesThem() {
        func code(_ language: String) -> String { DeepLTranslator.targetCode(for: TranslationLanguages.language(code: language)!) }

        #expect(code("ko") == "KO")
        #expect(code("en") == "EN-US")
        #expect(code("pt") == "PT-BR")
        #expect(code("zh-CN") == "ZH-HANS")
        #expect(code("zh-TW") == "ZH-HANT")
    }

    @Test func textsGoAsXMLSoTheirTagsStayInPlace() async throws {
        let transport = ScriptedTransport((200, #"{"translations":[{"detected_source_language":"EN","text":"A&amp;B &lt; <g0>여기</g0><x1/>"}]}"#))

        let translations = try await DeepLTranslator(apiKey: "abc:fx", transport: transport).translate(["A&B < <g0>here</g0><x1/>"], into: korean)

        #expect(translations == ["A&B < <g0>여기</g0><x1/>"])
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key abc:fx")
        let sent = try json(request)
        #expect(sent["text"] as? [String] == ["A&amp;B &lt; <g0>here</g0><x1/>"])
        #expect(sent["target_lang"] as? String == "KO")
        #expect(sent["tag_handling"] as? String == "xml")
    }

    @Test func aUsedUpQuotaAndARejectedKeyAreToldApart() async {
        let spent = ScriptedTransport((456, #"{"message":"Quota Exceeded"}"#))
        let rejected = ScriptedTransport((403, ""))

        let quota = await error { () throws(TranslationError) in try await DeepLTranslator(apiKey: "k", transport: spent).translate(["one"], into: korean) }
        let auth = await error { () throws(TranslationError) in try await DeepLTranslator(apiKey: "k", transport: rejected).translate(["one"], into: korean) }

        #expect(quota == TranslationError(.quota, "Quota Exceeded"))
        #expect(auth == TranslationError(.auth, "HTTP 403"))
    }
}

@Suite struct TranslationSegmentsTests {
    @Test func textsTravelAsNumberedSegments() {
        #expect(TranslationSegments.encode(["first", "second\nline"]) == "[[1]]\nfirst\n\n[[2]]\nsecond\nline")
    }

    @Test func aReplyIsMatchedToItsSegmentsByNumber() {
        let reply = "[[2]]\n둘째\n\n[[1]] 첫째\n"

        #expect(TranslationSegments.decode(reply, count: 3) == ["첫째", "둘째", nil])
    }

    @Test func aMarkerRepeatedLaterOrOutOfRangeChangesNothing() {
        let reply = "[[1]]\n첫째 [[9]] 인용\n[[1]]\n다시"

        #expect(TranslationSegments.decode(reply, count: 1) == ["첫째"])
    }
}

@Suite struct ModelTranslatorTests {
    private func endpoint(_ modelProtocol: ModelProtocol, model: String, address: String, key: String = "secret") -> ModelEndpoint {
        ModelEndpoint(modelProtocol: modelProtocol, address: URL(string: address)!, model: model, apiKey: key)
    }

    @Test func anOpenAIServiceIsAskedForEverySegmentAtOnce() async throws {
        let transport = ScriptedTransport((200, #"{"choices":[{"message":{"content":"<think>hm</think>[[1]]\n안녕\n\n[[2]]\n세계"}}]}"#))
        let translator = ModelTranslator(endpoint: endpoint(.openAI, model: "gpt-x", address: "https://api.example.com/v1"), transport: transport)

        let translations = try await translator.translate(["Hello", "World"], into: korean)

        #expect(translations == ["안녕", "세계"])
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let sent = try json(request)
        #expect(sent["model"] as? String == "gpt-x")
        let messages = try #require(sent["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[0]["content"]?.contains("into Korean") == true)
        #expect(messages[1]["content"] == "[[1]]\nHello\n\n[[2]]\nWorld")
    }

    @Test func aModelOnThePersonsOwnMachineIsAskedWithoutAKey() async throws {
        let transport = ScriptedTransport((200, #"{"choices":[{"message":{"content":"[[1]] 안녕"}}]}"#))
        let translator = ModelTranslator(endpoint: endpoint(.openAI, model: "llama", address: "http://localhost:11434/v1", key: ""), transport: transport)

        _ = try await translator.translate(["Hello"], into: korean)

        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func segmentsAModelLeftOutAreAskedForOnceMore() async throws {
        let transport = ScriptedTransport(
            (200, #"{"choices":[{"message":{"content":"[[1]]\n하나\n\n[[3]]\n셋"}}]}"#),
            (200, #"{"choices":[{"message":{"content":"[[1]]\n둘"}}]}"#)
        )
        let translator = ModelTranslator(endpoint: endpoint(.openAI, model: "gpt-x", address: "https://api.example.com/v1"), transport: transport)

        let translations = try await translator.translate(["one", "two", "three"], into: korean)

        #expect(translations == ["하나", "둘", "셋"])
        #expect(transport.requests.count == 2)
        let second = try #require((try json(transport.requests[1]))["messages"] as? [[String: String]])
        #expect(second[1]["content"] == "[[1]]\ntwo")
    }

    @Test func claudeIsAskedInItsOwnProtocolWithAFallbackForDeclinedRequests() async throws {
        let transport = ScriptedTransport((200, #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"[[1]]\n안녕"}],"stop_reason":"end_turn"}"#))
        let translator = ModelTranslator(endpoint: endpoint(.anthropic, model: "claude-opus-5-5", address: "https://api.anthropic.com"), transport: transport)

        #expect(try await translator.translate(["Hello"], into: korean) == ["안녕"])

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let sent = try json(request)
        #expect(sent["model"] as? String == "claude-opus-5-5")
        #expect(sent["max_tokens"] as? Int == 16000)
        #expect(sent["fallbacks"] as? String == "default")
        #expect((sent["output_config"] as? [String: String])?["effort"] == "low")
        #expect((sent["system"] as? String)?.contains("into Korean") == true)
    }

    @Test func aClaudeModelWithoutTheFallbackIsNotSentOne() async throws {
        let transport = ScriptedTransport((200, #"{"content":[{"type":"text","text":"[[1]]\n안녕"}],"stop_reason":"end_turn"}"#))
        let translator = ModelTranslator(endpoint: endpoint(.anthropic, model: "claude-haiku-5-5", address: "https://api.anthropic.com"), transport: transport)

        _ = try await translator.translate(["Hello"], into: korean)

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try json(request)["fallbacks"] == nil)
    }

    @Test func aDeclinedRequestIsARefusalNotAnEmptyTranslation() async {
        let transport = ScriptedTransport((200, #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Declined."}}"#))
        let translator = ModelTranslator(endpoint: endpoint(.anthropic, model: "claude-opus-5-5", address: "https://api.anthropic.com"), transport: transport)

        let failure = await error { () throws(TranslationError) in try await translator.translate(["Hello"], into: korean) }
        #expect(failure == TranslationError(.refused, "Declined."))
    }

    @Test func geminiIsAskedInItsOwnProtocolAndItsReasoningLeftOut() async throws {
        let transport = ScriptedTransport((200, #"{"candidates":[{"content":{"parts":[{"text":"thinking…","thought":true},{"text":"[[1]]\n안녕"}]},"finishReason":"STOP"}]}"#))
        let translator = ModelTranslator(endpoint: endpoint(.gemini, model: "gemini-x", address: "https://generativelanguage.googleapis.com/v1beta"), transport: transport)

        #expect(try await translator.translate(["Hello"], into: korean) == ["안녕"])

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret")
    }

    @Test func aServicesOwnErrorCodeDecidesAheadOfTheStatus() async {
        let transport = ScriptedTransport((429, #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#))
        let translator = ModelTranslator(endpoint: endpoint(.openAI, model: "gpt-x", address: "https://api.example.com/v1"), transport: transport)

        let failure = await error { () throws(TranslationError) in try await translator.translate(["Hello"], into: korean) }
        #expect(failure == TranslationError(.quota, "You exceeded your current quota."))
    }
}

@Suite struct TranslationSettingsFeatureTests {
    private let feature = TranslationSettingsFeature()

    @Test func savedChoicesReplaceTheOnesStartedWith() {
        var state = TranslationSettingsFeature.State(settings: TranslationSettings(language: "en"))
        var saved = TranslationSettings(language: "ko")
        saved.service = "deepl"

        #expect(feature.reduce(&state, .loadRequested) == [.load])
        #expect(feature.reduce(&state, .loaded(saved, servicesWithKey: ["deepl"])).isEmpty)

        #expect(state.settings == saved)
        #expect(state.servicesWithKey == ["deepl"])
    }

    @Test func withNothingSavedTheStartingChoicesStandAndAreNotWritten() {
        var state = TranslationSettingsFeature.State(settings: TranslationSettings(language: "ko"))

        #expect(feature.reduce(&state, .loaded(nil, servicesWithKey: [])).isEmpty)
        #expect(state.settings == TranslationSettings(language: "ko"))
    }

    @Test func aChangeIsSavedAndTheSameChoiceAgainIsNot() {
        var state = TranslationSettingsFeature.State(settings: TranslationSettings(language: "ko"))
        var changed = state.settings
        changed.display = .translationOnly

        #expect(feature.reduce(&state, .changed(changed)) == [.save(changed)])
        #expect(feature.reduce(&state, .changed(changed)).isEmpty)
    }

    @Test func aKeyIsStoredTrimmedAndAnEmptyOneForgetsIt() {
        var state = TranslationSettingsFeature.State(settings: TranslationSettings(language: "ko"))

        #expect(feature.reduce(&state, .keyEntered(" abc:fx\n", service: "deepl")) == [.storeKey("abc:fx", service: "deepl")])
        _ = feature.reduce(&state, .keyStored(service: "deepl", isStored: true))
        #expect(state.servicesWithKey == ["deepl"])

        #expect(feature.reduce(&state, .keyEntered("", service: "deepl")) == [.storeKey("", service: "deepl")])
        _ = feature.reduce(&state, .keyStored(service: "deepl", isStored: false))
        #expect(state.servicesWithKey.isEmpty)
    }

    @Test func aStorageProblemStaysUntilItIsSeen() {
        var state = TranslationSettingsFeature.State(settings: TranslationSettings(language: "ko"))

        _ = feature.reduce(&state, .storageFailed("disk full"))
        #expect(state.storageProblem == "disk full")
        _ = feature.reduce(&state, .storageProblemDismissed)
        #expect(state.storageProblem == nil)
    }
}

@Suite struct TranslationFeatureTests {
    private let feature = TranslationFeature()
    private let id = MessageSummary.ID(mailbox: "INBOX", uid: 7)

    @Test func aTranslationWaitsForThePageThenAsksTheService() {
        var state = TranslationFeature.State()

        #expect(feature.reduce(&state, .requested(id)).isEmpty)
        #expect(state.messages[id]?.phase == .reading)

        #expect(feature.reduce(&state, .paragraphsRead(id, ["Hello", "World"])) == [.translate(id, run: 1, paragraphs: ["Hello", "World"])])
        #expect(state.messages[id]?.phase == .translating)
    }

    @Test func translationsShowAsTheyArriveAndTheLastOneFinishesIt() {
        var state = TranslationFeature.State()
        _ = feature.reduce(&state, .requested(id))
        _ = feature.reduce(&state, .paragraphsRead(id, ["Hello", "World"]))

        _ = feature.reduce(&state, .started(id, run: 1, .init(service: "Google Translate", language: korean)))
        _ = feature.reduce(&state, .partTranslated(id, run: 1, [1: "세계"]))
        #expect(state.messages[id]?.translations == [1: "세계"])
        #expect(state.messages[id]?.phase == .translating)

        _ = feature.reduce(&state, .partTranslated(id, run: 1, [0: "안녕"]))
        _ = feature.reduce(&state, .finished(id, run: 1, nil))

        #expect(state.messages[id]?.phase == .finished)
        #expect(state.messages[id]?.translations == [0: "안녕", 1: "세계"])
        #expect(state.messages[id]?.credit == .init(service: "Google Translate", language: korean))
    }

    @Test func aMessageWithNoTextIsFinishedWithoutAskingAnyone() {
        var state = TranslationFeature.State()
        _ = feature.reduce(&state, .requested(id))

        #expect(feature.reduce(&state, .paragraphsRead(id, [])).isEmpty)
        #expect(state.messages[id]?.phase == .finished)
    }

    @Test func aFailureKeepsWhatArrivedAndAskingAgainStartsOver() {
        var state = TranslationFeature.State()
        _ = feature.reduce(&state, .requested(id))
        _ = feature.reduce(&state, .paragraphsRead(id, ["Hello", "World"]))
        _ = feature.reduce(&state, .partTranslated(id, run: 1, [0: "안녕"]))

        _ = feature.reduce(&state, .finished(id, run: 1, TranslationError(.rateLimit, "slow down")))
        #expect(state.messages[id]?.phase == .failed(TranslationError(.rateLimit, "slow down")))
        #expect(state.messages[id]?.translations == [0: "안녕"])

        _ = feature.reduce(&state, .requested(id))
        #expect(state.messages[id] == MessageTranslation(run: 2))
    }

    @Test func choosingAnotherLanguageTranslatesAfreshAndTheEarlierAnswerIsDropped() {
        var state = TranslationFeature.State()
        _ = feature.reduce(&state, .requested(id))
        _ = feature.reduce(&state, .paragraphsRead(id, ["Hello"]))
        _ = feature.reduce(&state, .partTranslated(id, run: 1, [0: "안녕"]))
        _ = feature.reduce(&state, .finished(id, run: 1, nil))

        #expect(feature.reduce(&state, .retranslationRequested(id)).isEmpty)
        #expect(state.messages[id] == MessageTranslation(run: 2))
        #expect(feature.reduce(&state, .paragraphsRead(id, ["Hello"])) == [.translate(id, run: 2, paragraphs: ["Hello"])])

        // What the first request still sends back is for a translation nobody is waiting on.
        _ = feature.reduce(&state, .partTranslated(id, run: 1, [0: "안녕"]))
        _ = feature.reduce(&state, .finished(id, run: 1, nil))
        #expect(state.messages[id]?.translations.isEmpty == true)
        #expect(state.messages[id]?.phase == .translating)

        _ = feature.reduce(&state, .partTranslated(id, run: 2, [0: "こんにちは"]))
        _ = feature.reduce(&state, .finished(id, run: 2, nil))
        #expect(state.messages[id]?.translations == [0: "こんにちは"])
        #expect(state.messages[id]?.phase == .finished)
    }

    @Test func aServiceThatAnswersWithNothingHasNotTranslated() {
        var state = TranslationFeature.State()
        _ = feature.reduce(&state, .requested(id))
        _ = feature.reduce(&state, .paragraphsRead(id, ["Hello"]))

        _ = feature.reduce(&state, .finished(id, run: 1, nil))

        #expect(state.messages[id]?.phase == .failed(TranslationError(.missing, "")))
    }

    @Test func theOriginalAndTheTranslationCanBeSwitchedWithoutTranslatingAgain() {
        var state = TranslationFeature.State()
        _ = feature.reduce(&state, .requested(id))
        _ = feature.reduce(&state, .paragraphsRead(id, ["Hello"]))
        _ = feature.reduce(&state, .partTranslated(id, run: 1, [0: "안녕"]))
        _ = feature.reduce(&state, .finished(id, run: 1, nil))

        _ = feature.reduce(&state, .originalRequested(id))
        #expect(state.messages[id]?.isShown == false)

        #expect(feature.reduce(&state, .requested(id)).isEmpty)
        #expect(state.messages[id]?.isShown == true)
        #expect(state.messages[id]?.translations == [0: "안녕"])
    }

    @Test func aMessageAlreadyInTheReadersLanguageReadsAsWritten() {
        var state = TranslationFeature.State()
        _ = feature.reduce(&state, .requested(id))
        _ = feature.reduce(&state, .paragraphsRead(id, ["안녕하세요 <g0>여기</g0>", "둘째 문단"]))
        _ = feature.reduce(&state, .partTranslated(id, run: 1, [0: "안녕하세요 <g0>여기</g0> ", 1: "둘째 문단"]))
        #expect(state.messages[id]?.readsAsWritten == false)

        _ = feature.reduce(&state, .finished(id, run: 1, nil))
        #expect(state.messages[id]?.readsAsWritten == true)

        var other = TranslationFeature.State()
        _ = feature.reduce(&other, .requested(id))
        _ = feature.reduce(&other, .paragraphsRead(id, ["Hello", "둘째 문단"]))
        _ = feature.reduce(&other, .partTranslated(id, run: 1, [0: "안녕", 1: "둘째 문단"]))
        _ = feature.reduce(&other, .finished(id, run: 1, nil))
        #expect(other.messages[id]?.readsAsWritten == false)
    }

    @Test func whatArrivesForAMessageNobodyAskedAboutIsIgnored() {
        var state = TranslationFeature.State()

        #expect(feature.reduce(&state, .paragraphsRead(id, ["Hello"])).isEmpty)
        _ = feature.reduce(&state, .partTranslated(id, run: 1, [0: "안녕"]))
        _ = feature.reduce(&state, .finished(id, run: 1, nil))

        #expect(state.messages.isEmpty)
    }

    /// The events an effect sends, in order.
    private actor Sent {
        var events: [TranslationFeature.Event] = []

        func add(_ event: TranslationFeature.Event) {
            events.append(event)
        }
    }

    @Test func theEffectTranslatesWithTheChosenServiceAndReportsItsProgress() async throws {
        let transport = ScriptedTransport((200, #"[["안녕","en"],["세계","en"]]"#))
        let route = try TranslationSettings(language: "ko").route(apiKey: nil)
        let run = TranslationFeature.effects(route: { .success(route) }, transport: transport)
        let sent = Sent()

        await run(.translate(id, run: 1, paragraphs: ["Hello", "World"])) { await sent.add($0) }

        let events = await sent.events
        #expect(events.count == 3)
        guard case .started(_, _, let credit) = events[0], case .partTranslated(_, _, let translations) = events[1], case .finished(_, _, nil) = events[2] else {
            Issue.record("unexpected events: \(events)")
            return
        }
        #expect(credit == .init(service: "Google Translate", language: korean))
        #expect(translations == [0: "안녕", 1: "세계"])
    }

    @Test func withNoServiceToReachNothingIsSent() async {
        let transport = ScriptedTransport()
        let run = TranslationFeature.effects(route: { .failure(TranslationError(.notSetUp, "Enter an API key for DeepL in Settings.")) }, transport: transport)
        let sent = Sent()

        await run(.translate(id, run: 1, paragraphs: ["Hello"])) { await sent.add($0) }

        let events = await sent.events
        guard events.count == 1, case .finished(_, _, let error?) = events[0] else {
            Issue.record("unexpected events: \(events)")
            return
        }
        #expect(error.kind == .notSetUp)
        #expect(transport.requests.isEmpty)
    }

    @Test func aFailedRequestEndsTheTranslationWithItsReason() async throws {
        let transport = ScriptedTransport((500, #"{"error":{"message":"boom"}}"#))
        let route = try TranslationSettings(language: "ko").route(apiKey: nil)
        let run = TranslationFeature.effects(route: { .success(route) }, transport: transport)
        let sent = Sent()

        await run(.translate(id, run: 1, paragraphs: ["Hello"])) { await sent.add($0) }

        guard case .finished(_, _, let error?) = await sent.events.last else {
            Issue.record("no failure reported")
            return
        }
        #expect(error == TranslationError(.server, "boom"))
    }
}

@Suite struct TranslationErrorTests {
    @Test func whatTheReaderIsToldNamesTheProblemThenTheServicesWords() {
        #expect(TranslationError(.auth, "Invalid key.").userMessage == "The translation service did not accept the API key. Invalid key.")
        #expect(TranslationError(.notSetUp, "Enter an API key for DeepL in Settings.").userMessage == "Enter an API key for DeepL in Settings.")
        #expect(TranslationError(.missing, "").userMessage == "The translation service answered without a translation.")
    }
}
