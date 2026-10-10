import ConceptCore
@testable import ConceptStudio
import CryptoKit
import Foundation
import Security
import Testing

final class MemoryChatGPTCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var reads = 0
    private var writes = 0
    init(_ state: ChatGPTSavedState? = nil) throws {
        value = try state.map { try JSONEncoder().encode($0) }
    }

    func load() -> Data? {
        lock.withLock { reads += 1; return value }
    }

    func save(_ data: Data) {
        lock.withLock { value = data; writes += 1 }
    }

    func counts() -> (reads: Int, writes: Int) {
        lock.withLock { (reads, writes) }
    }

    func saved() throws -> ChatGPTSavedState {
        try lock.withLock { try JSONDecoder().decode(ChatGPTSavedState.self, from: #require(value)) }
    }
}

final class ChatGPTTestSigningKey: @unchecked Sendable {
    let key: SecKey
    let jwks: Data
    init() throws {
        key = try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 1
        _ = Self.length(der, offset: &offset)
        let modulus = Self.integer(der, offset: &offset)
        let exponent = Self.integer(der, offset: &offset)
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "fixture", "kty": "RSA", "alg": "RS256", "use": "sig",
            "n": ChatGPTAuth.encode(modulus), "e": ChatGPTAuth.encode(exponent),
        ]]])
    }

    func token(
        clientID: String,
        nonce: String,
        subject: String = "user",
        overrides: [String: Any] = [:]
    ) throws -> String {
        var claims: [String: Any] = [
            "iss": ChatGPTAuth.issuer, "aud": clientID, "sub": subject, "nonce": nonce,
            "iat": 1_800_000_000, "exp": 1_800_003_600, "email": "same@example.invalid",
        ]
        claims.merge(overrides) { _, new in new }
        let header = try ChatGPTAuth.encode(JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture"]))
        let payload = try ChatGPTAuth.encode(JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let message = Data("\(header).\(payload)".utf8)
        let signature = try #require(SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            nil
        ))
        return "\(header).\(payload).\(ChatGPTAuth.encode(signature as Data))"
    }

    private static func length(_ data: Data, offset: inout Int) -> Int {
        let first = Int(data[offset]); offset += 1
        if first < 128 { return first }
        var value = 0
        for _ in 0 ..< (first & 0x7F) {
            value = value * 256 + Int(data[offset]); offset += 1
        }
        return value
    }

    private static func integer(_ data: Data, offset: inout Int) -> Data {
        precondition(data[offset] == 2); offset += 1
        let size = length(data, offset: &offset)
        var result = Data(data[offset ..< offset + size]); offset += size
        while result.first == 0 {
            result.removeFirst()
        }
        return result
    }
}

actor ChatGPTAuthBrowserFixture {
    weak var active: ChatGPTCallbackFixture?
    var delivered = true
    var subject = "user"
    var stateOverride: String?
    var clientOverride: String?
    var count = 0
    var queries: [[String: String]] = []
    var current: [String: String] = [:]

    func listen(_ callback: ChatGPTCallbackFixture) -> URL {
        active = callback
        return URL(string: "http://127.0.0.1:\(1455 + count)/auth/callback")!
    }

    func configure(delivered: Bool = true, subject: String = "user", state: String? = nil, client: String? = nil) {
        self.delivered = delivered; self.subject = subject
        stateOverride = state; clientOverride = client
    }

    func open(_ url: URL) async throws {
        let listener = try #require(active)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        current = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        queries.append(current)
        count += 1
        guard delivered else { return }
        let issued = current["client_id"] == ChatGPTAuth
            .dynamicClient ? "oaiapp_fixture\(count)" : current["client_id"]!
        var callback = URLComponents(string: current["redirect_uri"]!)!
        callback.queryItems = [
            URLQueryItem(name: "state", value: stateOverride ?? current["state"]),
            URLQueryItem(name: "code", value: "synthetic-code"),
            URLQueryItem(name: "client_id", value: clientOverride ?? issued),
        ]
        current["issued"] = issued
        await listener.respond(callback.url!)
    }
}

actor ChatGPTCallbackFixture: ChatGPTCallback {
    let browser: ChatGPTAuthBrowserFixture
    var response: Result<URL, any Error>?
    var continuation: CheckedContinuation<URL, any Error>?
    private(set) var cancelled = false
    init(browser: ChatGPTAuthBrowserFixture) {
        self.browser = browser
    }

    func start() async -> URL {
        await browser.listen(self)
    }

    func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            if let response { return try response.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { await self.cancel() } }
    }

    func respond(_ url: URL) {
        response = .success(url); continuation?.resume(returning: url); continuation = nil
    }

    func cancel() {
        cancelled = true
        if response == nil { response = .failure(CancellationError()) }
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }
}

actor ChatGPTAuthTransportFixture: HTTPTransport {
    let browser: ChatGPTAuthBrowserFixture
    let signing: ChatGPTTestSigningKey
    var scopes = ChatGPTAuth.scopes
    var refreshError: String?
    var refreshStatus = 200
    var holdRefresh = false
    var refreshContinuation: CheckedContinuation<Void, Never>?
    var revocationStatus = 200
    var modelStatus = 200
    var holdJWKS = false
    var jwksContinuation: CheckedContinuation<Void, Never>?
    private(set) var jwksCount = 0
    var codeExchangeError: String?
    private(set) var requests: [URLRequest] = []
    private(set) var refreshCount = 0
    private(set) var revokeCount = 0
    init(browser: ChatGPTAuthBrowserFixture, signing: ChatGPTTestSigningKey) {
        self.browser = browser; self.signing = signing
    }

    func configure(
        scopes: String? = nil,
        refreshError: String? = nil,
        refreshStatus: Int = 200,
        holdRefresh: Bool = false,
        revocationStatus: Int = 200,
        modelStatus: Int = 200,
        holdJWKS: Bool = false,
        codeExchangeError: String? = nil
    ) {
        if let scopes { self.scopes = scopes }
        self.refreshError = refreshError; self.refreshStatus = refreshStatus
        self.holdRefresh = holdRefresh; self.revocationStatus = revocationStatus
        self.modelStatus = modelStatus
        self.holdJWKS = holdJWKS; self.codeExchangeError = codeExchangeError
    }

    func releaseRefresh() {
        refreshContinuation?.resume(); refreshContinuation = nil
    }

    func releaseJWKS() {
        jwksContinuation?.resume(); jwksContinuation = nil
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let path = request.url!.path()
        if path.hasSuffix("openid-configuration") {
            return try json([
                "issuer": ChatGPTAuth.issuer,
                "authorization_endpoint": ChatGPTAuth.issuer + "/api/accounts/authorize",
                "token_endpoint": ChatGPTAuth.issuer + "/api/accounts/oauth/token",
                "jwks_uri": ChatGPTAuth.issuer + "/.well-known/jwks.json",
                "revocation_endpoint": ChatGPTAuth.issuer + "/oauth/revoke",
            ])
        }
        if path.hasSuffix("jwks.json") {
            jwksCount += 1
            if holdJWKS { await withCheckedContinuation { jwksContinuation = $0 } }
            return HTTPResponse(status: 200, body: signing.jwks)
        }
        if path.hasSuffix("revoke") { revokeCount += 1; return HTTPResponse(status: revocationStatus) }
        if path == "/v1/models" {
            return try json(["models": [
                ["slug": "hidden", "display_name": "Hidden model", "visibility": "hidden"],
                ["slug": "gpt-fixture", "display_name": "Fixture model", "visibility": "list"],
                ["slug": "unlisted", "display_name": "Unlisted model", "visibility": "unlisted"],
                ["slug": "gpt-last", "display_name": "Last model", "visibility": "list"],
            ]], status: modelStatus)
        }
        let fields = Self.fields(request)
        if fields["grant_type"] == "refresh_token" {
            refreshCount += 1
            if holdRefresh { await withCheckedContinuation { refreshContinuation = $0 } }
            if refreshStatus != 200 { return try json(["error": refreshError ?? "temporary"], status: refreshStatus) }
            return try json([
                "access_token": "rotated-access", "refresh_token": "rotated-refresh", "token_type": "Bearer",
                "scope": scopes, "expires_in": 3600,
            ])
        }
        if let codeExchangeError { return try json(["error": codeExchangeError], status: 400) }
        let query = await browser.current
        #expect(fields["redirect_uri"] == query["redirect_uri"])
        #expect(fields["client_id"] == query["issued"])
        #expect(fields["resource"] == ChatGPTAuth.resource)
        #expect(fields["client_secret"] == nil)
        let challenge = ChatGPTAuth.encode(Data(SHA256.hash(data: Data(fields["code_verifier"]!.utf8))))
        #expect(challenge == query["code_challenge"])
        return try await json([
            "access_token": "access-\(query["issued"]!)", "refresh_token": "refresh-\(query["issued"]!)",
            "id_token": signing.token(
                clientID: query["issued"]!,
                nonce: query["nonce"]!,
                subject: browser.subject
            ),
            "token_type": "Bearer", "scope": scopes, "expires_in": 3600,
        ])
    }

    static func fields(_ request: URLRequest) -> [String: String] {
        let query = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let parts = URLComponents(string: "https://fixture.invalid/?" + query)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: parts.map { ($0.name, $0.value ?? "") })
    }

    private func json(_ object: [String: Any], status: Int = 200) throws -> HTTPResponse {
        try HTTPResponse(status: status, body: JSONSerialization.data(withJSONObject: object))
    }
}
