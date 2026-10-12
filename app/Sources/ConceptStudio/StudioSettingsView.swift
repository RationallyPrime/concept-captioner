import ConceptCore
import SwiftUI

private enum CaptioningAccountChoice: String, CaseIterable, Identifiable {
    case chatGPT
    case openRouter
    case apiKey

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT plan"
        case .openRouter: "OpenRouter"
        case .apiKey: "API key"
        }
    }
}

struct StudioSettingsView: View {
    @Bindable var session: StudioSession
    @State private var captioningAccount: CaptioningAccountChoice = .chatGPT
    @State private var account = "openrouter"
    @State private var enteredKey = ""
    @State private var huggingFaceToken = ""
    @State private var runPodKey = ""
    @State private var keyPresence: [String: Bool] = [:]
    @State private var keyStatusText: [String: String] = [:]
    @State private var checkingAccount: String?
    @State private var keyCheckGeneration = 0
    @State private var keyCheckTask: Task<Void, Never>?
    @State private var preferencesNote = ""
    @State private var failure: String?
    @Environment(\.openWindow) private var openWindow

    private let gateways = ["openrouter", "vercel", "gateway"]
    private let manualProviders = ["openrouter", "vercel", "gateway", "google", "anthropic", "openai", "vllm"]
    private let additionalAccounts = ["huggingface", "runpod"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accounts & settings").font(.title2.weight(.semibold))
                }
                Spacer()
                if session.demoMode { DemoBadge() }
                Button("Help", systemImage: "questionmark.circle") { openWindow(id: "help") }
                    .help("Open the training explanation and searchable definitions.")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                    StudioTermsHelp(terms: [.provider, .apiKey, .keychain, .gateway, .tokens])
                    captioningAccounts
                    Divider()
                    publishingAndTrainingAccounts
                    Divider()
                    DisclosureGroup("Advanced: custom servers and training images") {
                        advancedPreferences.padding(.top, 12)
                    }
                    Divider()
                    StudioSection(
                        title: "Offline demo",
                        subtitle: session.demoMode
                            ? "The demo is offline and uses prepared examples."
                            : "Explore the whole journey with prepared examples without an account or spending."
                    ) {
                        Button("Try the offline demo") {
                            // The discard prompt is attached to the studio window; bring it in front of Settings.
                            openWindow(id: "studio")
                            session.useDemo()
                        }
                        .disabled(session.busy || session.gpu.hasRunningPod || session.gpu.isBusy)
                        .help("Opens the example project with simulated services; no credentials or network are used.")
                    }
                }.padding(24)
            }
        }
        .tint(StudioStyle.accent)
        .frame(width: 700, height: 680)
        .background(StudioStyle.canvas)
        .onAppear { reloadKeyStatuses() }
        .task(id: session.demoMode) {
            guard !session.demoMode else { return }
            await session.chatGPT.load()
            if !session.demoMode, !Task.isCancelled { await session.openRouter.load() }
        }
        .alert("You’re using your ChatGPT plan", isPresented: $session.showChatGPTPlanNotice) {
            Button("Got it") { session.acknowledgeChatGPTPlan() }
        } message: {
            Text("Eligible OpenAI requests in ConceptStudio count toward your ChatGPT plan or credits balance. "
                + "Use Manage usage to review your allowance and set an app limit in ChatGPT settings.")
        }
        .alert(
            "Something needs your attention",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
        .onChange(of: captioningAccount) { _, _ in enteredKey = "" }
        .onChange(of: account) { _, _ in enteredKey = "" }
        .onChange(of: session.demoMode) { _, _ in
            cancelKeyCheck()
            session.chatGPT.cancelSignIn()
            session.openRouter.cancel()
            enteredKey = ""
            huggingFaceToken = ""
            runPodKey = ""
            reloadKeyStatuses()
        }
        .onDisappear {
            cancelKeyCheck()
            session.chatGPT.cancelSignIn()
            session.openRouter.cancel()
        }
        .onChange(of: session.openRouter.isBusy) { _, busy in if !busy { reloadKeyStatuses() } }
        .onChange(of: session.openRouter.isConnected) { _, connected in
            if !connected { session.clearProviderModelChoices(for: "openrouter") }
        }
    }

    private var captioningAccounts: some View {
        StudioSection(
            title: "Connect a captioning account",
            subtitle: "Connect your accounts here, then choose the provider and model on Captioning."
        ) {
            Picker("Connection", selection: $captioningAccount) {
                ForEach(CaptioningAccountChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.demoMode || session.busy)

            switch captioningAccount {
            case .chatGPT:
                ChatGPTSettingsSection(session: session).padding(.top, 12)
            case .openRouter:
                OpenRouterSettingsSection(session: session).padding(.top, 12)
            case .apiKey:
                manualProviderKey.padding(.top, 12)
            }
        }
    }

    private var manualProviderKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Account", selection: $account) {
                    Section("Gateways") {
                        ForEach(gateways, id: \.self) { Text(title($0)).tag($0) }
                    }
                    Section("Direct providers and custom servers") {
                        ForEach(manualProviders.dropFirst(gateways.count), id: \.self) {
                            Text(title($0)).tag($0)
                        }
                    }
                }
                .help("Choose the service this key opens; it does not choose a model or change billing routes.")
                SecureField("Account key", text: $enteredKey, prompt: Text("Paste account key"))
                    .help("Saved in this Mac’s Keychain. It is never written to the project.")
                LabeledContent("Status", value: keyStatus(account))
            }.formStyle(.columns)

            if let url = accountKeyURL {
                Link("Get a key from \(title(account))", destination: url)
                    .help("Opens the service’s key settings; it does not create a key or buy credits.")
            }

            HStack(spacing: 12) {
                Button(checkingAccount == account ? "Checking key…" : "Save and check key") {
                    saveManualKey()
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(session.demoMode || session.busy || session.openRouter.isBusy
                    || checkingAccount != nil
                    || enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Saves the key, then checks it with a read-only provider request that generates nothing.")

                Button("Remove saved key") { removeKey(account) }
                    .disabled(session.demoMode || session.busy || session.openRouter.isBusy
                        || checkingAccount != nil || keyPresence[account] != true)
                    .help("Removes this key from the Mac; it does not revoke it at the provider.")
            }
        }
    }

    private var publishingAndTrainingAccounts: some View {
        StudioSection(
            title: "Publishing and training accounts",
            subtitle: "Use these accounts to publish datasets and rent training computers."
        ) {
            Form {
                LabeledContent("Hugging Face", value: keyStatus("huggingface"))
                SecureField("Hugging Face write token", text: $huggingFaceToken, prompt: Text("Paste write token"))
                    .help("Saved in this Mac’s Keychain and used for Hugging Face publishing.")
            }.formStyle(.columns)
            HStack(spacing: 12) {
                Button(checkingAccount == "huggingface" ? "Checking token…" : "Save and check token") {
                    saveAdditionalKey("huggingface", value: huggingFaceToken)
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(session.demoMode || session.busy || checkingAccount != nil
                    || huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Saves the token, then asks Hugging Face who it belongs to; no data is uploaded.")
                Button("Remove saved token") { removeKey("huggingface") }
                    .disabled(session.demoMode || session.busy || checkingAccount != nil
                        || keyPresence["huggingface"] != true)
                    .help("Removes this token from the Mac; it does not revoke it on Hugging Face.")
                if let url = URL(string: "https://huggingface.co/settings/tokens") {
                    Link("Token settings", destination: url)
                }
            }

            Divider()

            Form {
                LabeledContent("RunPod", value: keyStatus("runpod"))
                SecureField("RunPod API key", text: $runPodKey, prompt: Text("Paste API key"))
                    .help("Saved in this Mac’s Keychain and used only for RunPod account actions.")
            }.formStyle(.columns)
            HStack(spacing: 12) {
                Button(checkingAccount == "runpod" ? "Checking key…" : "Save and check key") {
                    saveAdditionalKey("runpod", value: runPodKey)
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(session.demoMode || session.busy || checkingAccount != nil
                    || runPodKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Saves the key, then reads the RunPod computer list; it creates and rents nothing.")
                Button("Remove saved key") { removeKey("runpod") }
                    .disabled(session.demoMode || session.busy || checkingAccount != nil
                        || keyPresence["runpod"] != true)
                    .help("Removes this key from the Mac; it does not revoke it at RunPod.")
            }
        }
    }

    private var advancedPreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioTermsHelp(terms: [.containerImage, .networkStorage, .provider])
            Form {
                TextField("vLLM server URL", text: $session.customBaseURL)
                    .help("An OpenAI-compatible server you control; the vLLM key goes only to this configured host.")
                TextField(
                    "Custom training image",
                    text: $session.podImageName,
                    prompt: Text(StudioSession.defaultPodImageName)
                )
                .help("Leave blank to use the published default image when renting a computer.")
                TextField("RunPod network volume ID", text: $session.volumeID, prompt: Text("Optional"))
                    .help("An existing persistent storage volume in the RunPod data center used for a rental.")
            }.formStyle(.columns)
            HStack(spacing: 12) {
                Button("Save preferences") {
                    session.rememberChoices()
                    session.configureGPU()
                    session.gpuKeysLoadedFor = session.gpu
                    preferencesNote = "Preferences saved."
                }
                .disabled(session.demoMode)
                .help("Saves these Mac-level choices and configures computer controls; it rents nothing.")
                if !preferencesNote.isEmpty {
                    Label(preferencesNote, systemImage: "checkmark.circle").font(.callout)
                }
            }
        }
    }

    private var accountKeyURL: URL? {
        switch account {
        case "openrouter": URL(string: "https://openrouter.ai/settings/keys")
        case "vercel": URL(string: "https://vercel.com/ai-gateway")
        case "gateway": URL(string: "https://logfire.pydantic.dev")
        case "google": URL(string: "https://aistudio.google.com/apikey")
        case "anthropic": URL(string: "https://console.anthropic.com/settings/keys")
        case "openai": URL(string: "https://platform.openai.com/api-keys")
        default: nil
        }
    }

    private func keyStatus(_ name: String) -> String {
        if session.demoMode { return "Demo · no key used" }
        guard keyPresence[name] == true else { return "Not set" }
        return keyStatusText[name] ?? "Saved in Keychain · not checked in this app session"
    }

    private func title(_ kind: String) -> String {
        switch kind {
        case "gateway": "Pydantic AI Gateway"
        case "huggingface": "Hugging Face"
        case "runpod": "RunPod"
        default: ProviderChoices.title(kind)
        }
    }

    private func reloadKeyStatuses() {
        guard !session.demoMode else {
            keyPresence = [:]
            keyStatusText = [:]
            return
        }
        do {
            for name in manualProviders + additionalAccounts {
                let present = try session.secrets.read(name)?.isEmpty == false
                keyPresence[name] = present
                if !present {
                    keyStatusText[name] = "Not set"
                } else if keyStatusText[name] == nil || keyStatusText[name] == "Not set" {
                    keyStatusText[name] = "Saved in Keychain · not checked in this app session"
                }
            }
        } catch {
            failure = StudioSession.describe(error)
        }
    }

    private func saveManualKey() {
        saveKey(account, value: enteredKey)
        enteredKey = ""
    }

    private func saveAdditionalKey(_ name: String, value: String) {
        saveKey(name, value: value)
        if name == "huggingface" { huggingFaceToken = "" } else { runPodKey = "" }
    }

    private func saveKey(_ name: String, value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try session.secrets.save(value, account: name)
            keyPresence[name] = true
            keyStatusText[name] = "Checking…"
            if name == "huggingface" { session.providerCredentialsDidChange() }
            clearProviderModels(for: name)
            reloadGPUKeysIfNeeded(name)
            cancelKeyCheck()
            let generation = keyCheckGeneration
            checkingAccount = name
            keyCheckTask = Task { await checkKey(name, generation: generation) }
        } catch {
            failure = StudioSession.describe(error)
        }
    }

    private func removeKey(_ name: String) {
        do {
            try session.secrets.save("", account: name)
            cancelKeyCheck()
            keyPresence[name] = false
            keyStatusText[name] = "Not set"
            if name == "huggingface" { session.providerCredentialsDidChange() }
            clearProviderModels(for: name)
            reloadGPUKeysIfNeeded(name)
            if name == "openrouter" { Task { await session.openRouter.load() } }
        } catch {
            failure = StudioSession.describe(error)
        }
    }

    private func reloadGPUKeysIfNeeded(_ name: String) {
        guard ["runpod", "huggingface"].contains(name) else { return }
        session.configureGPU()
        session.gpuKeysLoadedFor = session.gpu
    }

    private func clearProviderModels(for account: String) {
        session.clearProviderModelChoices(for: account == "gateway" ? "gateway/anthropic" : account)
    }

    private func cancelKeyCheck() {
        keyCheckGeneration &+= 1
        keyCheckTask?.cancel()
        keyCheckTask = nil
        checkingAccount = nil
    }

    @MainActor
    private func checkKey(_ name: String, generation: Int) async {
        defer {
            if generation == keyCheckGeneration {
                checkingAccount = nil
                keyCheckTask = nil
            }
        }
        do {
            switch name {
            case "huggingface":
                let token = try session.secrets.read(name) ?? ""
                try await ProviderCredentialValidator.checkHuggingFace(token: token)
                try Task.checkCancellation()
                guard generation == keyCheckGeneration else { return }
                keyStatusText[name] = "Works · account accepted the token"
            case "runpod":
                let key = try session.secrets.read(name) ?? ""
                try await ProviderCredentialValidator.checkRunPod(key: key)
                try Task.checkCancellation()
                guard generation == keyCheckGeneration else { return }
                keyStatusText[name] = "Works · account accepted the key"
            case "openrouter":
                await session.openRouter.refresh()
                try Task.checkCancellation()
                guard generation == keyCheckGeneration else { return }
                if let error = session.openRouter.errorMessage { throw StudioError.message(error) }
                let models = try await session.refreshProviderModels(for: name)
                guard generation == keyCheckGeneration else { return }
                keyStatusText[name] = "Works · \(models.count) models listed"
            default:
                let kind = name == "gateway" ? "gateway/anthropic" : name
                let models = try await session.checkSavedProviderKey(for: kind)
                guard generation == keyCheckGeneration else { return }
                keyStatusText[name] = "Works · \(models.count) models listed"
            }
        } catch is CancellationError {
            if generation == keyCheckGeneration { keyStatusText[name] = "Saved in Keychain · check cancelled" }
        } catch {
            if generation == keyCheckGeneration { keyStatusText[name] = error.localizedDescription }
        }
    }
}
