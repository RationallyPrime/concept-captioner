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

/// URLSession-backed. Follows redirects; drops Authorization when a redirect leaves the host.
///
/// Errors from URLSession (`URLError`) propagate unchanged; each caller wraps them in its own
/// error type (`ModelError.transport`, `HubError.transport`). A non-HTTP response is reported as
/// `URLError(.badServerResponse)`.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession
    public let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 600) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        var request = request
        request.timeoutInterval = timeout
        let delegate = RedirectDelegate(originalHost: request.url?.host())
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
}

/// Per-task delegate: lets URLSession follow the redirect but strips `Authorization` once the
/// chain leaves the original host (Hub `resolve` URLs redirect to a CDN that rejects a second
/// auth mechanism, and a bearer token must never leak to a third host anyway).
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let originalHost: String?

    init(originalHost: String?) {
        self.originalHost = originalHost?.lowercased()
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var next = request
        if next.url?.host()?.lowercased() != originalHost {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
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
