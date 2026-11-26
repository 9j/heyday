import Foundation

/// Why a translation could not be made.
public struct TranslationError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The service needs something that has not been entered: a key, a model, an address.
        case notSetUp
        /// The service did not accept the key.
        case auth
        /// The account behind the key has nothing left to spend.
        case quota
        case rateLimit
        case server
        case network
        /// The service would not take the request as sent.
        case badRequest
        /// A model declined to translate the text.
        case refused
        /// The service answered without a translation.
        case missing

        /// What services' own error codes mean. A code decides ahead of the HTTP
        /// status, because services report exhausted credit and rejected keys under
        /// several statuses.
        private static let kindForCode: [String: Kind] = [
            "insufficient_quota": .quota,
            "billing_error": .quota,
            "enforced_spend_limit_reached": .quota,
            "API_KEY_INVALID": .auth,
        ]

        /// Classifies a failed request by the codes the service attached and, when
        /// none of them is known, by its status.
        init(httpStatus status: Int, codes: [String] = []) {
            if let kind = codes.lazy.compactMap({ Self.kindForCode[$0] }).first {
                self = kind
                return
            }
            switch status {
            case 401, 403: self = .auth
            // 456 is DeepL's own status for a used-up quota.
            case 402, 456: self = .quota
            case 429: self = .rateLimit
            case 408, 500...: self = .server
            default: self = .badRequest
            }
        }
    }

    public let kind: Kind
    /// The service's own wording, or what is missing, as detail for the reader.
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// What to tell the reader.
    public var userMessage: String {
        let summary = switch kind {
        case .notSetUp: ""
        case .auth: "The translation service did not accept the API key."
        case .quota: "The translation service account has no credit or quota left."
        case .rateLimit: "The translation service is taking too many requests right now. Try again in a moment."
        case .server: "The translation service had a problem."
        case .network: "The translation service could not be reached."
        case .badRequest: "The translation service would not take the request."
        case .refused: "The model declined to translate this text."
        case .missing: "The translation service answered without a translation."
        }
        return [summary, message].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
