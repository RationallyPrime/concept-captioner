// The HTTP seam: clients and the Hub client send URLRequests through an injected transport so
// tests never touch the network.

import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// A response whose body is read as it arrives. Status and headers are complete; `body` yields
/// raw byte chunks of any size (a chunk boundary means nothing). Read the body once, either as
/// `events` or with `collect(limit:)`.
public struct HTTPStreamResponse: Sendable {
    public let status: Int
    /// Header names lowercased, as for HTTPResponse.
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, any Error>
    private let cancellation: @Sendable () -> Void

    public init(
        status: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, any Error>,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        cancellation = cancel
    }

    /// The body parsed as server-sent events, each delivered as soon as its blank line arrives.
    public var events: ServerSentEventStream {
        ServerSentEventStream(body: body)
    }

    /// At most `limit` bytes of the body (for error reports), stopping early once reached.
    public func collect(limit: Int) async throws -> Data {
        var collected = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            collected.append(chunk.prefix(limit - collected.count))
            if collected.count >= limit { break }
        }
        return collected
    }

    /// Stop reading and release the connection. Safe to call more than once.
    public func cancel() {
        cancellation()
    }
}

public protocol HTTPStreamingTransport: HTTPTransport {
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// URLSession-backed. Follows redirects; drops every credential header when a redirect leaves
/// the host.
///
/// Errors from URLSession (`URLError`) propagate unchanged; each caller wraps them in its own
/// error type (`ModelError.transport`, `HubError.transport`). A non-HTTP response is reported as
/// `URLError(.badServerResponse)`.
public struct URLSessionTransport: HTTPStreamingTransport {
    public let session: URLSession
    public let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 600) {
        self.session = session
        self.timeout = timeout
    }

    /// Largest chunk the streaming body yields without a line ending in it.
    static let streamChunkLimit = 16384

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        var request = request
        request.timeoutInterval = timeout
        let delegate = RedirectDelegate(original: request.url)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        var request = request
        request.timeoutInterval = timeout
        let delegate = RedirectDelegate(original: request.url)
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }
        // Raw bytes, not `bytes.lines`: AsyncLineSequence drops empty lines, and the blank line is
        // what ends a server-sent event. A chunk is flushed at every line ending so an event is
        // delivered the moment its terminating blank line arrives.
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let reader = Task {
            do {
                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if byte == 0x0A || byte == 0x0D || chunk.count >= Self.streamChunkLimit {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                        chunk = Data()
                    }
                }
                if !chunk.isEmpty { continuation.yield(chunk) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let cancel: @Sendable () -> Void = {
            reader.cancel()
            bytes.task.cancel()
        }
        continuation.onTermination = { _ in cancel() }
        return HTTPStreamResponse(status: http.statusCode, headers: headers, body: body, cancel: cancel)
    }
}

/// Per-task delegate: lets URLSession follow the redirect but strips the credential headers once
/// the chain leaves the original origin, that is scheme, host and port (Hub `resolve` URLs
/// redirect to a CDN that rejects a second auth mechanism, a key must never leak to a third host,
/// and a downgrade to plain http or a move to another port on the same host is a different
/// origin too).
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    /// Every header a client in this package puts a credential in.
    static let credentialHeaders = ["Authorization", "x-api-key", "x-goog-api-key"]

    let original: Origin?

    init(original: URL?) {
        self.original = original.map(Origin.init)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var next = request
        if original == nil || next.url.map(Origin.init) != original {
            for name in Self.credentialHeaders {
                next.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return next
    }
}

// MARK: - Shared provider plumbing

/// What the three provider clients share: POST a JSON body, map failures to `ModelError`, parse
/// the JSON envelope.
enum ProviderHTTP {
    /// Error bodies are truncated to this many bytes in `ModelError.http`.
    static let errorBodyLimit = 4096

    static func post(
        _ body: JSONObject,
        to url: URL,
        headers: [String: String],
        transport: any HTTPTransport
    ) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = JSONValue.object(body).pythonDumpsData()

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as ModelError {
            throw error
        } catch {
            throw ModelError.transport(describe(error))
        }
        guard (200 ..< 300).contains(response.status) else {
            throw ModelError.http(status: response.status, body: truncatedText(response.body))
        }
        do {
            return try JSONValue(parsing: response.body)
        } catch {
            throw ModelError.malformedReply("response is not JSON: \(truncatedText(response.body))")
        }
    }

    /// A 400 that names thinking or reasoning, re-worded to say which model refused which level.
    /// Every other error is returned unchanged.
    static func explainThinkingRejection(
        _ error: ModelError,
        model: String,
        settings: RequestSettings
    ) -> ModelError {
        guard case let .http(status, body) = error, status == 400, settings.thinks,
              body.contains("reasoning") || body.contains("thinking") else { return error }
        return .http(
            status: status,
            body: "model '\(model)' rejected thinking '\(settings.thinkingEffort?.rawValue ?? "medium")'; "
                + "choose a supported thinking level or none. Provider response: \(body)"
        )
    }

    /// UTF-8 text of at most `errorBodyLimit` bytes. Lossy on purpose: the cut may split a
    /// multi-byte character and an error body is still worth showing with a replacement mark.
    static func truncatedText(_ data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data.prefix(errorBodyLimit), as: UTF8.self)
    }

    /// A readable one-line description of any thrown error.
    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.domain == NSCocoaErrorDomain {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }
}
