// A scripted HTTPTransport that records URLRequests. Used by the model client and Hub tests.

import ConceptCore
import Foundation
import Synchronization

public actor StubTransport: HTTPTransport {
    public private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest) async throws -> HTTPResponse

    public init(_ handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try await handler(request)
    }

    /// A JSON response built from Foundation objects (order does not matter in tests).
    public static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) throws -> HTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: object)
        var merged = headers
        merged["content-type"] = "application/json"
        return HTTPResponse(status: status, headers: merged, body: data)
    }

    /// Parse a request's JSON body.
    public static func body(of request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ConfigurationError("request body is not a JSON object")
        }
        return object
    }
}

// MARK: - URLSession stub

/// A `URLProtocol` for exercising `URLSessionTransport` without a network. Serves `/cross`
/// (302 to another host), `/same` (302 to the same origin), `/downgrade` (302 to http on the same
/// host), `/port` (302 to another port on the same host) and anything else as 200 `ok`, and
/// records every request the loading system hands it, redirected ones included.
public final class RedirectStubProtocol: URLProtocol {
    public static let seen = Mutex<[URLRequest]>([])

    /// A session whose loads all go through this stub; the recorder starts empty.
    public static func session() -> URLSession {
        seen.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override public static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override public static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func stopLoading() {}

    override public func startLoading() {
        Self.seen.withLock { $0.append(request) }
        guard let url = request.url, let client else { return }
        let target: URL? = switch url.path() {
        case "/cross": URL(string: "https://cdn.test/final")
        case "/same": URL(string: "https://origin.test/final")
        case "/downgrade": URL(string: "http://origin.test/final")
        case "/port": URL(string: "https://origin.test:8443/final")
        default: nil
        }
        if let target {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
            )!
            // CFNetwork carries the original headers onto the redirected request; so does this stub.
            var redirected = URLRequest(url: target)
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
            // Once the task delegate accepts, the loading system stops this load and starts the
            // redirected one; sending anything more here races that hand-off.
            client.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data("ok".utf8))
        client.urlProtocolDidFinishLoading(self)
    }
}
