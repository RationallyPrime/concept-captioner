import AppKit
import ConceptCore
import Foundation
import Observation

struct ChatGPTAccount: Identifiable, Equatable {
    var id: String {
        clientID
    }

    let clientID: String
    let email: String?
    let label: String
    let isSignedIn: Bool
    let hasPlanPermission: Bool
}

struct ChatGPTAvailableModel: Identifiable, Codable, Equatable {
    var id: String {
        slug
    }

    let slug: String
    let displayName: String
    let visibility: String

    enum CodingKeys: String, CodingKey {
        case slug, visibility
        case displayName = "display_name"
    }
}

@MainActor @Observable
final class ChatGPTAccounts {
    private(set) var accounts: [ChatGPTAccount] = []
    private(set) var availableModels: [ChatGPTAvailableModel] = []
    private(set) var isBusy = false
    var message = ""
    var errorMessage: String?
    var selectedAccountID: String? {
        didSet {
            guard oldValue != selectedAccountID else { return }
            availableModels = []
            preferences.set(selectedAccountID, forKey: "chatgpt.selectedAccount")
        }
    }

    var selectedAccount: ChatGPTAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    @ObservationIgnored private let session: ChatGPTSession
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var operationTask: Task<Bool, Never>?
    @ObservationIgnored private var operationID = UUID()

    init(
        preferences: UserDefaults = .standard,
        transport: any HTTPTransport = URLSessionTransport(timeout: 30),
        loadCredentials: @escaping @Sendable () throws -> Data? = {
            try KeychainStore().read("chatgpt.accounts").map { Data($0.utf8) }
        },
        saveCredentials: @escaping @Sendable (Data) throws -> Void = {
            guard let text = String(bytes: $0, encoding: .utf8) else {
                throw ChatGPTAuthError("ChatGPT credentials could not be saved.")
            }
            try KeychainStore().save(text, account: "chatgpt.accounts")
        },
        callbackFactory: @escaping @Sendable () -> any ChatGPTCallback = { ChatGPTLoopbackCallback() },
        openBrowser: @escaping @Sendable (URL) async throws -> Void = { url in
            try await MainActor.run {
                guard NSWorkspace.shared.open(url) else {
                    throw ChatGPTAuthError("Your browser could not open ChatGPT sign-in. Try again.")
                }
            }
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.preferences = preferences
        session = ChatGPTSession(
            transport: transport, loadCredentials: loadCredentials, saveCredentials: saveCredentials,
            callbackFactory: callbackFactory, openBrowser: openBrowser, now: now
        )
    }

    /// Loading is explicit so an offline demo never touches the Keychain or network.
    func load() async {
        _ = await run {
            self.accounts = try await self.session.accounts()
            if self.selectedAccountID == nil {
                let saved = self.preferences.string(forKey: "chatgpt.selectedAccount")
                self.selectedAccountID = self.accounts.contains { $0.id == saved } ? saved : self.accounts.first?.id
            }
        }
    }

    @discardableResult
    func signIn(accountID: String? = nil, enablePlanUsage: Bool = false) async -> Bool {
        await run {
            self.message = "Finish signing in with ChatGPT in your browser."
            let id = try await self.session.signIn(accountID: accountID, enablePlanUsage: enablePlanUsage)
            try Task.checkCancellation()
            self.accounts = try await self.session.accounts()
            self.selectedAccountID = id
            self.availableModels = []
            self.message = self.selectedAccount?.hasPlanPermission == true
                ? "Signed in with ChatGPT. Your ChatGPT plan can be used for captioning."
                : "Signed in. ChatGPT plan use is not enabled; enable it before captioning."
        }
    }

    func cancelSignIn() {
        operationTask?.cancel()
    }

    func cancelAndWait() async {
        let pending = operationTask
        pending?.cancel()
        await session.cancelAndWait()
        _ = await pending?.value
    }

    func signOut() async {
        guard let id = selectedAccountID else { return }
        await cancelAndWait()
        _ = await run {
            self.availableModels = []
            let confirmed = try await self.session.signOut(accountID: id)
            self.accounts = try await self.session.accounts()
            self.message = confirmed ? "Signed out of this ChatGPT account. Its registration is saved for later."
                : "Signed out locally. Remote revocation was not confirmed; disconnect the app in ChatGPT Settings."
        }
    }

    func refreshModels() async {
        guard let id = selectedAccountID else { return }
        _ = await run {
            self.availableModels = []
            let models = try await self.session.models(accountID: id)
            try Task.checkCancellation()
            guard self.selectedAccountID == id else { return }
            self.accounts = try await self.session.accounts()
            self.availableModels = models
            self.message = models.isEmpty ? "This ChatGPT account has no available models." : "ChatGPT models updated."
        }
    }

    func tokenProvider(accountID: String) -> @Sendable () async throws -> String {
        let session = session
        return { [weak self] in
            do {
                return try await session.accessToken(accountID: accountID)
            } catch {
                let accounts = await session.cachedAccounts()
                await self?.synchronizeAccounts(accounts)
                throw error
            }
        }
    }

    private func synchronizeAccounts(_ updated: [ChatGPTAccount]) {
        accounts = updated
        if selectedAccount?.hasPlanPermission != true { availableModels = [] }
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
                try await operation()
                try Task.checkCancellation()
                return true
            } catch is CancellationError {
                await self.synchronizeAccounts(self.session.cachedAccounts())
                self.message = "ChatGPT account action cancelled."
                return false
            } catch {
                await self.synchronizeAccounts(self.session.cachedAccounts())
                self.errorMessage = error.localizedDescription
                return false
            }
        }
        operationTask = work
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if operationID == id { operationTask = nil }
        return result
    }
}
