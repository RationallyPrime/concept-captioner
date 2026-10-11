import ConceptCore
import CryptoKit
import Foundation

struct OpenRouterConnectionError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

/// OpenRouter's PKCE flow mints an API key, not an identity or subscription token.
/// https://openrouter.ai/docs/guides/overview/auth/oauth
struct OpenRouterAuthorization {
    let redirectURI: URL
    let verifier: String
    let state: String

    init(redirectURI: URL) throws {
        self.redirectURI = redirectURI
        do {
            verifier = try ChatGPTAuth.randomValue(bytes: 64)
            state = try ChatGPTAuth.randomValue()
        } catch {
            throw OpenRouterConnectionError(
                "Your Mac could not prepare OpenRouter authorization. Try connecting again."
            )
        }
    }

    var browserURL: URL {
        var parts = URLComponents(string: "https://openrouter.ai/auth")!
        parts.queryItems = [
            URLQueryItem(name: "callback_url", value: redirectURI.absoluteString),
            URLQueryItem(
                name: "code_challenge",
                value: ChatGPTAuth.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
            ),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "key_label", value: "ConceptStudio"),
        ]
        return parts.url!
    }

    func exchangeRequest(callback: URL) throws -> URLRequest {
        guard callback.scheme == redirectURI.scheme, callback.host() == redirectURI.host(),
              callback.port == redirectURI.port, callback.path() == redirectURI.path(), callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw OpenRouterConnectionError(
                "OpenRouter's callback did not match this connection attempt. Connect again."
            )
        }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else {
                throw OpenRouterConnectionError(
                    "OpenRouter returned an ambiguous authorization response. Connect again."
                )
            }
            values[item.name] = value
        }
        // OpenRouter does not return state when access is denied. That response never exchanges or saves a key.
        if values["error"] == "access_denied" {
            throw OpenRouterConnectionError("OpenRouter authorization was declined. Your saved key was not changed.")
        }
        guard values["state"] == state else {
            throw OpenRouterConnectionError("OpenRouter's authorization state did not match. Connect again.")
        }
        guard values["error"] == nil, let code = values["code"], !code.isEmpty else {
            throw OpenRouterConnectionError("OpenRouter did not return an authorization code. Connect again.")
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256",
        ])
        return request
    }

    static func keyHash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A callback verifier must never be forwarded by an HTTP redirect. This transport is only
/// for the two fixed OpenRouter authorization/metadata endpoints; inference keeps the Core transport.
struct OpenRouterAuthorizationTransport: HTTPTransport {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = request
        request.timeoutInterval = 30
        let (body, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponse(status: response.statusCode, body: body)
    }
}
