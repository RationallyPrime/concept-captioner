import AppKit
import ConceptCore
import Foundation
import Observation

struct OpenRouterKeyInfo: Decodable, Equatable {
    let creatorUserID: String?
    let limit: Double?
    let limitRemaining: Double?
    let limitReset: String?
    let usage: Double
    let usageDaily: Double?
    let usageMonthly: Double?
    let isFreeTier: Bool

    enum CodingKeys: String, CodingKey {
        case creatorUserID = "creator_user_id"
        case limit, usage
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usageDaily = "usage_daily"
        case usageMonthly = "usage_monthly"
        case isFreeTier = "is_free_tier"
    }
}

@MainActor @Observable
final class OpenRouterConnection {
    private(set) var isConnected = false
    private(set) var isBusy = false
    private(set) var info: OpenRouterKeyInfo?
    private(set) var lastRefreshed: Date?
    private(set) var keyHash: String?
    var message = ""
    var errorMessage: String?

    var keySettingsURL: URL {
        keyHash.flatMap { URL(string: "https://openrouter.ai/keys/\($0)") }
            ?? URL(string: "https://openrouter.ai/settings/keys")!
    }

    var activityURL: URL {
        var parts = URLComponents(string: "https://openrouter.ai/logs")!
        if let keyHash { parts.queryItems = [URLQueryItem(name: "api_key_hash", value: keyHash)] }
        return parts.url!
    }

    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let callbackFactory: @Sendable () -> any ChatGPTCallback
    @ObservationIgnored private let openBrowser: @Sendable (URL) async throws -> Void
    @ObservationIgnored private var operationTask: Task<Bool, Never>?
    @ObservationIgnored private var operationID = UUID()

    init(
        secrets: any SecretStore = KeychainStore(),
        transport: any HTTPTransport = OpenRouterAuthorizationTransport(),
        callbackFactory: @escaping @Sendable () -> any ChatGPTCallback = {
            ChatGPTLoopbackCallback(providerName: "OpenRouter")
        },
        openBrowser: @escaping @Sendable (URL) async throws -> Void = { url in
            try await MainActor.run {
                guard NSWorkspace.shared.open(url) else {
                    throw OpenRouterConnectionError("Your browser could not open OpenRouter. Connect again.")
                }
            }
        }
    ) {
        self.secrets = secrets
        self.transport = transport
        self.callbackFactory = callbackFactory
        self.openBrowser = openBrowser
    }

    /// Explicit local loading only. The session must not call this in the offline demo.
    func load() async {
        _ = await run { _ = try self.savedKey() }
    }

    @discardableResult
    func connect() async -> Bool {
        await run {
            self.message = "Approve ConceptStudio in your browser. This creates an OpenRouter API key."
            let callback = self.callbackFactory()
            do {
                let redirect = try await callback.start()
                let attempt = try OpenRouterAuthorization(redirectURI: redirect)
                try Task.checkCancellation()
                try await self.openBrowser(attempt.browserURL)
                let response = try await callback.wait()
                await callback.cancel()
                try Task.checkCancellation()
                let request = try attempt.exchangeRequest(callback: response)
                let result = try await self.transport.send(request)
                try Task.checkCancellation()
                guard result.status == 200 else {
                    throw OpenRouterConnectionError(result.status == 403
                        ? "OpenRouter did not accept the authorization code. Connect again to get a new code."
                        : "OpenRouter could not finish authorization (HTTP \(result.status)). Connect again.")
                }
                struct Exchange: Decodable { let key: String }
                guard let exchanged = try? JSONDecoder().decode(Exchange.self, from: result.body),
                      !exchanged.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw OpenRouterConnectionError("OpenRouter did not return a usable API key. Connect again.")
                }
                try self.secrets.save(exchanged.key, account: "openrouter")
                self.adopt(exchanged.key)
                self.message = "Connected to OpenRouter. Caption requests use OpenRouter credits."
            } catch {
                await callback.cancel()
                throw error
            }
        }
    }

    func refresh() async {
        _ = await run {
            guard let key = try self.savedKey() else {
                throw OpenRouterConnectionError("Connect OpenRouter or save an API key before refreshing usage.")
            }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let response = try await self.transport.send(request)
            try Task.checkCancellation()
            guard response.status == 200 else {
                if response.status == 401 { self.isConnected = false; self.info = nil; self.lastRefreshed = nil }
                throw OpenRouterConnectionError(response.status == 401
                    ? "OpenRouter did not accept this saved key. Reconnect or replace it in Settings."
                    : "OpenRouter key usage could not be refreshed (HTTP \(response.status)). Try refreshing again.")
            }
            struct Envelope: Decodable { let data: OpenRouterKeyInfo }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.body) else {
                throw OpenRouterConnectionError("OpenRouter returned unreadable key usage. Try refreshing again.")
            }
            self.info = envelope.data
            self.lastRefreshed = Date()
            self.message = "OpenRouter key usage refreshed."
        }
    }

    /// Ordinary keys cannot revoke themselves through the management API. Remove locally;
    /// keep the key-settings link available for the owner to revoke it on OpenRouter.
    func disconnect() async {
        await cancelAndWait()
        _ = await run {
            try self.secrets.save("", account: "openrouter")
            self.isConnected = false
            self.info = nil
            self.lastRefreshed = nil
            self.message = "OpenRouter key removed from this Mac. Revoke it on OpenRouter to disable it elsewhere."
        }
    }

    func cancel() {
        operationTask?.cancel()
    }

    func cancelAndWait() async {
        let pending = operationTask
        pending?.cancel()
        _ = await pending?.value
    }

    private func savedKey() throws -> String? {
        let key = try secrets.read("openrouter")
        if let key, !key.isEmpty {
            adopt(key)
            return key
        }
        isConnected = false; info = nil; lastRefreshed = nil
        return nil
    }

    private func adopt(_ key: String) {
        let hash = OpenRouterAuthorization.keyHash(key)
        if keyHash != hash { info = nil; lastRefreshed = nil }
        keyHash = hash
        isConnected = true
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        let id = UUID()
        operationID = id
        let work = Task { @MainActor in
            defer { self.isBusy = false }
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                return true
            } catch is CancellationError {
                self.message = "OpenRouter account action cancelled."
                return false
            } catch {
                if Task.isCancelled {
                    self.message = "OpenRouter account action cancelled."
                    return false
                }
                self.errorMessage = (error as? OpenRouterConnectionError)?.message
                    ?? (error as? ChatGPTAuthError)?.message
                    ?? (error as? StudioError)?.localizedDescription
                    ?? "OpenRouter could not connect. Check your internet connection and try again."
                return false
            }
        }
        operationTask = work
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if operationID == id { operationTask = nil }
        return result
    }
}
