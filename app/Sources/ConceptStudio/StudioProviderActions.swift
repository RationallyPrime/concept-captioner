import ConceptCore
import Foundation

@MainActor
extension StudioSession {
    func refreshProviderModels(
        for requestedKind: String? = nil,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> [ProviderModelChoice] {
        guard !demoMode else { return [] }
        let kind = requestedKind ?? endpointKind
        let cacheKey = providerModelCacheKey(for: kind)
        let key: String
        let targetURL: String?
        let trustedBaseURL: String?
        let usesRunningPod = kind == "vllm" && usingPodCaptioner
        let account = kind.hasPrefix("gateway/") ? "gateway" : kind

        if usesRunningPod {
            guard let endpoint = gpu.captionEndpoint, !gpu.agentToken.isEmpty else {
                throw ProviderModelCatalogError.unreachable("your captioning computer")
            }
            key = gpu.agentToken
            targetURL = vllmTargetURL
            trustedBaseURL = endpoint.absoluteString
        } else {
            key = try secrets.read(account) ?? ""
            targetURL = kind == "vllm" ? vllmTargetURL : nil
            trustedBaseURL = kind == "vllm" && !customBaseURL.isEmpty ? customBaseURL : nil
        }

        let models = try await ProviderModelCatalog.list(
            for: kind,
            apiKey: key,
            baseURL: targetURL,
            trustedBaseURL: trustedBaseURL,
            transport: transport
        )
        try Task.checkCancellation()
        if usesRunningPod {
            guard usingPodCaptioner, gpu.captionEndpoint?.absoluteString == trustedBaseURL,
                  gpu.agentToken == key, providerModelCacheKey(for: kind) == cacheKey
            else {
                throw CancellationError()
            }
        } else {
            guard try (secrets.read(account) ?? "") == key,
                  kind != "vllm"
                  || (!usingPodCaptioner && providerModelCacheKey(for: kind) == cacheKey)
            else { throw CancellationError() }
        }
        providerModelChoices[cacheKey] = models
        return models
    }
}
