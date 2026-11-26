import Foundation

/// Sends a request to a translation service and returns the reply. Tests substitute
/// their own.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws(TranslationError) -> (Data, HTTPURLResponse)
}

/// Requests over a session that keeps nothing between them: no cookies, no stored
/// credentials, no cache.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        // A model can take a while to answer a long text in one reply.
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws(TranslationError) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw TranslationError(.server, "The reply was not an HTTP response.")
            }
            return (data, response)
        } catch let error as TranslationError {
            throw error
        } catch {
            throw TranslationError(.network, error.localizedDescription)
        }
    }
}

extension HTTPTransport {
    /// POSTs JSON and returns the reply's body once the service accepted the request.
    func postJSON(_ body: some Encodable, to url: URL, headers: [String: String]) async throws(TranslationError) -> Data {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw TranslationError(.badRequest, error.localizedDescription)
        }
        return try await post(encoded, as: "application/json", to: url, headers: headers)
    }

    /// POSTs a body and returns the reply's body once the service accepted the request.
    func post(_ body: Data, as contentType: String, to url: URL, headers: [String: String]) async throws(TranslationError) -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let failure = ServiceFailure(body: data)
            throw TranslationError(
                .init(httpStatus: response.statusCode, codes: failure.codes),
                failure.message ?? "HTTP \(response.statusCode)"
            )
        }
        return data
    }
}

/// What a service's error reply says. Services use `{"error": {"message", "code",
/// "type", "details"}}`, `{"error": "…"}`, `{"message": "…"}` or plain text; the
/// codes say what went wrong more exactly than the status.
private struct ServiceFailure {
    var message: String?
    var codes: [String] = []

    init(body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // A web page in place of an answer says nothing a reader can use.
            message = text.isEmpty || text.hasPrefix("<") ? nil : text
            return
        }
        guard let error = json["error"] as? [String: Any] else {
            message = json["error"] as? String ?? json["message"] as? String
            return
        }
        message = error["message"] as? String
        // Claude names a spend cap in `details.error_code`; Gemini names a bad key in `details[].reason`.
        let detail = (error["details"] as? [String: Any])?["error_code"]
        let reasons = (error["details"] as? [[String: Any]] ?? []).map { $0["reason"] }
        codes = ([error["code"], error["type"], detail] + reasons).compactMap { $0 as? String }
    }
}

/// Decodes a service's reply, treating one of an unexpected shape as its fault.
func decodeReply<Reply: Decodable>(_ type: Reply.Type, from data: Data) throws(TranslationError) -> Reply {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw TranslationError(.server, "The service sent a reply that could not be read.")
    }
}
