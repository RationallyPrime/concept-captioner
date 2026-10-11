import ConceptCore
@testable import ConceptStudio
import CryptoKit
import Foundation
import Testing

private final class OpenRouterSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private(set) var readCount = 0
    private(set) var writeCount = 0
    var rejectWrites = false

    init(_ value: String? = nil) {
        self.value = value
    }

    func read(_ account: String) throws -> String? {
        try #require(account == "openrouter")
        return lock.withLock { readCount += 1; return value }
    }

    func save(_ value: String, account: String) throws {
        try #require(account == "openrouter")
        try lock.withLock {
            if rejectWrites { throw StudioError.message("Test Keychain write refused.") }
            writeCount += 1
            self.value = value.isEmpty ? nil : value
        }
    }
}

private actor OpenRouterFixture: ChatGPTCallback, HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var browserURLs: [URL] = []
    private(set) var cancelled = false
    private(set) var exchangeStarted = false
    var exchangeStatus = 200
    var exchangeBody = Data(#"{"key":"synthetic-new-key","user_id":"fixture-user"}"#.utf8)
    var metadataStatus = 200
    var deny = false
    var badState = false
    var holdCallback = false
    var holdExchange = false
    var exchangeTransportError = false
    var exchangeWaiter: CheckedContinuation<Void, Never>?
    var callbackResult: Result<URL, any Error>?
    var callbackWaiter: CheckedContinuation<URL, any Error>?
    let redirect = URL(string: "http://127.0.0.1:14555/auth/callback")!

    func configure(
        status: Int = 200, body: Data? = nil, metadataStatus: Int = 200,
        deny: Bool = false, badState: Bool = false, holdCallback: Bool = false, holdExchange: Bool = false,
        exchangeTransportError: Bool = false
    ) {
        exchangeStatus = status
        if let body { exchangeBody = body }
        self.metadataStatus = metadataStatus
        self.deny = deny; self.badState = badState
        self.holdCallback = holdCallback; self.holdExchange = holdExchange
        self.exchangeTransportError = exchangeTransportError
    }

    func start() -> URL {
        redirect
    }

    func open(_ url: URL) throws {
        browserURLs.append(url)
        guard !holdCallback else { return }
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = deny ? [URLQueryItem(name: "error", value: "access_denied")] : [
            URLQueryItem(name: "state", value: badState ? "incorrect-state" : values["state"]),
            URLQueryItem(name: "code", value: "synthetic-code"),
        ]
        callbackResult = .success(parts.url!)
    }

    func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            if let callbackResult { return try callbackResult.get() }
            return try await withCheckedThrowingContinuation { callbackWaiter = $0 }
        } onCancel: { Task { await self.cancel() } }
    }

    func cancel() {
        cancelled = true
        if callbackResult == nil { callbackResult = .failure(CancellationError()) }
        callbackWaiter?.resume(throwing: CancellationError()); callbackWaiter = nil
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        switch request.url?.path() {
        case "/api/v1/auth/keys":
            exchangeStarted = true
            if holdExchange { await withCheckedContinuation { exchangeWaiter = $0 } }
            if exchangeTransportError { throw URLError(.cancelled) }
            return HTTPResponse(status: exchangeStatus, body: exchangeBody)
        case "/api/v1/key":
            return HTTPResponse(
                status: metadataStatus,
                body: Data(
                    #"""
                    {"data": {
                        "creator_user_id":"fixture-user", "limit":25, "limit_remaining":19.5,
                        "limit_reset":"monthly", "usage":5.5, "usage_daily":0.5,
                        "usage_monthly":5.5, "is_free_tier":false
                    }}
                    """#
                    .utf8
                )
            )
        default:
            return HTTPResponse(
                status: 200,
                body: Data(#"{"model":"fixture","choices":[{"message":{"content":"{}"}}]}"#.utf8)
            )
        }
    }

    func releaseExchange() {
        exchangeWaiter?.resume(); exchangeWaiter = nil
    }
}

@Suite("OpenRouter browser authorization")
@MainActor
struct OpenRouterTests {
    private func connection(_ secrets: OpenRouterSecrets, _ fixture: OpenRouterFixture) -> OpenRouterConnection {
        OpenRouterConnection(
            secrets: secrets, transport: fixture, callbackFactory: { fixture },
            openBrowser: { try await fixture.open($0) }
        )
    }

    @Test func pkceExchangePersistsOnlyNewKeyThenReadsOwnUsage() async throws {
        let secrets = OpenRouterSecrets("synthetic-old-key")
        let fixture = OpenRouterFixture()
        let connection = connection(secrets, fixture)
        #expect(secrets.readCount == 0 && secrets.writeCount == 0)
        #expect(await connection.connect())
        #expect(try secrets.read("openrouter") == "synthetic-new-key")
        #expect(await fixture.cancelled)
        let browser = try #require(await fixture.browserURLs.first)
        #expect(browser.host() == "openrouter.ai" && browser.path() == "/auth")
        let query = try Dictionary(uniqueKeysWithValues: #require(
            URLComponents(url: browser, resolvingAgainstBaseURL: false)?.queryItems
        ).map { ($0.name, $0.value ?? "") })
        #expect(query["callback_url"] == "http://127.0.0.1:14555/auth/callback")
        #expect(query["key_label"] == "ConceptStudio")
        #expect(query["state"]?.isEmpty == false)
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let requestBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
        #expect(body["code"] == "synthetic-code")
        #expect(body["code_challenge_method"] == "S256")
        let verifier = try #require(body["code_verifier"])
        #expect(verifier.count >= 43 && verifier.count <= 128)
        #expect(query["code_challenge"] == ChatGPTAuth.encode(Data(SHA256.hash(data: Data(verifier.utf8)))))
        await connection.refresh()
        let usage = try #require(connection.info)
        #expect(usage.creatorUserID == "fixture-user")
        #expect(usage.usage == 5.5 && usage.limitRemaining == 19.5)
        #expect(await fixture.requests.last?.url?.absoluteString == "https://openrouter.ai/api/v1/key")
        #expect(await fixture.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-new-key")
        #expect(connection.keySettingsURL.path().hasSuffix(OpenRouterAuthorization.keyHash("synthetic-new-key")))
        #expect(!connection.activityURL.absoluteString.contains("synthetic-new-key"))
    }

    @Test(arguments: [true, false])
    func refusedOrMismatchedCallbackNeverExchangesOrChangesExistingKey(denied: Bool) async throws {
        let secrets = OpenRouterSecrets("synthetic-old-key")
        let fixture = OpenRouterFixture()
        await fixture.configure(deny: denied, badState: !denied)
        let connection = connection(secrets, fixture)
        #expect(await connection.connect() == false)
        #expect(await fixture.requests.isEmpty)
        #expect(secrets.writeCount == 0)
        #expect(try secrets.read("openrouter") == "synthetic-old-key")
        #expect(connection.errorMessage?.contains(denied ? "declined" : "state") == true)
        #expect(await fixture.cancelled)
    }

    @Test(arguments: [403, 500, 302])
    func rejectedExchangeKeepsOldKeyAndNeverShowsSecretBody(status: Int) async {
        let secrets = OpenRouterSecrets("synthetic-old-key")
        let fixture = OpenRouterFixture()
        await fixture.configure(status: status, body: Data("DO-NOT-SHOW-SECRET".utf8))
        let connection = connection(secrets, fixture)
        #expect(await connection.connect() == false)
        #expect(secrets.writeCount == 0)
        #expect(connection.errorMessage?.contains("DO-NOT-SHOW") == false)
        #expect(await fixture.cancelled)
    }

    @Test func malformedExchangeAndKeychainWriteFailurePreserveOldKey() async throws {
        let secrets = OpenRouterSecrets("synthetic-old-key")
        let fixture = OpenRouterFixture()
        await fixture.configure(body: Data(#"{"key":""}"#.utf8))
        let connection = connection(secrets, fixture)
        #expect(await connection.connect() == false)
        #expect(secrets.writeCount == 0)
        let other = OpenRouterFixture()
        secrets.rejectWrites = true
        let second = self.connection(secrets, other)
        #expect(await second.connect() == false)
        #expect(try secrets.read("openrouter") == "synthetic-old-key")
        #expect(second.errorMessage == "Test Keychain write refused.")
    }

    @Test func cancelWhileWaitingClosesCallbackAndDrainsBeforeDisconnect() async throws {
        let secrets = OpenRouterSecrets("synthetic-old-key")
        let fixture = OpenRouterFixture()
        await fixture.configure(holdCallback: true)
        let connection = connection(secrets, fixture)
        let pending = Task { await connection.connect() }
        while await fixture.browserURLs.isEmpty {
            await Task.yield()
        }
        await connection.cancelAndWait()
        #expect(await pending.value == false)
        #expect(await fixture.cancelled)
        #expect(!connection.isBusy)
        #expect(secrets.writeCount == 0)
        await connection.disconnect()
        #expect(try secrets.read("openrouter") == nil)
        #expect(await fixture.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancelledLateExchangeCannotOverwriteOldKey(urlSessionCancellation: Bool) async throws {
        let secrets = OpenRouterSecrets("synthetic-old-key")
        let fixture = OpenRouterFixture()
        await fixture.configure(holdExchange: true, exchangeTransportError: urlSessionCancellation)
        let connection = connection(secrets, fixture)
        let pending = Task { await connection.connect() }
        while await !fixture.exchangeStarted {
            await Task.yield()
        }
        connection.cancel()
        await fixture.releaseExchange()
        await connection.cancelAndWait()
        #expect(await pending.value == false)
        #expect(secrets.writeCount == 0)
        #expect(connection.errorMessage == nil)
        #expect(try secrets.read("openrouter") == "synthetic-old-key")
    }

    @Test func localDisconnectKeepsRemoteRevocationLinkButNeverCallsManagementAPI() async throws {
        let secrets = OpenRouterSecrets("synthetic-existing-key")
        let fixture = OpenRouterFixture()
        let connection = connection(secrets, fixture)
        await connection.load()
        let remoteLink = connection.keySettingsURL
        await connection.disconnect()
        #expect(!connection.isConnected && connection.info == nil)
        #expect(try secrets.read("openrouter") == nil)
        #expect(connection.keySettingsURL == remoteLink)
        #expect(await fixture.requests.isEmpty)
    }

    @Test(arguments: [401, 500])
    func usageFailuresDoNotEraseSavedCredentials(status: Int) async throws {
        let secrets = OpenRouterSecrets("synthetic-existing-key")
        let fixture = OpenRouterFixture()
        await fixture.configure(metadataStatus: status)
        let connection = connection(secrets, fixture)
        await connection.refresh()
        #expect(try secrets.read("openrouter") == "synthetic-existing-key")
        #expect(secrets.writeCount == 0)
        #expect(connection.errorMessage != nil)
        #expect(connection.isConnected == (status != 401))
    }

    @Test func callbackRejectsWrongOriginDuplicatesEmptyCodeAndMissingState() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1:14555/auth/callback"))
        let attempt = try OpenRouterAuthorization(redirectURI: redirect)
        for callback in [
            "http://127.0.0.1:14556/auth/callback?code=x&state=\(attempt.state)",
            "http://localhost:14555/auth/callback?code=x&state=\(attempt.state)",
            "http://127.0.0.1:14555/other?code=x&state=\(attempt.state)",
            "http://127.0.0.1:14555/auth/callback?code=x&code=y&state=\(attempt.state)",
            "http://127.0.0.1:14555/auth/callback?code=&state=\(attempt.state)",
            "http://127.0.0.1:14555/auth/callback?code=x",
        ] {
            #expect(throws: OpenRouterConnectionError.self) {
                _ = try attempt.exchangeRequest(callback: #require(URL(string: callback)))
            }
        }
        let parsed = ChatGPTLoopbackCallback.callbackTarget(
            "GET /auth/callback?code=x&state=\(attempt.state) HTTP/1.1\r\nHost: 127.0.0.1\r\n", redirectURI: redirect
        )
        #expect(try attempt.exchangeRequest(callback: #require(parsed)).httpMethod == "POST")
    }

    @Test func demoConnectHasNoBrowserKeychainOrNetworkCalls() async throws {
        let name = "ConceptStudio.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let secrets = OpenRouterSecrets()
        let fixture = OpenRouterFixture()
        let connection = connection(secrets, fixture)
        let session = StudioSession(preferences: preferences, openRouter: connection, secrets: secrets)
        session.demoMode = true
        session.endpointKind = "openrouter"
        await session.connectOpenRouter()
        #expect(secrets.readCount == 0 && secrets.writeCount == 0)
        #expect(await fixture.browserURLs.isEmpty)
        #expect(await fixture.requests.isEmpty)
        #expect(try session.endpoint().client is DemoModelClient)
    }

    @Test func connectedKeyReachesExistingFixedGatewayInferenceWithoutJobSecrets() async throws {
        let name = "ConceptStudio.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let secrets = OpenRouterSecrets()
        let fixture = OpenRouterFixture()
        let connection = connection(secrets, fixture)
        let session = StudioSession(preferences: preferences, openRouter: connection, secrets: secrets)
        session.endpointKind = "openrouter"
        session.modelName = "fixture/model"
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        session.project = project
        await session.connectOpenRouter()
        #expect(session.modelName == "fixture/model")
        #expect(connection.info?.creatorUserID == "fixture-user")
        let endpoint = try session.endpoint(transport: fixture)
        _ = try await endpoint.client.request(
            instructions: "test", messages: [.user("test")],
            output: OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: endpoint.outputMode),
            settings: endpoint.settings
        )
        let request = try #require(await fixture.requests.last)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-new-key")
        let job = try session.jobForCaptioning()
        #expect(job.endpoints?.captioner.kind == "openrouter")
        #expect(job.endpoints?.captioner.baseURL == nil)
        #expect(try !job.dump().contains("synthetic-new-key"))
    }

    @Test func stopEverythingDrainsBrowserApprovalBeforeAnyGatewayContinuation() async throws {
        let name = "ConceptStudio.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let secrets = OpenRouterSecrets("synthetic-old-key")
        let fixture = OpenRouterFixture()
        await fixture.configure(holdCallback: true)
        let connection = connection(secrets, fixture)
        let session = StudioSession(preferences: preferences, openRouter: connection, secrets: secrets)
        session.endpointKind = "google"
        let pending = Task { await session.connectOpenRouter() }
        while await fixture.browserURLs.isEmpty {
            await Task.yield()
        }
        #expect(session.needsCloseConfirmation)
        await session.stopEverything()
        await pending.value
        #expect(!connection.isBusy)
        #expect(await fixture.cancelled)
        #expect(await fixture.requests.isEmpty)
        #expect(secrets.writeCount == 0)
        #expect(session.endpointKind == "google")
    }
}
