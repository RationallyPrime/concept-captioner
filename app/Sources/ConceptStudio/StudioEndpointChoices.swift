import ConceptCore
import Foundation

/// The captioning providers the app offers, in menu order, with their display names and default
/// models. Views list providers from here; nothing else hard-codes provider vocabulary.
enum ProviderChoices {
    struct Provider: Equatable, Identifiable {
        let kind: String
        let title: String
        let defaultModel: String
        var id: String {
            kind
        }
    }

    static let all: [Provider] = [
        Provider(kind: "openrouter", title: "OpenRouter gateway", defaultModel: "google/gemini-3.8-flash"),
        Provider(kind: "vercel", title: "Vercel AI Gateway", defaultModel: "google/gemini-3.8-flash"),
        Provider(kind: "gateway/anthropic", title: "Pydantic AI Gateway", defaultModel: "claude-sonnet-4-6"),
        Provider(kind: "google", title: "Google Gemini", defaultModel: "gemini-3.8-flash"),
        Provider(kind: "anthropic", title: "Anthropic Claude", defaultModel: "claude-sonnet-4-6"),
        Provider(kind: "openai", title: "OpenAI", defaultModel: "gpt-5.2"),
        Provider(kind: "vllm", title: "My pod / custom server", defaultModel: "Qwen/Qwen3-VL-8B-Instruct"),
    ]

    /// The provider a fresh install starts with.
    static let defaultKind = "openrouter"

    static var kinds: [String] {
        all.map(\.kind)
    }

    static func title(_ kind: String) -> String {
        all.first { $0.kind == kind }?.title ?? kind
    }

    static func defaultModel(for kind: String) -> String {
        all.first { $0.kind == kind }?.defaultModel ?? ""
    }
}

@MainActor
extension StudioSession {
    static let defaultPodImageName =
        "ghcr.io/rationallyprime/concept-captioner-pod-{trainer}:v0.2.3-clean-20261011"

    var vllmTargetURL: String {
        requestBaseURL.isEmpty ? customBaseURL : requestBaseURL
    }

    var criticTargetURL: String {
        criticRequestBaseURL.isEmpty ? customBaseURL : criticRequestBaseURL
    }

    func loadSavedChoices() {
        endpointKind = preferences.string(forKey: "endpointKind") ?? ProviderChoices.defaultKind
        modelName = preferences.string(forKey: "modelName") ?? ProviderChoices.defaultModel(for: endpointKind)
        openAIUsesChatGPT = preferences.bool(forKey: "openAIUsesChatGPT")
        criticKind = endpointKind
        criticModel = modelName
        customBaseURL = preferences.string(forKey: "vllmBaseURL") ?? ""
        podImageName = preferences.string(forKey: "podImage") ?? ""
        volumeID = preferences.string(forKey: "volumeID") ?? ""
        requestBaseURL = ""
        criticRequestBaseURL = ""
        usingPodCaptioner = false
        useCritic = false
    }

    /// The default model for `kind` as this session sees it: a running caption server's model for vllm.
    func defaultModel(for kind: String) -> String {
        kind == "vllm" && usingPodCaptioner ? gpu.captionModel : ProviderChoices.defaultModel(for: kind)
    }

    /// Call when the captioning provider changes from `old` to `new` (views: `.onChange(of:)`).
    /// A model the user typed is kept. With ChatGPT sign-in, OpenAI models come from the account.
    func providerChanged(from old: String, to new: String) {
        guard old != new else { return }
        if new == "openai", openAIUsesChatGPT {
            modelName = chatGPT.availableModels.first?.slug ?? ""
            return
        }
        modelName = defaultModel(for: new)
    }

    /// Call when the reviewer's provider changes, like `providerChanged(from:to:)`.
    func criticProviderChanged(from old: String, to new: String) {
        guard old != new else { return }
        if new == "openai", openAIUsesChatGPT {
            criticModel = chatGPT.availableModels.first?.slug ?? ""
            return
        }
        criticModel = defaultModel(for: new)
    }

    func applyJobChoices(_ job: Job) {
        if let endpoint = job.endpoints {
            endpointKind = endpoint.captioner.kind
            modelName = endpoint.captioner.model
            requestBaseURL = endpoint.captioner.baseURL ?? ""
            criticRequestBaseURL = endpoint.critic?.baseURL ?? ""
            outputMode = endpoint.captioner.outputMode
            concurrency = endpoint.captioner.concurrency
            useCritic = endpoint.critic != nil
            criticKind = endpoint.critic?.kind ?? endpointKind
            criticModel = endpoint.critic?.model ?? modelName
        }
        modelThinking = job.captionerThinking
        criticThinking = job.criticThinking
    }

    func endpoint(
        model: String? = nil,
        kind: String? = nil,
        settings: JSONObject? = nil,
        thinking: ThinkingLevel? = nil,
        baseURL: String? = nil,
        keys: (any KeyStore)? = nil,
        transport: any HTTPTransport = URLSessionTransport(),
        streamingTransport: any HTTPStreamingTransport = URLSessionTransport()
    ) throws -> ResolvedEndpoint {
        if demoMode { return ResolvedEndpoint(client: DemoModelClient(scenario: scenario)) }
        let selectedKind = kind ?? endpointKind
        let targetURL = baseURL ?? vllmTargetURL
        let spec = try EndpointSpec(
            kind: selectedKind,
            model: model ?? modelName,
            baseURL: selectedKind == "vllm" ? targetURL : nil,
            outputMode: outputMode,
            settings: settings ?? project?.job.endpoints?.captioner.settings ?? [:],
            concurrency: concurrency
        )
        if selectedKind == "openai", openAIUsesChatGPT {
            let requestSettings = try RequestSettings(settings: spec.settings, thinking: thinking ?? modelThinking)
            try ChatGPTModelClient.validate(settings: requestSettings, outputMode: spec.outputMode)
            guard let account = chatGPT.selectedAccount, account.isSignedIn, account.hasPlanPermission else {
                throw StudioError
                    .message("Log in with ChatGPT in Settings and allow use of your plan before captioning.")
            }
            guard chatGPT.availableModels.contains(where: { $0.slug == spec.model }) else {
                throw StudioError.message("Refresh the ChatGPT models on Captioning and choose one for this account.")
            }
            return ResolvedEndpoint(
                client: ChatGPTModelClient(
                    model: spec.model,
                    accessToken: chatGPT.tokenProvider(accountID: account.id),
                    onUsageLimit: { [weak self] error in
                        await self?.stopForChatGPTUsageLimit(error)
                    },
                    transport: streamingTransport
                ),
                settings: requestSettings,
                outputMode: spec.outputMode,
                requested: spec.model,
                concurrency: spec.concurrency
            )
        }
        if selectedKind == "vllm", usingPodCaptioner {
            guard let trustedURL = gpu.captionEndpoint,
                  !gpu.agentToken.isEmpty else {
                throw StudioError
                    .message("Your captioning computer is stopped or changed. Start its caption server again.")
            }
            return try Endpoints.resolve(
                spec,
                thinking: thinking ?? modelThinking,
                keys: StaticKeyStore(
                    [.vllm: gpu.agentToken],
                    vllmBaseURL: trustedURL.absoluteString
                ),
                transport: transport
            )
        }
        return try Endpoints.resolve(
            spec,
            thinking: thinking ?? modelThinking,
            keys: keys ?? keyStore,
            transport: transport
        )
    }

    /// The project's job with the current model choices, as job.yaml should store them. The caller
    /// writes it only when it differs from the saved job. A rented computer's caption server is
    /// temporary, so its URL is never stored: while it is in use the stored captioner stays as it was.
    func jobForCaptioning() throws -> Job {
        guard var job = project?.job else { throw StudioError.message("Open a project first.") }
        if !demoMode {
            let captioner = try usingPodCaptioner && endpointKind == "vllm"
                ? job.endpoints?.captioner ?? EndpointSpec(
                    kind: endpointKind, model: modelName, outputMode: outputMode, concurrency: concurrency
                )
                : EndpointSpec(
                    kind: endpointKind,
                    model: modelName,
                    baseURL: endpointKind == "vllm" ? vllmTargetURL : nil,
                    outputMode: outputMode,
                    settings: job.endpoints?.captioner.settings ?? [:],
                    concurrency: concurrency
                )
            let critic = useCritic ? try EndpointSpec(
                kind: criticKind,
                model: criticModel,
                baseURL: criticKind == "vllm" ? criticTargetURL : nil,
                settings: job.endpoints?.critic?.settings ?? [:]
            ) : nil
            job.endpoints = Endpoints(captioner: captioner, critic: critic)
        }
        job.captionerThinking = modelThinking
        job.criticThinking = criticThinking
        return job
    }
}

@MainActor
extension StudioSession {
    // MARK: Rented computer

    func useCurrentTrainingDataset() {
        gpu.repeatSourceRunID = ""
        updateTrainingProjectDefaults(preservingTrainer: true)
    }

    func updateTrainingProjectDefaults(preservingTrainer: Bool = false) {
        guard gpu.repeatSourceRunID.isEmpty else { return }
        gpu.triggerWords = project?.job.triggers.joined(separator: ",") ?? ""
        gpu.profile = project?.job.profile ?? "flux-image"
        gpu.datasetRevision = projectState.datasetRevision
        gpu.datasetContainsVideo = project?.images.contains { Sources.isVideo(Sources.suffix(of: $0.id)) } ?? false
        if !preservingTrainer, !gpu.hasRunningPod, !gpu.hasNativeRecipe,
           ["black-forest-labs/FLUX.1-dev", "Lightricks/LTX-2"].contains(gpu.baseModel) {
            gpu.trainer = gpu.profile.hasPrefix("ltx-") ? "ltx" : "aitoolkit"
            if gpu.profile.hasPrefix("h3-") { gpu.baseModel = GPUWorkspace.h3BaseModel }
        }
    }

    func configureGPU() {
        updateTrainingProjectDefaults()
        guard !demoMode else { return }
        do {
            try gpu.configure(
                runpodKey: keyStore.read("runpod") ?? "",
                hubToken: keyStore.read("huggingface") ?? "",
                imageName: podImageName,
                networkVolumeID: volumeID.isEmpty ? nil : volumeID
            )
        } catch { errorMessage = Self.describe(error) }
    }
}
