import ConceptCore
import Foundation

@MainActor
extension StudioSession {
    var vllmTargetURL: String {
        requestBaseURL.isEmpty ? customBaseURL : requestBaseURL
    }

    var criticTargetURL: String {
        criticRequestBaseURL.isEmpty ? customBaseURL : criticRequestBaseURL
    }

    func loadSavedChoices() {
        endpointKind = preferences.string(forKey: "endpointKind") ?? "openrouter"
        modelName = preferences.string(forKey: "modelName") ?? "google/gemini-3.8-flash"
        criticKind = endpointKind
        criticModel = modelName
        customBaseURL = preferences.string(forKey: "vllmBaseURL") ?? ""
        repoID = preferences.string(forKey: "hubRepo") ?? ""
        podImageName = preferences.string(forKey: "podImage") ?? ""
        volumeID = preferences.string(forKey: "volumeID") ?? ""
        requestBaseURL = ""
        criticRequestBaseURL = ""
        usingPodCaptioner = false
        useCritic = false
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
        transport: any HTTPTransport = URLSessionTransport()
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

    func jobForCaptioning() throws -> Job {
        guard var job = project?.job else { throw StudioError.message("Open a project first.") }
        if !demoMode {
            let captioner = try EndpointSpec(
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
