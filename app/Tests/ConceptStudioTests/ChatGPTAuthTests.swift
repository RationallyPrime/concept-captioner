import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@MainActor
private final class ChatGPTFixture {
    let store: MemoryChatGPTCredentials
    let browser = ChatGPTAuthBrowserFixture()
    let transport: ChatGPTAuthTransportFixture
    let manager: ChatGPTAccounts
    let suite = "ChatGPTAuthTests." + UUID().uuidString
    let preferences: UserDefaults

    init(saved: ChatGPTSavedState? = nil) throws {
        store = try MemoryChatGPTCredentials(saved)
        preferences = try #require(UserDefaults(suiteName: suite))
        transport = try ChatGPTAuthTransportFixture(browser: browser, signing: ChatGPTTestSigningKey())
        let store = store, browser = browser
        manager = ChatGPTAccounts(
            preferences: preferences, transport: transport, loadCredentials: { store.load() },
            saveCredentials: { store.save($0) }, callbackFactory: { ChatGPTCallbackFixture(browser: browser) },
            openBrowser: { try await browser.open($0) }, now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: suite)
    }

    static func saved(expired: Bool = false, scopes: Set<String> = [ChatGPTAuth.directScope]) -> ChatGPTSavedState {
        ChatGPTSavedState(hostID: "urn:uuid:fixture-host", registrations: ["oaiapp_savedA", "oaiapp_savedB"].map { id in
            ChatGPTRegistration(clientID: id, subject: "user", email: "same@example.invalid", tokens: ChatGPTTokens(
                accessToken: "old-access-\(id)", refreshToken: "old-refresh-\(id)", idToken: "retained-id-hint-\(id)",
                scopes: scopes, expiresAt: Date(timeIntervalSince1970: expired ? 1_799_999_999 : 1_800_003_600),
                nonce: "old-nonce"
            ))
        })
    }
}

@Suite("ChatGPT account lifecycle")
@MainActor
struct ChatGPTAuthTests {
    @Test func initializationIsIdleAndLoadingKeepsDistinctRegistrationsAndSelection() async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved())
        defer { f.cleanup() }
        #expect(f.store.counts().reads == 0)
        #expect(await f.transport.requests.isEmpty)
        await f.manager.load()
        #expect(f.manager.accounts.count == 2)
        #expect(Set(f.manager.accounts.map(\.label)).count == 2)
        f.manager.selectedAccountID = "oaiapp_savedB"
        await f.manager.load()
        #expect(f.manager.selectedAccountID == "oaiapp_savedB")
        #expect(f.preferences.string(forKey: "chatgpt.selectedAccount") == "oaiapp_savedB")
        #expect(await f.transport.requests.isEmpty)
    }

    @Test func dynamicSignInReauthorizesWithIssuedClientHostHintsAndFreshPkce() async throws {
        let f = try ChatGPTFixture()
        defer { f.cleanup() }
        #expect(await f.manager.signIn())
        let id = try #require(f.manager.selectedAccountID)
        let host = try f.store.saved().hostID
        #expect(f.manager.selectedAccount?.hasPlanPermission == true)
        #expect(await f.manager.signIn(accountID: id))
        let queries = await f.browser.queries
        #expect(queries.count == 2)
        #expect(queries[0]["client_id"] == "dynamic_agent_client")
        #expect(queries[0]["agent_name_hint"] == "ConceptStudio")
        #expect(queries[0]["prompt"] == nil)
        #expect(queries[1]["client_id"] == id)
        #expect(queries[1]["agent_name_hint"] == nil)
        #expect(queries[1]["id_token_hint"] != nil)
        #expect(queries[1]["ext_agent_host_id"] == host)
        #expect(queries[0]["ext_agent_host_id"] == host)
        #expect(queries[0]["state"] != queries[1]["state"])
        #expect(queries[0]["nonce"] != queries[1]["nonce"])
        #expect(queries[0]["code_challenge"] != queries[1]["code_challenge"])
        #expect(try f.store.saved().registrations.count == 1)
    }

    @Test func callbackStateMismatchNeverExchangesCodeOrActivatesAccount() async throws {
        let f = try ChatGPTFixture()
        defer { f.cleanup() }
        await f.browser.configure(state: "wrong-state")
        #expect(await !(f.manager.signIn()))
        #expect(f.manager.selectedAccountID == nil)
        #expect(try f.store.saved().registrations.isEmpty)
        #expect(await f.transport.requests.allSatisfy { !$0.url!.path().hasSuffix("oauth/token") })
    }

    @Test func expiredCodeRetriesWithIssuedRegistrationInsteadOfCreatingAnotherClient() async throws {
        let f = try ChatGPTFixture()
        defer { f.cleanup() }
        await f.transport.configure(codeExchangeError: "invalid_grant")
        #expect(await !(f.manager.signIn()))
        #expect(try f.store.saved().registrations.isEmpty)
        await f.transport.configure()
        #expect(await f.manager.signIn())
        let queries = await f.browser.queries
        #expect(queries[0]["client_id"] == "dynamic_agent_client")
        #expect(queries[1]["client_id"] == "oaiapp_fixture1")
        #expect(queries[1]["agent_name_hint"] == nil)
        #expect(try f.store.saved().registrations.count == 1)
    }

    @Test(arguments: ["client", "subject"])
    func returningCallbackCannotReplaceAccountIdentity(field: String) async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved())
        defer { f.cleanup() }
        await f.manager.load()
        let previous = try f.store.saved()
        await f.browser.configure(
            subject: field == "subject" ? "someone-else" : "user",
            client: field == "client" ? "oaiapp_different" : nil
        )
        #expect(await !(f.manager.signIn(accountID: "oaiapp_savedA")))
        #expect(f.manager.selectedAccountID == "oaiapp_savedA")
        #expect(try f.store.saved().registrations[0].tokens?.accessToken == previous.registrations[0].tokens?
            .accessToken)
    }

    @Test func signedIdentityWithoutPlanPermissionCannotInferAndExplicitEnableUsesConsent() async throws {
        let f = try ChatGPTFixture()
        defer { f.cleanup() }
        await f.transport.configure(scopes: "openid profile email offline_access")
        #expect(await f.manager.signIn())
        let id = try #require(f.manager.selectedAccountID)
        #expect(f.manager.selectedAccount?.isSignedIn == true)
        #expect(f.manager.selectedAccount?.hasPlanPermission == false)
        await #expect(throws: ChatGPTAuthError.self) { try await f.manager.tokenProvider(accountID: id)() }
        await f.transport.configure(scopes: ChatGPTAuth.scopes)
        #expect(await f.manager.signIn(accountID: id, enablePlanUsage: true))
        #expect(f.manager.selectedAccount?.hasPlanPermission == true)
        #expect(await f.browser.queries.last?["prompt"] == "consent")
        #expect(await f.browser.queries.last?["client_id"] == id)
    }

    @Test func modelsUseSelectedBearerFilterVisibilityAndClearStaleCatalog() async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved())
        defer { f.cleanup() }
        await f.manager.load()
        await f.manager.refreshModels()
        #expect(f.manager.availableModels.map(\.slug) == ["gpt-fixture", "gpt-last"])
        let modelRequest = try #require(await f.transport.requests.last)
        #expect(modelRequest.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(modelRequest.value(forHTTPHeaderField: "Authorization") == "Bearer old-access-oaiapp_savedA")
        f.manager.selectedAccountID = "oaiapp_savedB"
        #expect(f.manager.availableModels.isEmpty)
        await f.transport.configure(modelStatus: 503)
        await f.manager.refreshModels()
        #expect(f.manager.availableModels.isEmpty)
        #expect(f.manager.errorMessage != nil)
    }

    @Test func concurrentRequestsRefreshOnceAndPersistBothRotatedTokens() async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved(expired: true))
        defer { f.cleanup() }
        await f.transport.configure(holdRefresh: true)
        let token = f.manager.tokenProvider(accountID: "oaiapp_savedA")
        let first = Task { try await token() }
        let second = Task { try await token() }
        for _ in 0 ..< 100 {
            if await f.transport.refreshCount > 0 { break }; await Task.yield()
        }
        #expect(await f.transport.refreshCount == 1)
        await f.transport.releaseRefresh()
        #expect(try await first.value == "rotated-access")
        #expect(try await second.value == "rotated-access")
        #expect(await f.transport.refreshCount == 1)
        let saved = try f.store.saved()
        #expect(saved.registrations[0].tokens?.refreshToken == "rotated-refresh")
        #expect(saved.registrations[1].tokens?.refreshToken == "old-refresh-oaiapp_savedB")
        let request = try #require(await f.transport.requests.last { $0.httpBody != nil })
        let fields = ChatGPTAuthTransportFixture.fields(request)
        #expect(fields["client_id"] == "oaiapp_savedA")
        #expect(fields["resource"] == "https://api.openai.com/v1")
        #expect(fields["scope"] == nil)
    }

    @Test(arguments: [true, false], ["token", "models"])
    func terminalRefreshClearsStoredAndVisibleTokensButTemporaryFailurePreservesThem(
        terminal: Bool, operation: String
    ) async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved(expired: true))
        defer { f.cleanup() }
        await f.manager.load()
        await f.transport.configure(
            refreshError: terminal ? "refresh_token_reused" : "temporary",
            refreshStatus: terminal ? 400 : 503
        )
        if operation == "token" {
            do {
                _ = try await f.manager.tokenProvider(accountID: "oaiapp_savedA")()
                Issue.record("Expected refresh failure")
            } catch {}
        } else {
            await f.manager.refreshModels()
            #expect(f.manager.errorMessage != nil)
        }
        let saved = try f.store.saved()
        #expect(saved.hostID == "urn:uuid:fixture-host")
        #expect(saved.registrations.count == 2)
        #expect((saved.registrations[0].tokens == nil) == terminal)
        #expect(saved.registrations[1].tokens != nil)
        #expect(f.manager.selectedAccount?.isSignedIn == !terminal)
        #expect(f.manager.selectedAccount?.hasPlanPermission == !terminal)
        #expect(f.manager.accounts[1].isSignedIn)
        #expect(f.manager.availableModels.isEmpty)
    }

    @Test func signOutRevokesSelectedSessionAndPreservesRegistrationOtherAccountAndHost() async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved())
        defer { f.cleanup() }
        await f.manager.load()
        await f.transport.configure(revocationStatus: 503)
        await f.manager.signOut()
        let saved = try f.store.saved()
        #expect(saved.registrations[0].tokens == nil)
        #expect(saved.registrations[1].tokens != nil)
        #expect(saved.hostID == "urn:uuid:fixture-host")
        #expect(f.manager.message.contains("not confirmed"))
        #expect(await f.transport.revokeCount == 2)
        let request = try #require(await f.transport.requests.last)
        #expect(ChatGPTAuthTransportFixture.fields(request) == [
            "client_id": "oaiapp_savedA", "token_type_hint": "refresh_token", "token": "old-refresh-oaiapp_savedA",
        ])
        #expect(await f.manager.signIn(accountID: "oaiapp_savedA"))
        #expect(await f.browser.queries.last?["client_id"] == "oaiapp_savedA")
        #expect(await f.browser.queries.last?["id_token_hint"] == nil)
    }

    @Test func cancelledAttemptReturnsFalseWithOlderAccountStillSignedInAndDrainsCallback() async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved())
        defer { f.cleanup() }
        await f.manager.load()
        await f.browser.configure(delivered: false)
        let work = Task { await f.manager.signIn() }
        for _ in 0 ..< 100 {
            if await f.browser.count > 0 { break }; await Task.yield()
        }
        let callback = try #require(await f.browser.active)
        await f.manager.cancelAndWait()
        #expect(await !(work.value))
        #expect(await callback.cancelled)
        #expect(!f.manager.isBusy)
        #expect(f.manager.selectedAccountID == "oaiapp_savedA")
        #expect(f.manager.selectedAccount?.isSignedIn == true)
        #expect(try f.store.saved().registrations.count == 2)
    }

    @Test func enteringDemoSettlesPendingAuthBeforeDemoStateAndStopsAllCredentialOrNetworkWork() async throws {
        let f = try ChatGPTFixture()
        defer { f.cleanup() }
        let studio = makeTestSession(preferences: f.preferences, chatGPT: f.manager)
        await f.browser.configure(delivered: false)
        let login = Task { await f.manager.signIn() }
        for _ in 0 ..< 100 {
            if await f.browser.count > 0 { break }; await Task.yield()
        }
        let callback = try #require(await f.browser.active)
        studio.useDemo()
        await studio.task?.value
        defer { if let directory = studio.project?.directory { try? FileManager.default.removeItem(at: directory) } }
        #expect(studio.demoMode)
        #expect(await !(login.value))
        #expect(await callback.cancelled)
        #expect(!f.manager.isBusy)
        let counts = f.store.counts()
        let requests = await f.transport.requests.count
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(f.store.counts().reads == counts.reads)
        #expect(f.store.counts().writes == counts.writes)
        #expect(await f.transport.requests.count == requests)
        #expect(try f.store.saved().registrations.isEmpty)
    }

    @Test(arguments: ["busy", "generation"])
    func successfulAuthCannotStartModelDiscoveryAfterStudioContextChanges(change: String) async throws {
        let f = try ChatGPTFixture()
        defer { f.cleanup() }
        let studio = StudioSession(preferences: f.preferences, chatGPT: f.manager)
        await f.transport.configure(holdJWKS: true)
        let connection = Task { await studio.connectChatGPT() }
        for _ in 0 ..< 100 {
            if await f.transport.jwksCount > 0 { break }; await Task.yield()
        }
        #expect(await f.transport.jwksCount == 1)
        if change == "busy" {
            studio.busy = true
        } else {
            studio.chatGPTWorkGeneration += 1
        }
        await f.transport.releaseJWKS()
        await connection.value
        #expect(f.manager.selectedAccount?.isSignedIn == true)
        #expect(f.manager.selectedAccount?.hasPlanPermission == true)
        #expect(await f.transport.requests.allSatisfy { $0.url?.path() != "/v1/models" })
        #expect(!studio.openAIUsesChatGPT)
        #expect(!studio.showChatGPTPlanNotice)
        studio.busy = false
    }

    @Test func signOutWaitsForLateRefreshAndCannotRestoreRotatedCredentials() async throws {
        let f = try ChatGPTFixture(saved: ChatGPTFixture.saved(expired: true))
        defer { f.cleanup() }
        await f.manager.load()
        await f.transport.configure(holdRefresh: true)
        let provider = f.manager.tokenProvider(accountID: "oaiapp_savedA")
        let request = Task { try await provider() }
        for _ in 0 ..< 100 {
            if await f.transport.refreshCount > 0 { break }; await Task.yield()
        }
        let stop = Task { await f.manager.signOut() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        // This fake deliberately completes the server response despite cancellation.
        await f.transport.releaseRefresh()
        await stop.value
        if case .success = await request.result { Issue.record("A signed-out session returned a token") }
        let saved = try f.store.saved()
        #expect(saved.registrations[0].tokens == nil)
        #expect(saved.registrations[1].tokens != nil)
        #expect(!f.manager.isBusy)
        let writes = f.store.counts().writes
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(f.store.counts().writes == writes)
    }
}

@Suite("ChatGPT identity and callback validation")
struct ChatGPTIdentityTests {
    @Test(arguments: ["valid", "issuer", "audience", "nonce", "expired", "subject", "signature"])
    func rsaSignatureAndIdentityClaimsAreRequired(caseName: String) throws {
        let key = try ChatGPTTestSigningKey()
        var changes: [String: Any] = [:]
        switch caseName {
        case "issuer": changes["iss"] = "https://wrong.invalid"
        case "audience": changes["aud"] = "another-client"
        case "nonce": changes["nonce"] = "another-attempt"
        case "expired": changes["exp"] = 1_799_999_999
        case "subject": changes["sub"] = ""
        default: break
        }
        var token = try key.token(clientID: "oaiapp_test", nonce: "expected", overrides: changes)
        if caseName == "signature" { token = String(token.dropLast(10)) + "AAAAAAAAAA" }
        let validate = { try ChatGPTIdentity.validate(
            token,
            jwks: key.jwks,
            clientID: "oaiapp_test",
            nonce: "expected",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ) }
        if caseName == "valid" {
            #expect(try validate().subject == "user")
        } else {
            #expect(throws: (any Error).self) { try validate() }
        }
    }

    @Test func loopbackParserAcceptsOnlyExactGetCallbackAndRejectsUnrelatedOrAbsoluteTargets() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1:54321/auth/callback"))
        #expect(ChatGPTLoopbackCallback.callbackTarget(
            "GET /auth/callback?code=x&state=y HTTP/1.1",
            redirectURI: redirect
        )?
            .absoluteString == "http://127.0.0.1:54321/auth/callback?code=x&state=y")
        for target in [
            "GET /callback HTTP/1.1",
            "POST /auth/callback HTTP/1.1",
            "GET //elsewhere/auth/callback HTTP/1.1",
            "GET https://elsewhere.invalid/auth/callback HTTP/1.1",
            "GET /favicon.ico HTTP/1.1",
        ] {
            #expect(ChatGPTLoopbackCallback.callbackTarget(target, redirectURI: redirect) == nil)
        }
    }
}
