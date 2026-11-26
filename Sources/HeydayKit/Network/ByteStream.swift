import Foundation

/// How a mail server connection is protected.
public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAP on 993, SMTP on 465).
    case tls
    /// Plain to begin with, upgraded with the protocol's STARTTLS command.
    case startTLS
    /// No encryption. Only sensible for a server on this same machine.
    case none
}

/// Where a mail server listens.
public struct ServerEndpoint: Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity

    public init(host: String, port: Int, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

/// The connection failed or dropped.
public struct StreamError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// A two-way byte connection to a server. IMAP and SMTP are both spoken over this,
/// and tests replace it with a scripted conversation.
public protocol ByteStream: Sendable {
    /// At least one byte. Throws when the server closes the connection or `timeout` passes.
    func read(timeout: TimeInterval) async throws(StreamError) -> Data
    func write(_ data: Data) async throws(StreamError)
    /// Switches the open connection to TLS, after a STARTTLS exchange.
    func startTLS() async throws(StreamError)
    func close()
}

public protocol ByteStreamConnector: Sendable {
    /// Opens a connection. For `.tls` the stream is already encrypted when returned;
    /// for `.startTLS` the caller negotiates and then calls `startTLS()`.
    func connect(to endpoint: ServerEndpoint) async throws(StreamError) -> any ByteStream
}

/// `ByteStreamConnector` over `URLSessionStreamTask`, which is the system API that can
/// upgrade a plain connection to TLS part-way through.
public struct URLSessionStreamConnector: ByteStreamConnector {
    public init() {}

    public func connect(to endpoint: ServerEndpoint) async throws(StreamError) -> any ByteStream {
        let session = URLSession(configuration: .ephemeral, delegate: TrustPolicy(), delegateQueue: nil)
        let task = session.streamTask(withHostName: endpoint.host, port: endpoint.port)
        task.resume()
        if endpoint.security == .tls {
            task.startSecureConnection()
        }
        return Stream(session: session, task: task)
    }

    private struct Stream: ByteStream {
        let session: URLSession
        let task: URLSessionStreamTask

        func read(timeout: TimeInterval) async throws(StreamError) -> Data {
            do {
                let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: timeout)
                if let data, !data.isEmpty { return data }
                throw StreamError(atEOF ? "The server closed the connection." : "The server sent nothing.")
            } catch let error as StreamError {
                throw error
            } catch {
                throw StreamError(error.localizedDescription)
            }
        }

        func write(_ data: Data) async throws(StreamError) {
            do {
                try await task.write(data, timeout: 30)
            } catch {
                throw StreamError(error.localizedDescription)
            }
        }

        func startTLS() async throws(StreamError) {
            task.startSecureConnection()
        }

        func close() {
            task.cancel()
            session.invalidateAndCancel()
        }
    }
}

/// Certificate checking for mail connections.
///
/// A server on this machine (Proton Mail Bridge and the like) presents a certificate
/// it generated itself, which no authority vouches for. Traffic to it never leaves
/// the Mac, so that certificate is accepted. Every other host gets the system's
/// normal validation.
private final class TrustPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.decide(challenge)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.decide(challenge)
    }

    private static func decide(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard
            space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = space.serverTrust,
            ServerEndpoint.isLoopback(space.host)
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

extension ServerEndpoint {
    /// Whether `host` names this machine itself.
    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}

/// Reads lines and counted byte runs from a `ByteStream`, which delivers bytes in
/// arbitrary chunks.
actor BufferedReader {
    private let stream: any ByteStream
    private var buffer = Data()

    init(stream: any ByteStream) {
        self.stream = stream
    }

    /// The next line, without its CRLF.
    func line(timeout: TimeInterval) async throws(StreamError) -> Data {
        while true {
            if let lineFeed = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<lineFeed]
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                let result = Data(line)
                buffer = Data(buffer[buffer.index(after: lineFeed)...])
                return result
            }
            buffer.append(try await stream.read(timeout: timeout))
        }
    }

    /// Exactly `count` bytes.
    func bytes(_ count: Int, timeout: TimeInterval) async throws(StreamError) -> Data {
        while buffer.count < count {
            buffer.append(try await stream.read(timeout: timeout))
        }
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }

    /// Forgets buffered plaintext. Called after STARTTLS, when nothing read before
    /// the handshake may be trusted.
    func discardBuffer() {
        buffer.removeAll()
    }
}
