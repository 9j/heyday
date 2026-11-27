import Foundation

/// What the composer was opened to write.
public enum ComposeIntent: Hashable, Codable, Sendable {
    case newMessage
    case reply(to: MessageSummary.ID)
    case forward(MessageSummary.ID)
}

/// Writing an email: a new one, a reply or a forward.
public struct ComposeFeature: Feature {
    public struct State: Equatable, Sendable {
        public let intent: ComposeIntent
        public let sender: EmailAddress
        public var draft = Draft()
        public var phase: Phase

        public init(intent: ComposeIntent, sender: EmailAddress, draft: Draft = Draft()) {
            self.intent = intent
            self.sender = sender
            self.draft = draft
            // A reply or forward starts from the message it is about.
            phase = intent == .newMessage ? .editing(problem: nil) : .preparing
        }
    }

    public struct Draft: Equatable, Sendable {
        public var to = ""
        public var cc = ""
        public var bcc = ""
        public var subject = ""
        /// Plain text, as typed.
        public var body = ""
        /// The original message, carried under what was typed.
        public var quotedHTML: String?
        public var inReplyTo: String?
        public var references: [String] = []

        public init() {}
    }

    public enum Phase: Equatable, Sendable {
        case preparing
        case preparationFailed(MailError)
        case editing(problem: Problem?)
        case sending
        /// Delivered. Nothing more happens here; the composer closes.
        case sent
    }

    /// Why the draft was not sent.
    public enum Problem: Error, Equatable, Sendable {
        case noRecipients
        case invalidAddress(String)
        case refused(MailError)

        public var userMessage: String {
            switch self {
            case .noRecipients: "Add at least one recipient."
            case .invalidAddress(let address): "“\(address)” isn’t an email address."
            case .refused(let error): error.userMessage
            }
        }
    }

    public enum Field: Hashable, Sendable {
        case to, cc, bcc, subject, body
    }

    public enum Event: Sendable {
        case opened
        case originalLoaded(Result<FullMessage, MailError>)
        case edited(Field, String)
        case sendRequested
        case sendFinished(Result<Void, MailError>)
    }

    public enum Effect: Equatable, Sendable {
        case loadOriginal(MessageSummary.ID)
        case deliver(OutgoingMail)
    }

    public init() {}

    public func reduce(_ state: inout State, _ event: Event) -> [Effect] {
        switch event {
        case .opened:
            guard state.phase == .preparing else { return [] }
            switch state.intent {
            case .newMessage: return []
            case .reply(let id), .forward(let id): return [.loadOriginal(id)]
            }

        case .originalLoaded(.success(let original)):
            guard state.phase == .preparing else { return [] }
            if case .forward = state.intent {
                state.draft = Self.forwardDraft(of: original)
            } else {
                state.draft = Self.replyDraft(to: original)
            }
            state.phase = .editing(problem: nil)
            return []

        case .originalLoaded(.failure(let error)):
            guard state.phase == .preparing else { return [] }
            state.phase = .preparationFailed(error)
            return []

        case .edited(let field, let text):
            guard case .editing = state.phase else { return [] }
            switch field {
            case .to: state.draft.to = text
            case .cc: state.draft.cc = text
            case .bcc: state.draft.bcc = text
            case .subject: state.draft.subject = text
            case .body: state.draft.body = text
            }
            state.phase = .editing(problem: nil)
            return []

        case .sendRequested:
            guard case .editing = state.phase else { return [] }
            switch Self.outgoingMail(from: state.draft, sender: state.sender) {
            case .success(let mail):
                state.phase = .sending
                return [.deliver(mail)]
            case .failure(let problem):
                state.phase = .editing(problem: problem)
                return []
            }

        case .sendFinished(.success):
            guard state.phase == .sending else { return [] }
            state.phase = .sent
            return []

        case .sendFinished(.failure(let error)):
            guard state.phase == .sending else { return [] }
            state.phase = .editing(problem: .refused(error))
            return []
        }
    }

    // MARK: Draft rules

    static func replyDraft(to original: FullMessage) -> Draft {
        var draft = Draft()
        draft.to = original.summary.from?.address ?? ""
        draft.subject = prefixed("Re:", original.summary.subject)
        draft.inReplyTo = original.summary.messageID
        draft.references = original.references + [original.summary.messageID].compactMap { $0 }
        let author = HTMLText.escape(original.summary.from?.displayName ?? "the sender")
        let when = original.summary.date.map { " on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        draft.quotedHTML = "<div><br></div><div>\(author) wrote\(when):</div>"
            + "<blockquote style=\"margin:0 0 0 0.8em;padding-left:0.8em;border-left:2px solid #ccc\">\(quotable(original))</blockquote>"
        return draft
    }

    static func forwardDraft(of original: FullMessage) -> Draft {
        var draft = Draft()
        draft.subject = prefixed("Fwd:", original.summary.subject)
        let from = HTMLText.escape(original.summary.from?.formatted ?? "")
        let subject = HTMLText.escape(original.summary.subject)
        draft.quotedHTML = "<div><br></div><div>---------- Forwarded message ----------</div>"
            + "<div>From: \(from)</div><div>Subject: \(subject)</div><div><br></div>\(quotable(original))"
        return draft
    }

    /// The original as it may be passed on: without its tracking pixels, which would
    /// otherwise report on whoever reads the reply or forward as though they were you.
    private static func quotable(_ original: FullMessage) -> String {
        MailBodyProtector.protect(original.html).quotableHTML
    }

    /// Adds "Re:" or "Fwd:" unless the subject already starts with it.
    static func prefixed(_ prefix: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    static func outgoingMail(from draft: Draft, sender: EmailAddress) -> Result<OutgoingMail, Problem> {
        let to = addresses(in: draft.to)
        let cc = addresses(in: draft.cc)
        let bcc = addresses(in: draft.bcc)
        if let invalid = (to + cc + bcc).first(where: { !looksLikeEmailAddress($0.address) }) {
            return .failure(.invalidAddress(invalid.address))
        }
        guard !(to + cc + bcc).isEmpty else { return .failure(.noRecipients) }
        let quotedText = draft.quotedHTML.map { "\n\n" + HTMLText.plainText(fromHTML: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return .success(OutgoingMail(
            from: sender,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: draft.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            textBody: draft.body + quotedText,
            htmlBody: HTMLText.blocks(fromPlainText: draft.body) + (draft.quotedHTML ?? ""),
            inReplyTo: draft.inReplyTo,
            references: draft.references
        ))
    }

    /// Reads a recipient line: addresses separated by commas, semicolons or line
    /// breaks, each either bare or written `Name <address>`.
    static func addresses(in line: String) -> [EmailAddress] {
        line.split(whereSeparator: { ";\n".contains($0) })
            .flatMap { AddressList.parse(String($0)) + unparsed(String($0)) }
    }

    /// Entries the header parser would drop because they are not addresses at all,
    /// kept so that sending can name what is wrong instead of ignoring it.
    private static func unparsed(_ segment: String) -> [EmailAddress] {
        segment.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("@") && !$0.contains("<") && !$0.contains("\"") }
            .map { EmailAddress(address: $0) }
    }

    /// A deliberately loose check: something, an `@`, a dotted domain. The server
    /// does the real validation; this catches a recipient that is plainly not one.
    static func looksLikeEmailAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !address.contains(" ") else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }

    public static func effects(service: any MailService) -> EffectRunner<ComposeFeature> {
        { effect, send in
            switch effect {
            case .loadOriginal(let id):
                await send(.originalLoaded(await outcome { () throws(MailError) in
                    guard let message = try await service.messages([id]).first else {
                        throw MailError(.refused, "the message is no longer there")
                    }
                    return message
                }))
            case .deliver(let mail):
                await send(.sendFinished(await outcome { () throws(MailError) in try await service.send(mail) }))
            }
        }
    }
}
