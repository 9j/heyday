import Foundation

/// A picture fetched from the address an email gave for it.
public struct RemoteImage: Equatable, Sendable {
    public let data: Data
    /// Such as `image/png`.
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ImageLoadError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Fetches the remote images of an email, when the person asks to see them.
public protocol RemoteImageLoader: Sendable {
    func image(at url: URL) async throws(ImageLoadError) -> RemoteImage
}

/// Fetches images giving away as little as a request can: no cookies in or out, no
/// stored credentials, nothing cached to disk, no referrer, and the same plain
/// request headers for every sender. The sender's server still sees that the
/// address was fetched, and from which network address.
public struct URLSessionImageLoader: RemoteImageLoader {
    /// Larger than any picture an email should carry by reference.
    private static let sizeLimit = 25 * 1024 * 1024

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["Accept": "image/*", "User-Agent": "Mozilla/5.0"]
        session = URLSession(configuration: configuration)
    }

    public func image(at url: URL) async throws(ImageLoadError) -> RemoteImage {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ImageLoadError(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImageLoadError("The server answered \(http.statusCode).")
        }
        guard let mimeType = response.mimeType?.lowercased(), mimeType.hasPrefix("image/") else {
            throw ImageLoadError("That address did not return an image.")
        }
        guard data.count <= Self.sizeLimit else {
            throw ImageLoadError("The image is too large to show.")
        }
        return RemoteImage(data: data, mimeType: mimeType)
    }
}
