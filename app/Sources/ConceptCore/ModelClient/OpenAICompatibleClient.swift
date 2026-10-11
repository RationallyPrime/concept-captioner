// Chat Completions over URLSession. Covers OpenRouter, Vercel, vLLM and the gateway's explicit
// OpenAI Chat route (direct OpenAI speaks Responses). See docs/CORE-SPEC.md for the exact
// request and reply shapes per output mode.

import Foundation

public struct OpenAICompatibleClient: ModelClient {
    /// How a thinking level is spelled on the wire. Chosen by `resolve` from the endpoint kind.
    public enum ReasoningDialect: Sendable {
        /// `reasoning_effort: <level>` (OpenAI Chat Completions, Vercel, vLLM).
        case reasoningEffort
        /// `reasoning: {effort, enabled: true}` with OpenRouter's three-step scale.
        case openRouter
    }

    public static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    public static let vercelBaseURL = URL(string: "https://ai-gateway.vercel.sh/v1")!

    public let baseURL: URL
    public let apiKey: String?
    public let requestedModel: String
    public let transport: any HTTPTransport
    public let extraHeaders: [String: String]
    public let acceptsVideo: Bool
    public let reasoningDialect: ReasoningDialect

    public init(
        baseURL: URL,
        apiKey: String?,
        model: String,
        transport: any HTTPTransport = URLSessionTransport(),
        extraHeaders: [String: String] = [:],
        reasoningDialect: ReasoningDialect = .reasoningEffort,
        acceptsVideo: Bool = false
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        requestedModel = model
        self.transport = transport
        self.extraHeaders = extraHeaders
        self.reasoningDialect = reasoningDialect
        self.acceptsVideo = acceptsVideo
    }

    public func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ModelReply {
        var headers = extraHeaders
        if let apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        settings.mergeExtraHeaders(into: &headers)
        let envelope: JSONValue
        do {
            envelope = try await ProviderHTTP.post(
                requestBody(instructions: instructions, messages: messages, output: output, settings: settings),
                to: baseURL.appendingPathComponent("chat/completions"),
                headers: headers,
                transport: transport
            )
        } catch let error as ModelError {
            throw ProviderHTTP.explainThinkingRejection(error, model: requestedModel, settings: settings)
        }
        return try Self.parse(envelope, mode: output.mode)
    }

    // MARK: Request

    func requestBody(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) throws -> JSONObject {
        var chat: [JSONValue] = [
            .object(["role": .string("system"), "content": .string(output.instructions(instructions))]),
        ]
        try chat.append(contentsOf: messages.map(encode))
        var body: JSONObject = ["model": .string(requestedModel), "messages": .array(chat)]
        switch output.mode {
        case .native:
            body["response_format"] = .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string(output.name),
                    "schema": output.schema,
                    "strict": .bool(true),
                ]),
            ])
        case .prompted:
            body["response_format"] = .object(["type": .string("json_object")])
        case .tool:
            body["tools"] = .array([
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(output.name),
                        "description": .string(output.toolDescription),
                        "parameters": output.schema,
                        "strict": .bool(true),
                    ]),
                ]),
            ])
            body["tool_choice"] = .object([
                "type": .string("function"),
                "function": .object(["name": .string(output.name)]),
            ])
        }
        if settings.thinks {
            for (key, value) in reasoningSettings(settings).pairs {
                body[key] = value
            }
        }
        if let temperature = settings.temperature { body["temperature"] = .double(temperature) }
        if let maxTokens = settings.maxTokens { body["max_completion_tokens"] = .int(maxTokens) }
        if let seed = settings.seed { body["seed"] = .int(seed) }
        if let topP = settings.topP { body["top_p"] = .double(topP) }
        // top_k is not a Chat Completions parameter; pydantic-ai drops it here too (vLLM: extra_body).
        if let stop = settings.stopSequencesJSON { body["stop"] = stop }
        if let penalty = settings.presencePenalty { body["presence_penalty"] = .double(penalty) }
        if let penalty = settings.frequencyPenalty { body["frequency_penalty"] = .double(penalty) }
        if let bias = settings.logitBiasJSON { body["logit_bias"] = bias }
        if let tier = settings.serviceTier { body["service_tier"] = .string(tier) }
        if output.mode == .tool, let parallel = settings.parallelToolCalls {
            body["parallel_tool_calls"] = .bool(parallel)
        }
        settings.mergeExtraBody(into: &body)
        try MediaInput.checkVideoRequest(body, messages: messages)
        return body
    }

    private func reasoningSettings(_ settings: RequestSettings) -> JSONObject {
        guard reasoningDialect == .openRouter else {
            // pydantic-ai's OPENAI_REASONING_EFFORT_MAP sends "medium" for `thinking: true`.
            return ["reasoning_effort": .string(settings.thinkingEffort?.rawValue ?? "medium")]
        }
        let effort = switch settings.thinkingEffort {
        case nil, .medium: "medium"
        case .some(.none), .minimal, .low: "low"
        case .high, .xhigh: "high"
        }
        return ["reasoning": .object(["effort": .string(effort), "enabled": .bool(true)])]
    }

    private func encode(_ message: ChatMessage) throws -> JSONValue {
        switch message.role {
        case .assistant:
            .object(["role": .string("assistant"), "content": .string(message.text)])
        case .user:
            try .object(["role": .string("user"), "content": .array(message.content.map(part))])
        }
    }

    private func part(_ content: UserContent) throws -> JSONValue {
        switch content {
        case let .video(data, mediaType):
            guard acceptsVideo else { throw MediaInput.unsupportedVideo() }
            return .object([
                "type": .string("video_url"),
                "video_url": .object(["url": .string("data:\(mediaType);base64,\(data.base64EncodedString())")]),
            ])
        case let .text(text):
            return .object(["type": .string("text"), "text": .string(text)])
        case let .image(data, mediaType):
            return .object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string("data:\(mediaType);base64,\(data.base64EncodedString())")]),
            ])
        }
    }

    // MARK: Reply

    static func parse(_ envelope: JSONValue, mode: OutputMode) throws -> ModelReply {
        guard let message = envelope.field("choices")?.element(0)?.field("message") else {
            let detail = envelope.field("error")?.field("message")?.stringValue ?? "no choices in reply"
            throw ModelError.malformedReply(detail)
        }
        let text: String
        if mode == .tool,
           let arguments = message.field("tool_calls")?.element(0)?.field("function")?.field("arguments")?.stringValue {
            text = arguments
        } else if let content = contentText(message.field("content")), !content.isEmpty {
            text = ReplyText.unfenced(content)
        } else if let refusal = message.field("refusal")?.stringValue {
            throw ModelError.malformedReply("refusal: \(refusal)")
        } else {
            throw ModelError.malformedReply("reply has no \(mode == .tool ? "tool call or " : "")text content")
        }
        let usage = envelope.field("usage")
        return ModelReply(
            text: text,
            servedModel: envelope.field("model")?.stringValue,
            usage: TokenUsage(
                inputTokens: usage?.field("prompt_tokens")?.intValue,
                outputTokens: usage?.field("completion_tokens")?.intValue
            )
        )
    }

    /// `content` is a string, or (some servers) an array of `{type: "text", text}` parts.
    private static func contentText(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let text = content.stringValue { return text }
        guard let parts = content.arrayValue else { return nil }
        let texts = parts.compactMap { $0.field("text")?.stringValue }
        return texts.isEmpty ? nil : texts.joined()
    }
}
