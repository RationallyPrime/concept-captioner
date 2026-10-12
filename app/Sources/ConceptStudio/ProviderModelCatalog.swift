import ConceptCore
import Foundation

struct ProviderModelChoice: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    /// nil means the provider did not report input modalities for this model.
    let inputModalities: Set<String>?
    /// Some providers report one capability at a time; others return the complete supported-input list.
    let inputModalitiesAreComplete: Bool
    /// nil means the provider did not classify this model type.
    let modelType: String?

    init(
        id: String,
        displayName: String,
        inputModalities: Set<String>?,
        inputModalitiesAreComplete: Bool = true,
        modelType: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.inputModalities = inputModalities
        self.inputModalitiesAreComplete = inputModalitiesAreComplete
        self.modelType = modelType
    }
}

enum ProviderModelCatalogError: Error, LocalizedError {
    case missingKey(String)
    case invalidKey(String)
    case requestFailed(String, Int)
    case unreachable(String)
    case unreadableModels(String)
    case missingServerURL
    case unsupportedCatalog(String)

    var errorDescription: String? {
        switch self {
        case let .missingKey(provider): "Add your \(provider) key in Settings, then refresh models."
        case let .invalidKey(provider): "\(provider) did not accept this key. Check it or save another key in Settings."
        case let .requestFailed(provider, status):
            "\(provider) could not check the account (HTTP \(status)). Check the service settings and try again."
        case let .unreachable(provider):
            "\(provider) could not be reached. Check your connection and try again."
        case let .unreadableModels(provider):
            "\(provider) returned an unreadable model list. Try again or enter a model identifier."
        case .missingServerURL: "Add the custom server URL in Settings to check this key and list its models."
        case let .unsupportedCatalog(provider):
            "\(provider) does not provide a model list here. Enter a model identifier instead."
        }
    }
}

enum ProviderModelCatalog {
    private static let nonLanguageModelTypes: Set<String> = ["audio", "embedding", "image", "video"]

    /// Name parts of OpenAI models that cannot caption an image: embeddings, speech, transcription,
    /// image or video generation, moderation, realtime/audio-only, search previews and legacy completions.
    /// OpenAI's list reports no input types, so this filter is name-based and deliberately conservative;
    /// "Other model…" still accepts any identifier.
    private static let openAINonVisionParts: Set<String> = [
        "embedding", "tts", "whisper", "transcribe", "moderation", "realtime", "audio", "search",
        "dall", "sora", "babbage", "davinci",
    ]

    static func mayAcceptImages(openAIModel id: String) -> Bool {
        let name = id.lowercased()
        let parts = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return parts.isDisjoint(with: openAINonVisionParts) && !name.contains("gpt-image")
    }

    static func forCaptioning(_ models: [ProviderModelChoice], includesVideo: Bool) -> [ProviderModelChoice] {
        models.filter { model in
            if let type = model.modelType?.lowercased(), nonLanguageModelTypes.contains(type) {
                return false
            }
            guard let modalities = model.inputModalities else { return true }
            guard modalities.contains("image") else { return false }
            return !includesVideo || !model.inputModalitiesAreComplete || modalities.contains("video")
        }
    }

    static func list(
        for kind: String,
        apiKey: String?,
        baseURL: String? = nil,
        trustedBaseURL: String? = nil,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> [ProviderModelChoice] {
        let providerName = ProviderChoices.title(kind)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard kind == "vllm" || !key.isEmpty else { throw ProviderModelCatalogError.missingKey(providerName) }

        switch kind {
        case "openai":
            return try await openAIModels(
                at: URL(string: "https://api.openai.com/v1/models")!,
                key: key,
                provider: providerName,
                transport: transport
            ).filter { mayAcceptImages(openAIModel: $0.id) }
        case "anthropic":
            return try await anthropicModels(
                at: URL(string: "https://api.anthropic.com/v1/models")!,
                key: key,
                provider: providerName,
                bearer: false,
                transport: transport
            )
        case "google":
            return try await geminiModels(key: key, transport: transport)
        case "openrouter":
            return try await openRouterModels(key: key, transport: transport)
        case "vercel":
            return try await vercelModels(key: key, transport: transport)
        case "gateway/anthropic":
            let base = try Endpoints.gatewayProxyBaseURL(for: key)
            return try await anthropicModels(
                at: base.appendingPathComponent("anthropic").appendingPathComponent("v1")
                    .appendingPathComponent("models"),
                key: key,
                provider: providerName,
                bearer: true,
                transport: transport
            )
        case "vllm":
            guard let baseURL, !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderModelCatalogError.missingServerURL
            }
            let spec = try EndpointSpec(kind: "vllm", model: "model-catalog", baseURL: baseURL)
            _ = try Endpoints.resolve(
                spec,
                keys: StaticKeyStore([.vllm: key], vllmBaseURL: trustedBaseURL),
                transport: transport
            )
            guard let base = URL(string: baseURL) else { throw ProviderModelCatalogError.missingServerURL }
            let catalogKey = try Endpoints.vllmCredentialMatchesTarget(
                targetURL: baseURL,
                configuredBaseURL: trustedBaseURL
            ) ? key : ""
            return try await openAIModels(
                at: base.appendingPathComponent("models"),
                key: catalogKey,
                provider: providerName,
                transport: transport
            )
        default:
            throw ProviderModelCatalogError.unsupportedCatalog(providerName)
        }
    }

    private static func openAIModels(
        at url: URL,
        key: String,
        provider: String,
        transport: any HTTPTransport
    ) async throws -> [ProviderModelChoice] {
        var request = URLRequest(url: url)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data = try await responseData(request, provider: provider, transport: transport)
        guard let response = try? JSONDecoder().decode(
            ProviderCatalogModelEnvelope<ProviderCatalogOpenAIModel>.self,
            from: data
        ) else {
            throw ProviderModelCatalogError.unreadableModels(provider)
        }
        return response.data.map {
            ProviderModelChoice(id: $0.id, displayName: $0.name ?? $0.id, inputModalities: $0.inputModalities)
        }
    }

    private static func anthropicModels(
        at url: URL,
        key: String,
        provider: String,
        bearer: Bool,
        transport: any HTTPTransport
    ) async throws -> [ProviderModelChoice] {
        var afterID: String?
        var models: [ProviderModelChoice] = []
        repeat {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { components.queryItems?.append(URLQueryItem(name: "after_id", value: afterID)) }
            var request = URLRequest(url: components.url!)
            request.setValue(bearer ? "Bearer \(key)" : key, forHTTPHeaderField: bearer ? "Authorization" : "x-api-key")
            request.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
            let data = try await responseData(request, provider: provider, transport: transport)
            guard let response = try? JSONDecoder().decode(
                ProviderCatalogModelEnvelope<ProviderCatalogAnthropicModel>.self,
                from: data
            ) else {
                throw ProviderModelCatalogError.unreadableModels(provider)
            }
            models.append(contentsOf: response.data.map { model in
                let imageSupport = model.capabilities?.imageInput?.supported
                let modalities = imageSupport.map { $0 ? Set(["image"]) : Set<String>() }
                return ProviderModelChoice(
                    id: model.id,
                    displayName: model.displayName ?? model.id,
                    inputModalities: modalities,
                    inputModalitiesAreComplete: false
                )
            })
            afterID = response.hasMore == true ? response.lastID : nil
        } while afterID != nil
        return models
    }

    private static func geminiModels(key: String, transport: any HTTPTransport) async throws -> [ProviderModelChoice] {
        var pageToken: String?
        var models: [ProviderModelChoice] = []
        repeat {
            var components = URLComponents(
                url: GeminiClient.defaultBaseURL.appendingPathComponent("models"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let data = try await responseData(request, provider: "Google Gemini", transport: transport)
            guard let response = try? JSONDecoder().decode(ProviderCatalogGeminiModelEnvelope.self, from: data) else {
                throw ProviderModelCatalogError.unreadableModels("Google Gemini")
            }
            models.append(contentsOf: response.models.compactMap { model in
                guard model.supportedGenerationMethods?.contains("generateContent") != false else { return nil }
                let name = model.name ?? model.baseModelID ?? ""
                let id = GeminiClient.normalizedModel(name)
                guard !id.isEmpty else { return nil }
                return ProviderModelChoice(id: id, displayName: model.displayName ?? id, inputModalities: nil)
            })
            pageToken = response.nextPageToken
        } while pageToken != nil
        return models
    }

    private static func openRouterModels(
        key: String,
        transport: any HTTPTransport
    ) async throws -> [ProviderModelChoice] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try await responseData(request, provider: "OpenRouter", transport: transport)
        guard let response = try? JSONDecoder().decode(
            ProviderCatalogModelEnvelope<ProviderCatalogOpenRouterModel>.self,
            from: data
        ) else {
            throw ProviderModelCatalogError.unreadableModels("OpenRouter")
        }
        return response.data.map {
            ProviderModelChoice(
                id: $0.id,
                displayName: $0.name ?? $0.id,
                inputModalities: $0.architecture?.inputModalities
            )
        }
    }

    private static func vercelModels(key: String, transport: any HTTPTransport) async throws -> [ProviderModelChoice] {
        let url = URL(string: "https://ai-gateway.vercel.sh/v1/models")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try await responseData(request, provider: "Vercel AI Gateway", transport: transport)
        guard let response = try? JSONDecoder().decode(
            ProviderCatalogModelEnvelope<ProviderCatalogVercelModel>.self,
            from: data
        ) else {
            throw ProviderModelCatalogError.unreadableModels("Vercel AI Gateway")
        }
        return response.data.map { model in
            ProviderModelChoice(
                id: model.id,
                displayName: model.name ?? model.id,
                inputModalities: model.modalities?.input,
                modelType: model.type
            )
        }
    }

    private static func responseData(
        _ request: URLRequest,
        provider: String,
        transport: any HTTPTransport
    ) async throws -> Data {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderModelCatalogError.unreachable(provider)
        }
        try Task.checkCancellation()
        guard (200 ..< 300).contains(response.status) else {
            if response.status == 401 || response.status == 403 {
                throw ProviderModelCatalogError.invalidKey(provider)
            }
            throw ProviderModelCatalogError.requestFailed(provider, response.status)
        }
        return response.body
    }
}

private struct ProviderCatalogModelEnvelope<Model: Decodable>: Decodable {
    let data: [Model]
    let hasMore: Bool?
    let lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

private struct ProviderCatalogOpenAIModel: Decodable {
    let id: String
    let name: String?
    let inputModalities: Set<String>?

    enum CodingKeys: String, CodingKey {
        case id, name
        case inputModalities = "input_modalities"
    }
}

private struct ProviderCatalogAnthropicModel: Decodable {
    let id: String
    let displayName: String?
    let capabilities: ProviderCatalogAnthropicCapabilities?

    enum CodingKeys: String, CodingKey {
        case id, capabilities
        case displayName = "display_name"
    }
}

private struct ProviderCatalogAnthropicCapabilities: Decodable {
    let imageInput: ProviderCatalogAnthropicCapability?

    enum CodingKeys: String, CodingKey {
        case imageInput = "image_input"
    }
}

private struct ProviderCatalogAnthropicCapability: Decodable {
    let supported: Bool?
}

private struct ProviderCatalogGeminiModelEnvelope: Decodable {
    let models: [ProviderCatalogGeminiModel]
    let nextPageToken: String?
}

private struct ProviderCatalogGeminiModel: Decodable {
    let name: String?
    let baseModelID: String?
    let displayName: String?
    let supportedGenerationMethods: [String]?

    enum CodingKeys: String, CodingKey {
        case name, displayName
        case baseModelID = "baseModelId"
        case supportedGenerationMethods
    }
}

private struct ProviderCatalogOpenRouterModel: Decodable {
    let id: String
    let name: String?
    let architecture: ProviderCatalogOpenRouterArchitecture?
}

private struct ProviderCatalogOpenRouterArchitecture: Decodable {
    let inputModalities: Set<String>?

    enum CodingKeys: String, CodingKey {
        case inputModalities = "input_modalities"
    }
}

private struct ProviderCatalogVercelModel: Decodable {
    let id: String
    let name: String?
    let type: String?
    let modalities: ProviderCatalogVercelModalities?
}

private struct ProviderCatalogVercelModalities: Decodable {
    let input: Set<String>?
}
