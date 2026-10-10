import ConceptCore
import Foundation

struct ChatGPTTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var scopes: Set<String>
    var expiresAt: Date
    var nonce: String
}

struct ChatGPTRegistration: Codable {
    let clientID: String
    let subject: String
    var email: String?
    var tokens: ChatGPTTokens?

    var account: ChatGPTAccount {
        ChatGPTAccount(
            clientID: clientID, email: email,
            label: "\(email ?? "ChatGPT account") · \(clientID.suffix(8))",
            isSignedIn: tokens != nil, hasPlanPermission: tokens?.scopes.contains(ChatGPTAuth.directScope) == true
        )
    }
}

struct ChatGPTSavedState: Codable {
    let hostID: String
    var registrations: [ChatGPTRegistration]
}

private struct ChatGPTDiscovery: Decodable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let jwksURI: URL
    let revocationEndpoint: URL?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case revocationEndpoint = "revocation_endpoint"
    }
}

private struct ChatGPTTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let tokenType: String
    let expiresIn: Double
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }

    func tokens(previousID: String? = nil, nonce: String, now: Date) throws -> ChatGPTTokens {
        guard tokenType.lowercased() == "bearer", !accessToken.isEmpty, !refreshToken.isEmpty, expiresIn > 0,
              let identityToken = idToken ?? previousID, !identityToken.isEmpty else {
            throw ChatGPTAuthError("ChatGPT returned incomplete credentials. Sign in again.")
        }
        return ChatGPTTokens(
            accessToken: accessToken, refreshToken: refreshToken, idToken: identityToken,
            scopes: Set(scope.split(separator: " ").map(String.init)),
            expiresAt: now.addingTimeInterval(expiresIn), nonce: nonce
        )
    }
}

private struct ChatGPTTokenFailure: LocalizedError {
    let code: String?
    let status: Int
    var errorDescription: String? {
        if code == "invalid_grant" { return "ChatGPT authorization expired. Sign in again to continue." }
        if code == "invalid_client" { return "ChatGPT did not accept this registration. Try signing in again." }
        return "ChatGPT could not renew or authorize this session (HTTP \(status)). Try again."
    }
}

/// The app's single writer for protected registrations and rotating token sets.
actor ChatGPTSession {
    private let transport: any HTTPTransport
    private let loadCredentials: @Sendable () throws -> Data?
    private let saveCredentials: @Sendable (Data) throws -> Void
    private let callbackFactory: @Sendable () -> any ChatGPTCallback
    private let openBrowser: @Sendable (URL) async throws -> Void
    private let now: @Sendable () -> Date
    private var state: ChatGPTSavedState?
    private var configuration: ChatGPTDiscovery?
    private var refreshing: [String: Task<String, any Error>] = [:]
    private var versions: [String: Int] = [:]
    private var signingOut: Set<String> = []
    private var authorizationEpoch = 0
    private var unfinishedClientID: String?

    init(
        transport: any HTTPTransport,
        loadCredentials: @escaping @Sendable () throws -> Data?,
        saveCredentials: @escaping @Sendable (Data) throws -> Void,
        callbackFactory: @escaping @Sendable () -> any ChatGPTCallback,
        openBrowser: @escaping @Sendable (URL) async throws -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        self.transport = transport
        self.loadCredentials = loadCredentials
        self.saveCredentials = saveCredentials
        self.callbackFactory = callbackFactory
        self.openBrowser = openBrowser
        self.now = now
    }

    func accounts() throws -> [ChatGPTAccount] {
        _ = try savedState()
        return cachedAccounts()
    }

    /// Metadata only: error handling must not start a new Keychain read or network operation.
    func cachedAccounts() -> [ChatGPTAccount] {
        (state?.registrations ?? []).map { registration in
            var visible = registration
            if signingOut.contains(visible.clientID) { visible.tokens = nil }
            return visible.account
        }
    }

    func signIn(accountID: String?, enablePlanUsage: Bool) async throws -> String {
        try Task.checkCancellation()
        let saved = try savedState()
        // Persist the host identity before the first browser authorization, even if that attempt fails.
        try persist(saved)
        let returning = accountID.flatMap { id in saved.registrations.first { $0.clientID == id } }
        guard accountID == nil || returning != nil
        else { throw ChatGPTAuthError("Select a saved ChatGPT account first.") }
        let clientID = returning?.clientID ?? unfinishedClientID ?? ChatGPTAuth.dynamicClient
        let epoch = authorizationEpoch
        let configuration = try await discovery()
        try Task.checkCancellation()
        let callback = callbackFactory()
        do {
            let redirect = try await callback.start()
            let attempt = try ChatGPTAuthorization(redirectURI: redirect, clientID: clientID)
            try await openBrowser(attempt.url(
                endpoint: configuration.authorizationEndpoint, hostID: saved.hostID,
                email: returning?.email, idToken: returning?.tokens?.idToken, enablePlan: enablePlanUsage
            ))
            let response = try await callback.wait()
            await callback.cancel()
            try Task.checkCancellation()
            let accepted = try attempt.accept(response)
            if returning == nil { unfinishedClientID = accepted.clientID }
            let reply = try await tokenRequest([
                "grant_type": "authorization_code", "client_id": accepted.clientID,
                "code": accepted.code, "code_verifier": attempt.verifier,
                "redirect_uri": redirect.absoluteString, "resource": ChatGPTAuth.resource,
            ], endpoint: configuration.tokenEndpoint)
            guard let idToken = reply.idToken
            else { throw ChatGPTAuthError("ChatGPT did not return a verified identity.") }
            let identity = try await validate(idToken, clientID: accepted.clientID, nonce: attempt.nonce)
            guard returning == nil || returning?.subject == identity.subject else {
                throw ChatGPTAuthError(
                    "This sign-in belongs to a different account. The saved account was not changed."
                )
            }
            try Task.checkCancellation()
            guard authorizationEpoch == epoch else { throw CancellationError() }
            var updated = try savedState()
            let registration = try ChatGPTRegistration(
                clientID: accepted.clientID, subject: identity.subject, email: identity.email,
                tokens: reply.tokens(nonce: attempt.nonce, now: now())
            )
            if let index = updated.registrations.firstIndex(where: { $0.clientID == accepted.clientID }) {
                guard updated.registrations[index].subject == identity.subject else {
                    throw ChatGPTAuthError("ChatGPT returned a different identity for this registration.")
                }
                updated.registrations[index] = registration
            } else { updated.registrations.append(registration) }
            try persist(updated)
            signingOut.remove(accepted.clientID)
            unfinishedClientID = nil
            versions[accepted.clientID, default: 0] += 1
            return accepted.clientID
        } catch {
            await callback.cancel()
            throw error
        }
    }

    func accessToken(accountID: String) async throws -> String {
        try Task.checkCancellation()
        let record = try registration(accountID)
        guard !signingOut.contains(accountID), let tokens = record.tokens else { throw signInRequired() }
        guard tokens.scopes.contains(ChatGPTAuth.directScope) else {
            throw ChatGPTAuthError("Enable ChatGPT plan use for this account before captioning.")
        }
        if tokens.expiresAt > now().addingTimeInterval(60) { return tokens.accessToken }
        let version = versions[accountID, default: 0]
        let work: Task<String, any Error>
        if let pending = refreshing[accountID] {
            work = pending
        } else {
            work = Task { try await self.refresh(accountID: accountID, version: version) }
            refreshing[accountID] = work
        }
        do {
            let token = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            refreshing[accountID] = nil
            try Task.checkCancellation()
            guard versions[accountID, default: 0] == version, !signingOut.contains(accountID) else {
                throw signInRequired()
            }
            return token
        } catch {
            refreshing[accountID] = nil
            throw error
        }
    }

    func models(accountID: String) async throws -> [ChatGPTAvailableModel] {
        let token = try await accessToken(accountID: accountID)
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: ChatGPTAuth.resource)!.appendingPathComponent("models"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200
        else { throw ChatGPTAuthError("ChatGPT models could not load (HTTP \(response.status)).") }
        struct Catalog: Decodable { let models: [ChatGPTAvailableModel] }
        return try JSONDecoder().decode(Catalog.self, from: response.body).models.filter { $0.visibility == "list" }
    }

    func signOut(accountID: String) async throws -> Bool {
        let record = try registration(accountID)
        authorizationEpoch += 1
        versions[accountID, default: 0] += 1
        signingOut.insert(accountID)
        let pending = refreshing[accountID]
        pending?.cancel()
        if let pending { _ = await pending.result }
        refreshing[accountID] = nil
        var confirmed = record.tokens == nil
        if let token = record.tokens?.refreshToken {
            confirmed = await revoke(token, clientID: accountID)
        }
        var updated = try savedState()
        if let index = updated.registrations.firstIndex(where: { $0.clientID == accountID }) {
            updated.registrations[index].tokens = nil
        }
        // Keep the account blocked if Keychain removal fails; do not resume inference with that token set.
        try persist(updated)
        signingOut.remove(accountID)
        return confirmed
    }

    func cancelAndWait() async {
        authorizationEpoch += 1
        let tasks = Array(refreshing.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.result
        }
        refreshing = [:]
    }

    private func refresh(accountID: String, version: Int) async throws -> String {
        let record = try registration(accountID)
        guard let previous = record.tokens else { throw signInRequired() }
        do {
            let config = try await discovery()
            let reply = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": accountID,
                "refresh_token": previous.refreshToken, "resource": ChatGPTAuth.resource,
            ], endpoint: config.tokenEndpoint)
            if let identityToken = reply.idToken {
                let identity = try await validate(identityToken, clientID: accountID, nonce: nil)
                guard identity.subject == record.subject else { throw signInRequired() }
            }
            let tokens = try reply.tokens(previousID: previous.idToken, nonce: previous.nonce, now: now())
            try Task.checkCancellation()
            guard versions[accountID, default: 0] == version, !signingOut.contains(accountID) else {
                throw CancellationError()
            }
            var updated = try savedState()
            guard let index = updated.registrations.firstIndex(where: { $0.clientID == accountID }) else {
                throw signInRequired()
            }
            updated.registrations[index].tokens = tokens
            try persist(updated)
            guard tokens.scopes.contains(ChatGPTAuth.directScope) else {
                throw ChatGPTAuthError("ChatGPT plan use is no longer enabled for this account.")
            }
            return tokens.accessToken
        } catch let error as ChatGPTTokenFailure {
            let terminal = [
                "invalid_grant",
                "invalid_refresh_token",
                "token_expired",
                "refresh_token_expired",
                "refresh_token_invalidated",
                "refresh_token_reused",
            ]
            if let code = error.code, terminal.contains(code), versions[accountID, default: 0] == version {
                var updated = try savedState()
                if let index = updated.registrations.firstIndex(where: { $0.clientID == accountID }) {
                    updated.registrations[index].tokens = nil
                }
                try persist(updated)
                throw signInRequired()
            }
            throw error
        }
    }

    private func revoke(_ token: String, clientID: String) async -> Bool {
        for attempt in 0 ..< 2 {
            do {
                guard let endpoint = try await discovery().revocationEndpoint else { return false }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = ChatGPTAuth.form([
                    "token": token, "token_type_hint": "refresh_token", "client_id": clientID,
                ])
                let reply = try await transport.send(request)
                if reply.status == 200 { return true }
                if reply.status < 500 { return false }
            } catch is CancellationError { return false } catch {}
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(250)) }
        }
        return false
    }

    private func validate(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        let config = try await discovery()
        let reply = try await transport.send(URLRequest(url: config.jwksURI))
        guard reply.status == 200
        else { throw ChatGPTAuthError("ChatGPT's identity keys could not be loaded. Try again.") }
        return try ChatGPTIdentity.validate(token, jwks: reply.body, clientID: clientID, nonce: nonce, now: now())
    }

    private func discovery() async throws -> ChatGPTDiscovery {
        if let configuration { return configuration }
        let reply = try await transport.send(URLRequest(url: ChatGPTAuth.discoveryURL))
        guard reply.status == 200
        else { throw ChatGPTAuthError("ChatGPT sign-in is temporarily unavailable. Try again.") }
        let config = try JSONDecoder().decode(ChatGPTDiscovery.self, from: reply.body)
        let endpoints = [config.authorizationEndpoint, config.tokenEndpoint, config.jwksURI]
            + (config.revocationEndpoint.map { [$0] } ?? [])
        guard config.issuer == ChatGPTAuth.issuer,
              endpoints.allSatisfy({ $0.scheme == "https" && $0.host() == "auth.openai.com" }) else {
            throw ChatGPTAuthError("ChatGPT's sign-in configuration could not be verified.")
        }
        configuration = config
        return config
    }

    private func tokenRequest(_ values: [String: String], endpoint: URL) async throws -> ChatGPTTokenResponse {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTAuth.form(values)
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else {
            let error = try? JSONValue(parsing: response.body).objectValue?["error"]
            throw ChatGPTTokenFailure(
                code: error?.stringValue ?? error?.objectValue?["code"]?.stringValue,
                status: response.status
            )
        }
        return try JSONDecoder().decode(ChatGPTTokenResponse.self, from: response.body)
    }

    private func savedState() throws -> ChatGPTSavedState {
        try Task.checkCancellation()
        if let state { return state }
        let loaded = try loadCredentials().map { try JSONDecoder().decode(ChatGPTSavedState.self, from: $0) }
            ?? ChatGPTSavedState(hostID: "urn:uuid:" + UUID().uuidString, registrations: [])
        state = loaded
        return loaded
    }

    private func registration(_ id: String) throws -> ChatGPTRegistration {
        guard let record = try savedState().registrations.first(where: { $0.clientID == id }) else {
            throw signInRequired()
        }
        return record
    }

    private func persist(_ updated: ChatGPTSavedState) throws {
        try saveCredentials(JSONEncoder().encode(updated))
        state = updated
    }

    private func signInRequired() -> ChatGPTAuthError {
        ChatGPTAuthError("This ChatGPT session needs sign-in again. Its account registration is still saved.")
    }
}
