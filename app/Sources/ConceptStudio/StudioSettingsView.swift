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
        Form {
            Section("One gateway key is enough to start") {
                Text(
                    "Bring an account you already hold. A gateway gives access to many models with one key. "
                        + "ConceptStudio sells no credits."
                )
                ForEach(gateways, id: \.self) { kind in
                    LabeledContent(
                        title(kind),
                        value: keyStatus(kind)
                    )
                }
            }
            Section("Save an account key") {
                Picker("Account", selection: $account) {
                    ForEach(gateways + advanced, id: \.self) { Text(title($0)).tag($0) }
                }
                SecureField("Paste key (never stored in the project)", text: $enteredKey)
                HStack {
                    Button("Save in Keychain") { save() }.disabled(session.demoMode || enteredKey.isEmpty)
                    Button("Remove saved key") { remove() }.disabled(session.demoMode || keyStatuses[account] != true)
                    Button("Test captioning connection") { test() }.disabled(session.busy)
                    if testing { Button("Cancel test") { session.cancel() } }
                }
                Text(
                    "The connection test uses the account and model selected on Captioning. "
                        + "Live tests may use provider credits."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced: direct providers, Hub and GPU accounts") {
                ForEach(advanced, id: \.self) { kind in
                    LabeledContent(
                        title(kind),
                        value: session.demoMode ? "Demo — no key used" : keyStatuses[kind] == true ? "Saved" : "Not set"
                    )
                }
                TextField("User-configured vLLM server URL", text: $session.customBaseURL)
                Text("The vLLM key goes only to this host. A downloaded job cannot redirect it.").font(.caption)
                TextField("Project GPU container image", text: $session.podImageName)
                TextField("Existing RunPod network volume ID (optional)", text: $session.volumeID)
                Text("Choose a verified ConceptStudio image before renting. Training images need CUDA 13 or newer.")
                    .font(.caption)
                Button("Save preferences") {
                    session.rememberChoices(); session.configureGPU(); status = "Preferences saved."
                }
                .disabled(session.demoMode)
            }
            Section("Demo mode") {
                Text(session
                    .demoMode ? "Demo is on. No Keychain or network is used." :
                    "Demo walks the full journey without an account or spending.")
                Button("Try the offline demo") { session.useDemo() }
                    .disabled(session.busy || session.gpu.hasRunningPod || session.gpu.isBusy)
                Text("Open or create a real project to leave demo mode.").font(.caption)
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped).padding(16).frame(width: 650, height: 680)
        .onAppear { reload() }
        .onChange(of: session.demoMode) { _, _ in
            if testing { session.cancel() }
            enteredKey = ""; reload()
        }
        .onDisappear { if testing { session.cancel() } }
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
