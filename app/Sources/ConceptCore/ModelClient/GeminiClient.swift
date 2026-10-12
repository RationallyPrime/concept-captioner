// Gemini generateContent over URLSession: responseMimeType application/json + responseJsonSchema,
// inlineData images or video targets, thinkingConfig.

import Foundation

public struct GeminiClient: ModelClient {
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    /// Which Gemini API serves the request. The two differ in some model capabilities (thinking
    /// levels of the image family); the request shape is the same.
    public enum API: Sendable {
        case developer
        case vertex
    }

    public let baseURL: URL
    public let apiKey: String
    public let requestedModel: String
    public let transport: any HTTPTransport
    /// Also send the key as bearer `Authorization` (Pydantic AI Gateway). Independent of `api`.
    public let bearerAuth: Bool
    public let api: API

    /// Google model resources use `models/<id>`; this client adds the resource prefix itself.
    public static func normalizedModel(_ model: String) -> String {
        model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
    }

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = defaultBaseURL,
        transport: any HTTPTransport = URLSessionTransport(),
        bearerAuth: Bool = false,
        api: API = .developer
    ) {
        self.apiKey = apiKey
        requestedModel = Self.normalizedModel(model)
        self.baseURL = baseURL
        self.transport = transport
        self.bearerAuth = bearerAuth
        self.api = api
    }

    public func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ModelReply {
        var headers = ["x-goog-api-key": apiKey]
        if bearerAuth { headers["Authorization"] = "Bearer \(apiKey)" }
        settings.mergeExtraHeaders(into: &headers)
        let body = requestBody(instructions: instructions, messages: messages, output: output, settings: settings)
        try MediaInput.checkVideoRequest(body, messages: messages)
        let envelope = try await ProviderHTTP.post(
            body,
            to: baseURL.appendingPathComponent("models/\(requestedModel):generateContent"),
            headers: headers,
            transport: transport
        )
        return try Self.parse(envelope, mode: output.mode)
    }

    // MARK: Request

    func requestBody(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) -> JSONObject {
        var body: JSONObject = [
            "systemInstruction": .object([
                "parts": .array([.object(["text": .string(output.instructions(instructions))])]),
            ]),
            "contents": .array(messages.map(Self.encode)),
        ]
        var generation = JSONObject()
        switch output.mode {
        case .native:
            generation["responseMimeType"] = .string("application/json")
            generation["responseJsonSchema"] = output.schema
        case .prompted:
            generation["responseMimeType"] = .string("application/json")
        case .tool:
            // parametersJsonSchema takes plain JSON Schema (type arrays, additionalProperties);
            // the older `parameters` field is an OpenAPI subset that rejects the strict schema.
            body["tools"] = .array([
                .object([
                    "functionDeclarations": .array([
                        .object([
                            "name": .string(output.name),
                            "description": .string(output.toolDescription),
                            "parametersJsonSchema": output.schema,
                        ]),
                    ]),
                ]),
            ])
            body["toolConfig"] = .object([
                "functionCallingConfig": .object([
                    "mode": .string("ANY"),
                    "allowedFunctionNames": .array([.string(output.name)]),
                ]),
            ])
        }
        if let thinking = thinkingConfig(settings) {
            generation["thinkingConfig"] = .object(thinking)
        }
        if let temperature = settings.temperature { generation["temperature"] = .double(temperature) }
        if let maxTokens = settings.maxTokens { generation["maxOutputTokens"] = .int(maxTokens) }
        if let topP = settings.topP { generation["topP"] = .double(topP) }
        if let topK = settings.topK { generation["topK"] = .int(topK) }
        if let seed = settings.seed { generation["seed"] = .int(seed) }
        if let stop = settings.stopSequencesJSON { generation["stopSequences"] = stop }
        if let penalty = settings.presencePenalty { generation["presencePenalty"] = .double(penalty) }
        if let penalty = settings.frequencyPenalty { generation["frequencyPenalty"] = .double(penalty) }
        if !generation.isEmpty {
            body["generationConfig"] = .object(generation)
        }
        settings.mergeExtraBody(into: &body)
        return body
    }

    private func thinkingConfig(_ settings: RequestSettings) -> JSONObject? {
        guard settings.thinks else { return nil }
        // Older non-thinking models do not accept thinkingConfig (pydantic-ai drops it).
        if requestedModel.contains("gemma") || requestedModel == "gemini-pro" || requestedModel.hasPrefix("gemini-1")
            || (requestedModel.hasPrefix("gemini-2.") && !requestedModel.hasPrefix("gemini-2.5")) {
            return nil
        }
        var config: JSONObject = ["includeThoughts": .bool(true)]
        guard let effort = settings.thinkingEffort else { return config }
        if requestedModel.hasPrefix("gemini-2.5") {
            let budget = switch effort {
            case .none, .minimal: 128
            case .low: 2048
            case .medium: 8192
            case .high, .xhigh: 24576
            }
            config["thinkingBudget"] = .int(budget)
        } else {
            let scale = ["minimal", "low", "medium", "high"]
            let levels: [Int] = if requestedModel.hasPrefix("gemini-3.1-flash-lite-image")
                || (requestedModel.hasPrefix("gemini-3.1-flash-image") && api == .developer) {
                [0, 3]
            } else if requestedModel.hasPrefix("gemini-3-pro-preview") {
                [1, 3]
            } else if ["gemini-3.7-flash", "gemini-3.8-flash", "gemini-3.1-pro-preview"]
                .contains(where: requestedModel.hasPrefix) {
                [1, 2, 3]
            } else {
                [0, 1, 2, 3]
            }
            let requested = switch effort {
            case .none, .minimal: 0
            case .low: 1
            case .medium: 2
            case .high, .xhigh: 3
            }
            // Match Python's nearest supported level, preferring the lower one on a tie.
            let chosen = levels.min { abs($0 - requested) < abs($1 - requested) }!
            config["thinkingLevel"] = .string(scale[chosen])
        }
        return config
    }

    private static func encode(_ message: ChatMessage) -> JSONValue {
        let parts: [JSONValue] = switch message.role {
        case .assistant: [.object(["text": .string(message.text)])]
        case .user: message.content.map(part)
        }
        return .object(["role": .string(message.role == .user ? "user" : "model"), "parts": .array(parts)])
    }

    private static func part(_ content: UserContent) -> JSONValue {
        switch content {
        case let .text(text):
            .object(["text": .string(text)])
        case let .image(data, mediaType):
            .object([
                "inlineData": .object([
                    "mimeType": .string(mediaType),
                    "data": .string(data.base64EncodedString()),
                ]),
            ])
        case let .video(data, mediaType):
            .object([
                "inlineData": .object([
                    "mimeType": .string(mediaType),
                    "data": .string(data.base64EncodedString()),
                ]),
                // Default 1 FPS can omit motion in the app's shortest approved segments.
                // Google's documented maximum is 24 FPS; keep the complete clip and sample it densely.
                "videoMetadata": .object(["fps": .int(Sources.videoSamplingFPS)]),
            ])
        }
    }

    // MARK: Reply

    static func parse(_ envelope: JSONValue, mode: OutputMode) throws -> ModelReply {
        guard let candidate = envelope.field("candidates")?.element(0) else {
            if let reason = envelope.field("promptFeedback")?.field("blockReason")?.stringValue {
                throw ModelError.malformedReply("prompt blocked: \(reason)")
            }
            let detail = envelope.field("error")?.field("message")?.stringValue ?? "no candidates in reply"
            throw ModelError.malformedReply(detail)
        }
        // Thought summaries come back as parts flagged `thought`; they are not the answer.
        let parts = (candidate.field("content")?.field("parts")?.arrayValue ?? [])
            .filter { $0.field("thought")?.boolValue != true }
        let text: String
        if mode == .tool, let args = parts.compactMap({ $0.field("functionCall")?.field("args") }).first {
            text = args.pythonDumps()
        } else if let content = parts.compactMap({ $0.field("text")?.stringValue }).first(where: { !$0.isEmpty }) {
            text = ReplyText.unfenced(content)
        } else {
            let finish = candidate.field("finishReason")?.stringValue ?? "unknown"
            throw ModelError.malformedReply(
                "candidate has no \(mode == .tool ? "functionCall or " : "")text part (finishReason \(finish))"
            )
        }
        let usage = envelope.field("usageMetadata")
        return ModelReply(
            text: text,
            servedModel: envelope.field("modelVersion")?.stringValue,
            usage: TokenUsage(
                inputTokens: usage?.field("promptTokenCount")?.intValue,
                outputTokens: usage?.field("candidatesTokenCount")?.intValue
            )
        )
    }
}
