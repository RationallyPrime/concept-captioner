import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor ProviderSettingsWire: HTTPTransport {
    private var response: HTTPResponse
    private let cancels: Bool
    private(set) var requests: [URLRequest] = []

    init(_ response: HTTPResponse, cancels: Bool = false) {
        self.response = response
        self.cancels = cancels
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if cancels { throw CancellationError() }
        return response
    }
}

@Suite("provider model catalogs and account checks")
struct ProviderSettingsTests {
    @Test func openRouterCatalogUsesItsReadOnlyModelRouteAndDeclaredCapabilities() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"""
        {"data":[
          {"id":"text-only","name":"Text only","architecture":{"input_modalities":["text"]}},
          {"id":"image-only","name":"Image only","architecture":{"input_modalities":["text","image"]}},
          {"id":"image-video","name":"Image and video","architecture":{"input_modalities":["text","image","video"]}},
          {"id":"unknown-capability","name":"Unknown"}
        ]}
        """#.utf8)))

        let models = try await ProviderModelCatalog.list(for: "openrouter", apiKey: "fixture-key", transport: wire)
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect((request.httpMethod ?? "GET") == "GET")
        #expect(ProviderModelCatalog.forCaptioning(models, includesVideo: false).map(\.id) == [
            "image-only", "image-video", "unknown-capability",
        ])
        #expect(ProviderModelCatalog.forCaptioning(models, includesVideo: true).map(\.id) == [
            "image-video", "unknown-capability",
        ])
    }

    @Test func anthropicFiltersOnlyTheCapabilityThatItsMetadataReports() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"""
        {"data":[
          {"id":"image-model","display_name":"Image model","capabilities":{"image_input":{"supported":true}}},
          {"id":"text-model","capabilities":{"image_input":{"supported":false}}},
          {"id":"unknown-model"}
        ],"has_more":false,"last_id":null}
        """#.utf8)))

        let models = try await ProviderModelCatalog.list(for: "anthropic", apiKey: "fixture-key", transport: wire)
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicClient.apiVersion)
        #expect(ProviderModelCatalog.forCaptioning(models, includesVideo: true).map(\.id) == [
            "image-model", "unknown-model",
        ])
    }

    @Test func openAIListDropsModelsThatCannotTakeImages() async throws {
        let ids = [
            "gpt-5.2", "gpt-4o", "o4-mini", "text-embedding-3-small", "tts-1-hd", "gpt-4o-mini-tts", "whisper-1",
            "gpt-4o-transcribe", "dall-e-3", "gpt-image-1", "omni-moderation-latest", "gpt-realtime",
            "gpt-4o-audio-preview", "gpt-4o-search-preview", "sora-2", "babbage-002", "davinci-002",
        ]
        let body = #"{"data":["# + ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",") + "]}"
        let wire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(body.utf8)))
        let models = try await ProviderModelCatalog.list(for: "openai", apiKey: "fixture-key", transport: wire)
        #expect(models.map(\.id) == ["gpt-5.2", "gpt-4o", "o4-mini"])
    }

    @Test func directOpenAIModelListUsesTheSavedAccountKeyWithoutGenerating() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"{"data":[{"id":"gpt-fixture"}]}"#.utf8)))
        let models = try await ProviderModelCatalog.list(for: "openai", apiKey: "fixture-key", transport: wire)
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect((request.httpMethod ?? "GET") == "GET")
        #expect(models.map(\.id) == ["gpt-fixture"])
    }

    @Test func googleCatalogRemovesTheResourcePrefixAndKeepsUnknownInputTypes() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"""
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini Flash",
           "supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding","supportedGenerationMethods":["embedContent"]}
        ]}
        """#.utf8)))

        let models = try await ProviderModelCatalog.list(for: "google", apiKey: "fixture-key", transport: wire)
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-key")
        #expect(models.map(\.id) == ["gemini-2.5-flash"])
        #expect(ProviderModelCatalog.forCaptioning(models, includesVideo: true).map(\.id) == ["gemini-2.5-flash"])
    }

    @Test func vercelCatalogReadsDeclaredModalitiesAndExcludesNonLanguageTypes() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"""
        {"data":[
          {"id":"text-only","type":"language","modalities":{"input":["text"],"output":["text"]}},
          {"id":"vision","type":"language","modalities":{"input":["text","image"],"output":["text"]}},
          {"id":"vision-video","type":"language","modalities":{"input":["text","image","video"],"output":["text"]}},
          {"id":"embedding","type":"embedding","modalities":{"input":["text"],"output":["embedding"]}},
          {"id":"image-generation","type":"image","modalities":{"input":["text","image"],"output":["image"]}},
          {"id":"video-generation","type":"video","modalities":{"input":["text","image","video"],"output":["video"]}},
          {"id":"unknown-type","type":"future","modalities":{"input":["text","image"],"output":["text"]}},
          {"id":"unknown-type-absent","modalities":{"input":["text","image"],"output":["text"]}}
        ]}
        """#.utf8)))

        let models = try await ProviderModelCatalog.list(for: "vercel", apiKey: "fixture-key", transport: wire)
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(ProviderModelCatalog.forCaptioning(models, includesVideo: false).map(\.id) == [
            "vision", "vision-video", "unknown-type", "unknown-type-absent",
        ])
        #expect(ProviderModelCatalog.forCaptioning(models, includesVideo: true).map(\.id) == [
            "vision-video",
        ])
    }

    @Test func gatewayCatalogsUseTheirConfiguredReadOnlyRoutes() async throws {
        let response = HTTPResponse(status: 200, body: Data(#"{"data":[{"id":"model"}]}"#.utf8))
        let vercel = ProviderSettingsWire(response)
        _ = try await ProviderModelCatalog.list(for: "vercel", apiKey: "fixture-key", transport: vercel)
        #expect(await (vercel.requests.first)?.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/models")

        let pydantic = ProviderSettingsWire(response)
        _ = try await ProviderModelCatalog.list(
            for: "gateway/anthropic", apiKey: "pylf_v1_eu_fixture", transport: pydantic
        )
        let request = try #require(await pydantic.requests.first)
        #expect(request.url?.host() == "gateway-eu.pydantic.dev")
        #expect(request.url?.path() == "/proxy/anthropic/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pylf_v1_eu_fixture")
    }

    @Test func customServerCatalogReusesTheEndpointTrustValidation() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(
            status: 200,
            body: Data(#"{"data":[{"id":"custom-model"}]}"#.utf8)
        ))
        _ = try await ProviderModelCatalog.list(
            for: "vllm", apiKey: "agent-token", baseURL: "http://127.0.0.1:8000/v1",
            trustedBaseURL: "http://127.0.0.1:8000/v1", transport: wire
        )
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8000/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer agent-token")

        await #expect(throws: ConfigurationError.self) {
            _ = try await ProviderModelCatalog.list(
                for: "vllm", apiKey: "agent-token", baseURL: "http://public.example/v1", transport: wire
            )
        }
        #expect(await wire.requests.count == 1)
    }

    @Test func customServerCatalogUsesOnlyTheCredentialForItsConfiguredOrigin() async throws {
        let sameOriginWire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"{"data":[]}"#.utf8)))
        _ = try await ProviderModelCatalog.list(
            for: "vllm",
            apiKey: "settings-key",
            baseURL: "http://127.0.0.1:8000/project/v1",
            trustedBaseURL: "http://127.0.0.1:8000/settings/v1",
            transport: sameOriginWire
        )
        #expect(await (sameOriginWire.requests.first)?
            .value(forHTTPHeaderField: "Authorization") == "Bearer settings-key")

        let crossOriginWire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"{"data":[]}"#.utf8)))
        _ = try await ProviderModelCatalog.list(
            for: "vllm",
            apiKey: "settings-key",
            baseURL: "http://127.0.0.2:8000/project/v1",
            trustedBaseURL: "http://127.0.0.1:8000/settings/v1",
            transport: crossOriginWire
        )
        #expect(await (crossOriginWire.requests.first)?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(await (crossOriginWire.requests.first)?.url?
            .absoluteString == "http://127.0.0.2:8000/project/v1/models")

        let noSettingsWire = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"{"data":[]}"#.utf8)))
        _ = try await ProviderModelCatalog.list(
            for: "vllm",
            apiKey: "settings-key",
            baseURL: "http://127.0.0.1:8000/project/v1",
            trustedBaseURL: nil,
            transport: noSettingsWire
        )
        #expect(await (noSettingsWire.requests.first)?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test @MainActor func projectServerWithNoSettingsOriginPublishesUnauthenticatedChoices() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let secrets = MemorySecretStore(["vllm": "settings-key"])
        let session = StudioSession(preferences: preferences.defaults, secrets: secrets)
        session.endpointKind = "vllm"
        session.requestBaseURL = "http://127.0.0.1:8000/project/v1"
        let wire = ProviderSettingsWire(HTTPResponse(
            status: 200,
            body: Data(#"{"data":[{"id":"project-model"}]}"#.utf8)
        ))

        let models = try await session.refreshProviderModels(for: "vllm", transport: wire)
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8000/project/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(models.map(\.id) == ["project-model"])
        #expect(session.providerModelChoices[session.providerModelCacheKey(for: "vllm")] == models)
    }

    @Test @MainActor func settingsKeyCheckSendsTheSavedKeyToTheSettingsServerOnly() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let secrets = MemorySecretStore(["vllm": "settings-key"])
        let session = StudioSession(preferences: preferences.defaults, secrets: secrets)
        session.endpointKind = "vllm"
        session.customBaseURL = "http://127.0.0.1:8000/settings/v1"
        session.requestBaseURL = "http://127.0.0.2:8000/project/v1"
        session.usingPodCaptioner = true
        let wire = ProviderSettingsWire(HTTPResponse(
            status: 200,
            body: Data(#"{"data":[{"id":"settings-model"}]}"#.utf8)
        ))

        let models = try await session.checkSavedProviderKey(for: "vllm", transport: wire)
        let request = try #require(await wire.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8000/settings/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer settings-key")
        #expect(models.map(\.id) == ["settings-model"])

        session.customBaseURL = ""
        await #expect(throws: ProviderModelCatalogError.self) {
            _ = try await session.checkSavedProviderKey(for: "vllm", transport: wire)
        }
    }

    @Test func accountChecksAreReadOnlyAndNeverReturnCredentialText() async throws {
        let hub = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"{"name":"fixture-user"}"#.utf8)))
        try await ProviderCredentialValidator.checkHuggingFace(token: "fixture-token", transport: hub)
        let hubRequest = try #require(await hub.requests.first)
        #expect(hubRequest.url?.host() == "huggingface.co")
        #expect(hubRequest.url?.path() == "/api/whoami-v2")
        #expect(hubRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect((hubRequest.httpMethod ?? "GET") == "GET")

        let runpod = ProviderSettingsWire(HTTPResponse(status: 200, body: Data(#"{"pods":[]}"#.utf8)))
        try await ProviderCredentialValidator.checkRunPod(key: "fixture-key", transport: runpod)
        let runpodRequest = try #require(await runpod.requests.first)
        #expect(runpodRequest.url?.absoluteString == "https://api.runpod.io/v2/pods?limit=1")
        #expect(runpodRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect((runpodRequest.httpMethod ?? "GET") == "GET")

        let rejected = ProviderSettingsWire(HTTPResponse(status: 401, body: Data("fixture-token".utf8)))
        var failure = ""
        do {
            try await ProviderCredentialValidator.checkHuggingFace(token: "fixture-token", transport: rejected)
        } catch {
            failure = error.localizedDescription
        }
        #expect(failure.contains("Hugging Face"))
        #expect(!failure.contains("fixture-token"))
    }

    @Test func catalogCancellationRemainsCancellation() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(status: 200), cancels: true)
        do {
            _ = try await ProviderModelCatalog.list(for: "openai", apiKey: "fixture-key", transport: wire)
            Issue.record("A cancelled catalog request returned models")
        } catch is CancellationError {
            #expect(await wire.requests.count == 1)
        }
    }

    @Test func rejectedCatalogKeyDoesNotEchoTheKeyOrProviderResponse() async throws {
        let wire = ProviderSettingsWire(HTTPResponse(status: 401, body: Data("fixture-key".utf8)))
        var failure = ""
        do {
            _ = try await ProviderModelCatalog.list(for: "openai", apiKey: "fixture-key", transport: wire)
        } catch {
            failure = error.localizedDescription
        }
        #expect(failure.contains("OpenAI"))
        #expect(!failure.contains("fixture-key"))
    }
}
