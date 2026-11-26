import Foundation

/// The wire format a model service speaks. There is one client per protocol.
public enum ModelProtocol: Hashable, Sendable {
    case openAI
    case anthropic
    case gemini
}

/// A service a person can have mail translated by.
public struct TranslationService: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Google Translate's public web endpoint, which takes no key.
        case google
        case deepL
        /// A language model, asked to translate in the protocol it speaks.
        case model(ModelProtocol)
    }

    public enum KeyNeed: Hashable, Sendable {
        case none
        /// A service the person runs themselves may take requests without one.
        case optional
        case required
    }

    public let id: String
    /// A proper name, shown as it is in every language.
    public let name: String
    public let kind: Kind
    /// Where a model service is reached. Empty for the one whose address the person enters.
    public let address: String
    /// The model to start with. Empty when the person has to name one.
    public let defaultModel: String
    public let keyNeed: KeyNeed
    /// Where a person creates an API key.
    public let keysURL: URL?

    init(
        id: String,
        name: String,
        kind: Kind,
        address: String = "",
        defaultModel: String = "",
        keyNeed: KeyNeed = .required,
        keysURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.address = address
        self.defaultModel = defaultModel
        self.keyNeed = keyNeed
        self.keysURL = keysURL.flatMap(URL.init(string:))
    }

    /// Whether the person chooses which model answers.
    public var takesModel: Bool {
        if case .model = kind { true } else { false }
    }

    /// Whether the person enters where the service is reached.
    public var takesAddress: Bool {
        address.isEmpty && takesModel
    }
}

/// The services on offer. The default models were the ones each provider's
/// documentation named on 2026-11-23; a person can enter any other.
public enum TranslationServices {
    public static let google = TranslationService(id: "google", name: "Google Translate", kind: .google, keyNeed: .none)

    public static let deepL = TranslationService(
        id: "deepl", name: "DeepL", kind: .deepL, keysURL: "https://www.deepl.com/your-account/keys"
    )

    public static let all: [TranslationService] = [
        google,
        deepL,
        TranslationService(
            id: "openai", name: "OpenAI", kind: .model(.openAI), address: "https://api.openai.com/v1",
            defaultModel: "gpt-6-luna", keysURL: "https://platform.openai.com/api-keys"
        ),
        TranslationService(
            id: "anthropic", name: "Claude", kind: .model(.anthropic), address: "https://api.anthropic.com",
            defaultModel: "claude-opus-5-5", keysURL: "https://platform.claude.com/settings/keys"
        ),
        TranslationService(
            id: "gemini", name: "Gemini", kind: .model(.gemini), address: "https://generativelanguage.googleapis.com/v1beta",
            defaultModel: "gemini-3.5-flash-lite", keysURL: "https://aistudio.google.com/apikey"
        ),
        TranslationService(
            id: "openrouter", name: "OpenRouter", kind: .model(.openAI), address: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-6-luna", keysURL: "https://openrouter.ai/settings/keys"
        ),
        // Any other service that speaks OpenAI's protocol, a model on this Mac included.
        TranslationService(id: "custom", name: "Other (OpenAI-Compatible)", kind: .model(.openAI), keyNeed: .optional),
    ]

    /// The service with an id, or the one to start with for an id that is no longer offered.
    public static func service(id: String) -> TranslationService {
        all.first { $0.id == id } ?? google
    }
}

/// What a person has chosen about translation, apart from the API keys.
public struct TranslationSettings: Codable, Equatable, Sendable {
    public enum Display: String, Codable, CaseIterable, Sendable {
        /// Each paragraph's translation follows the paragraph.
        case withOriginal
        /// The translation takes the paragraph's place.
        case translationOnly
    }

    /// Id of a service in `TranslationServices`.
    public var service: String
    /// Code of a language in `TranslationLanguages`.
    public var language: String
    public var display: Display
    /// The model chosen for each service, by its id. One nobody touched has no entry.
    public var models: [String: String]
    /// Where the custom service is reached.
    public var customAddress: String

    /// What a person starts with: Google Translate, which needs no setting up.
    public init(language: String) {
        service = TranslationServices.google.id
        self.language = language
        display = .withOriginal
        models = [:]
        customAddress = ""
    }

    public var chosenService: TranslationService {
        TranslationServices.service(id: service)
    }

    /// The model a service would be asked for now.
    public func model(for service: TranslationService) -> String {
        let entered = models[service.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return entered.isEmpty ? service.defaultModel : entered
    }

    /// The chosen service as it would be called now.
    /// - Parameter apiKey: the service's stored key, if it has one.
    /// - Throws: `.notSetUp`, saying what is missing.
    public func route(apiKey: String?) throws(TranslationError) -> TranslationRoute {
        let service = chosenService
        guard let language = TranslationLanguages.language(code: language) else {
            throw TranslationError(.notSetUp, "Choose a language to translate into in Settings.")
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if service.keyNeed == .required, key.isEmpty {
            throw TranslationError(.notSetUp, "Enter an API key for \(service.name) in Settings.")
        }

        switch service.kind {
        case .google:
            return TranslationRoute(service: service, language: language, access: .google)
        case .deepL:
            return TranslationRoute(service: service, language: language, access: .deepL(apiKey: key))
        case .model(let modelProtocol):
            let address = service.takesAddress ? customAddress.trimmingCharacters(in: .whitespaces) : service.address
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
                throw TranslationError(.notSetUp, "Enter the address of the translation service in Settings.")
            }
            let model = model(for: service)
            guard !model.isEmpty else {
                throw TranslationError(.notSetUp, "Choose a model for \(service.name) in Settings.")
            }
            let endpoint = ModelEndpoint(modelProtocol: modelProtocol, address: url, model: model, apiKey: key)
            return TranslationRoute(service: service, language: language, access: .model(endpoint))
        }
    }
}

/// A model service with everything a request to it needs.
public struct ModelEndpoint: Equatable, Sendable {
    public let modelProtocol: ModelProtocol
    public let address: URL
    public let model: String
    /// Empty for a service that takes requests without one.
    public let apiKey: String
}

/// What one translation needs besides the text: the language it goes into and the
/// way to reach the service that makes it.
public struct TranslationRoute: Equatable, Sendable {
    public enum Access: Equatable, Sendable {
        case google
        case deepL(apiKey: String)
        case model(ModelEndpoint)
    }

    public let service: TranslationService
    public let language: TranslationLanguage
    public let access: Access

    func translator(transport: any HTTPTransport) -> any Translator {
        switch access {
        case .google: GoogleTranslator(transport: transport)
        case .deepL(let apiKey): DeepLTranslator(apiKey: apiKey, transport: transport)
        case .model(let endpoint): ModelTranslator(endpoint: endpoint, transport: transport)
        }
    }

    /// How much text one request to the service carries. A model loses track of
    /// segments when given many at once; the others take long lists.
    var batchLimits: BatchLimits {
        switch access {
        case .google: BatchLimits(maxItems: 40, maxSize: 6000)
        case .deepL: BatchLimits(maxItems: 40, maxSize: 20000)
        case .model: BatchLimits(maxItems: 12, maxSize: 3000)
        }
    }
}
