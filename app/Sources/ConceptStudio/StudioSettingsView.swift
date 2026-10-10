import ConceptCore
import SwiftUI

struct StudioSettingsView: View {
    @Bindable var session: StudioSession
    @State private var account = "openrouter"
    @State private var enteredKey = ""
    @State private var keyStatuses: [String: Bool] = [:]
    @State private var status = ""
    @State private var testing = false

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
            }.padding(24)
            Form {
                ChatGPTSettingsSection(session: session)
                Section("One gateway account is enough to start") {
                    Text("A gateway gives you several captioning models through one account. "
                        + "An account key lets this app use that service. ConceptStudio sells no credits.")
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Account", selection: $account) {
                        Section("Gateways") {
                            ForEach(gateways, id: \.self) { Text(title($0)).tag($0) }
                        }
                        Section("Direct providers and training") {
                            ForEach(advanced, id: \.self) { Text(title($0)).tag($0) }
                        }
                    }
                    if let url = accountKeyURL {
                        Link("Get a key from \(title(account))", destination: url)
                    }
                    SecureField("Paste account key", text: $enteredKey)
                        .help("Saved in your Mac's Keychain, never in the project.")
                    Text("Keys are saved in your Mac’s Keychain and never included in a project upload.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    HStack {
                        Button("Save in Keychain") { save() }.buttonStyle(.borderedProminent)
                            .tint(StudioStyle.actionTint)
                            .disabled(session.demoMode || enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty)
                        Button("Remove saved key") { remove() }
                            .disabled(session.demoMode || keyStatuses[account] != true)
                        Spacer()
                        Text(keyStatus(account)).font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                }
                Section("Test your captioning connection") {
                    LabeledContent("Account", value: ModelChoices.title(session.endpointKind))
                    LabeledContent("Model", value: session.modelName)
                        .textSelection(.enabled)
                    if session.endpointKind == "openai" {
                        LabeledContent("Uses", value: session.openAIUsesChatGPT ? "ChatGPT plan" : "OpenAI API credits")
                    }
                    Text(
                        "Tests the choices on Captioning, shown above. Live tests use the selected account’s allowance."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    HStack {
                        Button(testing ? "Testing connection…" : "Test captioning connection") { test() }
                            .disabled(session.busy)
                        if testing {
                            ProgressView().controlSize(.small)
                            Button("Cancel test") { session.cancel() }
                        }
                    }
                }
                DisclosureGroup("Saved accounts") {
                    ForEach(gateways + advanced, id: \.self) { kind in
                        LabeledContent(title(kind), value: keyStatus(kind))
                    }
                }
                DisclosureGroup("Advanced: custom servers and training images") {
                    TextField("User-configured vLLM server URL", text: $session.customBaseURL)
                    Text("The vLLM key goes only to this host. A downloaded job cannot redirect it.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    TextField("Custom training image (optional)", text: $session.podImageName)
                    TextField("Existing RunPod network volume ID (optional)", text: $session.volumeID)
                    Text(
                        "The training image is chosen automatically. "
                            + "Clear and save an override to restore the included image."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    Button("Save preferences") {
                        session.rememberChoices(); session.configureGPU(); status = "Preferences saved."
                    }.disabled(session.demoMode)
                }
                Section("Try every step for free") {
                    Text(session.demoMode ? "Demo is on. No saved keys or network connections are used." :
                        "The offline demo walks through the whole journey without an account or spending.")
                    Button("Try the offline demo") { session.useDemo() }
                        .disabled(session.busy || session.gpu.hasRunningPod || session.gpu.isBusy)
                    Text("Open or create a real project to leave demo mode.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }.formStyle(.grouped)
            if !status.isEmpty {
                Text(status).font(.callout).textSelection(.enabled)
                    .padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .tint(StudioStyle.accent)
        .frame(width: 700, height: 680)
        .onAppear { reload() }
        .task(id: session.demoMode) {
            if !session.demoMode { await session.chatGPT.load() }
        }
        .alert("You’re using your ChatGPT plan", isPresented: $session.showChatGPTPlanNotice) {
            Button("Got it") { session.acknowledgeChatGPTPlan() }
        } message: {
            Text("Eligible OpenAI requests in ConceptStudio count toward your ChatGPT plan or credits balance. "
                + "Use Manage usage to review your allowance and set an app limit in ChatGPT settings.")
        }
        .onChange(of: account) { _, _ in enteredKey = "" }
        .onChange(of: session.demoMode) { _, _ in
            if testing { session.cancel() }
            session.chatGPT.cancelSignIn()
            enteredKey = ""; reload()
        }
        .onDisappear {
            if testing { session.cancel() }
            session.chatGPT.cancelSignIn()
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
        default: ModelChoices.title(kind)
        }
    }

    private func reload() {
        guard !session.demoMode else { keyStatuses = [:]; return }
        do {
            for account in gateways +
                advanced {
                keyStatuses[account] = try session.keyStore.read(account)?.isEmpty == false
            }
        } catch { status = StudioSession.describe(error) }
    }

    private func save() {
        do {
            try session.keyStore.save(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            enteredKey = ""; reload(); status = "Key saved in your Mac's Keychain."
            session.configureGPU()
        } catch { status = StudioSession.describe(error) }
    }

    private func remove() {
        do {
            try session.keyStore.save("", account: account)
            reload()
            status = "Saved key removed."
        } catch {
            status = StudioSession.describe(error)
        }
    }

    private func test() {
        testing = true
        session.perform("Testing captioning connection…") {
            defer { testing = false }
            do {
                if session.demoMode { status = "Demo connection works locally; no key or network used."; return }
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
                status = "Connection succeeded."
            } catch is CancellationError {
                status = "Test cancelled."
            } catch {
                status = StudioSession.describe(error)
            }
        }
    }
}
