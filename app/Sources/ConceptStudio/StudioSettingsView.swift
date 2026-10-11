import ConceptCore
import SwiftUI

struct StudioSettingsView: View {
    @Bindable var session: StudioSession
    @State private var account = "openrouter"
    @State private var enteredKey = ""
    @State private var keyStatuses: [String: Bool] = [:]
    @State private var keyNote = ""
    @State private var testNote = ""
    @State private var preferencesNote = ""
    @State private var failure: String?
    @State private var testing = false
    @Environment(\.openWindow) private var openWindow

    private let gateways = ["openrouter", "vercel", "gateway"]
    private let advanced = ["google", "anthropic", "openai", "vllm", "huggingface", "runpod"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accounts & settings").font(.title2.weight(.semibold))
                    Text("Connect once, then choose your model on Captioning.")
                        .foregroundStyle(StudioStyle.supportingText)
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
                    ChatGPTSettingsSection(session: session)
                    Divider()
                    OpenRouterSettingsSection(session: session)
                    Divider()
                    accountKeys
                    Divider()
                    connectionTest
                    Divider()
                    DisclosureGroup("Saved accounts") {
                        Form {
                            ForEach(gateways + advanced, id: \.self) { kind in
                                LabeledContent(title(kind), value: keyStatus(kind))
                            }
                        }.formStyle(.columns).padding(.top, 12)
                    }
                    DisclosureGroup("Advanced: custom servers and training images") {
                        advancedPreferences.padding(.top, 12)
                    }
                    Divider()
                    StudioSection(
                        title: "Offline demo",
                        subtitle: session.demoMode
                            ? "Demo is on. No saved keys or network connections are used."
                            : "The offline demo walks through the whole journey without an account or spending."
                    ) {
                        Button("Try the offline demo") {
                            // The discard prompt is attached to the studio window; bring it in front of Settings.
                            openWindow(id: "studio")
                            session.useDemo()
                        }
                        .disabled(session.busy || session.gpu.hasRunningPod || session.gpu.isBusy)
                        .help(
                            "Opens the example project with simulated services; no credentials or network."
                        )
                        Text("Open or create a real project to leave demo mode.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                }.padding(24)
            }
        }
        .tint(StudioStyle.accent)
        .frame(width: 700, height: 680)
        .background(StudioStyle.canvas)
        .onAppear { reload() }
        .task(id: session.demoMode) {
            if !session.demoMode {
                await session.chatGPT.load()
                if !session.demoMode, !Task.isCancelled { await session.openRouter.load() }
            }
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
        .onChange(of: account) { _, _ in enteredKey = ""; keyNote = "" }
        .onChange(of: session.demoMode) { _, _ in
            if testing { session.cancel() }
            session.chatGPT.cancelSignIn()
            session.openRouter.cancel()
            enteredKey = ""; reload()
        }
        .onDisappear {
            if testing { session.cancel() }
            session.chatGPT.cancelSignIn()
            session.openRouter.cancel()
        }
        .onChange(of: session.openRouter.isBusy) { _, busy in if !busy { reload() } }
        .onChange(of: session.openRouter.errorMessage) { _, error in
            if let error { failure = error }
        }
    }

    private var accountKeys: some View {
        StudioSection(
            title: "Manual API keys",
            subtitle: "A gateway gives you several captioning models through one account. "
                + "An API key authorizes requests to that service, which bills usage to your account."
        ) {
            Form {
                Picker("Account", selection: $account) {
                    Section("Gateways") {
                        ForEach(gateways, id: \.self) { Text(title($0)).tag($0) }
                    }
                    Section("Direct providers and training") {
                        ForEach(advanced, id: \.self) { Text(title($0)).tag($0) }
                    }
                }
                .help("Chooses which service receives the key. Choose the captioning service separately on Captioning.")
                SecureField("Account key", text: $enteredKey, prompt: Text("Paste account key"))
                    .help("Saved in your Mac's Keychain, never in the project.")
                LabeledContent("Status", value: keyStatus(account))
            }.formStyle(.columns)
            if let url = accountKeyURL {
                Link("Get a key from \(title(account))", destination: url)
                    .help(
                        "Opens the service's account page. It does not create a key or purchase credits automatically."
                    )
            }
            HStack(spacing: 12) {
                Button("Save in Keychain") { save() }.buttonStyle(.borderedProminent)
                    .tint(StudioStyle.actionTint)
                    .help("Saves this credential for the selected service in your Mac’s Keychain, outside the project.")
                    .disabled(session.demoMode || session.busy || session.openRouter.isBusy
                        || enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty)
                Button("Remove saved key") { remove() }
                    .help(
                        "Removes the selected service’s credential from this Mac. It does not revoke it at the service."
                    )
                    .disabled(session.demoMode || session.busy || session.openRouter
                        .isBusy || keyStatuses[account] != true)
                if !keyNote.isEmpty {
                    Label(keyNote, systemImage: "checkmark.circle").font(.callout)
                }
            }
            Text("Keys are saved in your Mac’s Keychain and never included in a project upload.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
        }
    }

    private var connectionTest: some View {
        StudioSection(
            title: "Test your captioning connection",
            subtitle: "Tests the choices on Captioning. Live tests use the selected account’s allowance."
        ) {
            Form {
                LabeledContent("Account", value: ProviderChoices.title(session.endpointKind))
                LabeledContent("Model", value: session.modelName)
                    .textSelection(.enabled)
                if session.endpointKind == "openai" {
                    LabeledContent("Uses", value: session.openAIUsesChatGPT ? "ChatGPT plan" : "OpenAI API credits")
                }
            }.formStyle(.columns)
            HStack(spacing: 12) {
                Button(testing ? "Testing connection…" : "Test captioning connection") { test() }
                    .disabled(session.busy)
                    .help(
                        "Sends a small request using the selected model and account. Live tests consume billed usage."
                    )
                if testing {
                    ProgressView().controlSize(.small)
                    Button("Cancel test") { session.cancel() }
                        .help("Cancels the current test request; no project captions are written by the test.")
                } else if !testNote.isEmpty {
                    Label(testNote, systemImage: "checkmark.circle").font(.callout)
                }
            }
        }
    }

    private var advancedPreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioTermsHelp(terms: [.containerImage, .networkStorage, .provider])
            Form {
                TextField("vLLM server URL", text: $session.customBaseURL)
                    .help(
                        "An OpenAI-compatible model server you control. Its key goes only to this origin."
                    )
                TextField("Custom training image", text: $session.podImageName, prompt: Text("Optional"))
                    .help(
                        "Chooses a custom container for rented computers. Leave blank for published defaults."
                    )
                TextField("RunPod network volume ID", text: $session.volumeID, prompt: Text("Optional"))
                    .help(
                        "An existing persistent storage volume in the rental’s RunPod data center."
                    )
            }.formStyle(.columns)
            Text("The vLLM key goes only to this host. A downloaded job cannot redirect it. "
                + "The training image is chosen automatically; clear and save an override to restore it.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Save preferences") {
                    session.rememberChoices(); session.configureGPU(); session.gpuKeysLoadedFor = session.gpu
                    preferencesNote = "Preferences saved."
                }.disabled(session.demoMode)
                    .help(
                        "Saves these Mac-level choices and configures the current computer controls; it rents nothing."
                    )
                if !preferencesNote.isEmpty {
                    Label(preferencesNote, systemImage: "checkmark.circle").font(.callout)
                }
            }
        }
    }

    private var accountKeyURL: URL? {
        switch account {
        case "openrouter": URL(string: "https://openrouter.ai/settings/keys")
        case "vercel": URL(string: "https://vercel.com/docs/ai-gateway/authentication-and-byok/api-keys")
        case "gateway": URL(string: "https://logfire.pydantic.dev")
        default: nil
        }
    }

    private func keyStatus(_ account: String) -> String {
        if session.demoMode { return "Demo — no key used" }
        return keyStatuses[account] == true ? "Saved in Keychain" : "Not set"
    }

    private func title(_ kind: String) -> String {
        switch kind {
        case "gateway": "Pydantic AI Gateway"
        case "huggingface": "Hugging Face write token"
        case "runpod": "RunPod"
        default: ProviderChoices.title(kind)
        }
    }

    private func reload() {
        guard !session.demoMode else { keyStatuses = [:]; return }
        do {
            for account in gateways +
                advanced {
                keyStatuses[account] = try session.keyStore.read(account)?.isEmpty == false
            }
        } catch { failure = StudioSession.describe(error) }
    }

    private func save() {
        do {
            try session.keyStore.save(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            enteredKey = ""; reload(); keyNote = "Saved in your Mac's Keychain."
            reloadGPUKeysIfNeeded()
            reloadOpenRouterIfNeeded()
        } catch { failure = StudioSession.describe(error) }
    }

    private func remove() {
        do {
            try session.keyStore.save("", account: account)
            reload()
            keyNote = "Saved key removed."
            reloadGPUKeysIfNeeded()
            reloadOpenRouterIfNeeded()
        } catch {
            failure = StudioSession.describe(error)
        }
    }

    /// The GPU screens read the RunPod and Hub keys once; a change to either is read again here.
    private func reloadGPUKeysIfNeeded() {
        guard ["runpod", "huggingface"].contains(account) else { return }
        session.configureGPU()
        session.gpuKeysLoadedFor = session.gpu
    }

    private func reloadOpenRouterIfNeeded() {
        guard account == "openrouter", !session.demoMode else { return }
        Task { await session.openRouter.load() }
    }

    private func test() {
        testing = true
        testNote = ""
        session.perform("Testing captioning connection…") {
            defer { testing = false }
            do {
                if session.demoMode { testNote = "Demo connection works locally; no key or network used."; return }
                if session.endpointKind == "openai", session.openAIUsesChatGPT {
                    let generation = session.chatGPTWorkGeneration
                    await session.prepareChatGPTModels(duringConnectionTest: true)
                    try Task.checkCancellation()
                    guard generation == session.chatGPTWorkGeneration, !session.demoMode else {
                        throw CancellationError()
                    }
                    if session.chatGPT.availableModels.isEmpty, let issue = session.chatGPT.errorMessage {
                        throw StudioError.message(issue)
                    }
                }
                let endpoint = try session.endpoint()
                _ = try await endpoint.client.request(
                    instructions: "Return a Caption object with caption set to connected.",
                    messages: [.user("Test connection")],
                    output: OutputRequest(
                        name: Caption.schemaName,
                        schema: Caption.jsonSchema,
                        mode: endpoint.outputMode
                    ),
                    settings: endpoint.settings
                )
                testNote = "Connection succeeded."
            } catch is CancellationError {
                testNote = ""
            } catch {
                failure = StudioSession.describe(error)
            }
        }
    }
}
