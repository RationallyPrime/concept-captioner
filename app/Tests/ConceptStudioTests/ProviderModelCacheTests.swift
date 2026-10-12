@testable import ConceptStudio
import Testing

@Suite("provider model cache identity")
@MainActor
struct ProviderModelCacheTests {
    @Test func vllmCacheSeparatesConfiguredTargetProjectTargetAndPodCredentials() {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.customBaseURL = "https://settings.example/v1"
        let settingsKey = session.providerModelCacheKey(for: "vllm")
        let settingsModels = [ProviderModelChoice(id: "settings", displayName: "Settings", inputModalities: nil)]
        session.providerModelChoices[settingsKey] = settingsModels

        session.requestBaseURL = "https://project.example/v1"
        let projectKey = session.providerModelCacheKey(for: "vllm")
        #expect(projectKey != settingsKey)
        #expect(session.providerModelChoices[projectKey] == nil)

        session.customBaseURL = "https://project.example/v1"
        let changedTrustKey = session.providerModelCacheKey(for: "vllm")
        #expect(changedTrustKey.targetURL == projectKey.targetURL)
        #expect(changedTrustKey.usesPodCaptioner == projectKey.usesPodCaptioner)
        #expect(changedTrustKey != projectKey)
        session.customBaseURL = "https://settings.example/v1"
        #expect(session.providerModelCacheKey(for: "vllm") == projectKey)

        session.usingPodCaptioner = true
        let podKey = session.providerModelCacheKey(for: "vllm")
        #expect(podKey != projectKey)

        session.requestBaseURL = ""
        session.usingPodCaptioner = false
        #expect(session.providerModelCacheKey(for: "vllm") == settingsKey)
        #expect(session.providerModelChoices[session.providerModelCacheKey(for: "vllm")] == settingsModels)
    }
}
