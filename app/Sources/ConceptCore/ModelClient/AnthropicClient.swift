// Anthropic Messages API over URLSession. Structured output via output_config.format (JSON
// Schema); tool mode via a strict tool with tool_choice auto; thinking via adaptive + effort.

import Foundation

public struct AnthropicClient: ModelClient {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let apiVersion = "2023-06-01"
    public static let defaultMaxTokens = 16000

    public let baseURL: URL
    public let apiKey: String
    public let requestedModel: String
    public let transport: any HTTPTransport

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = defaultBaseURL,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.apiKey = apiKey
        requestedModel = model
        self.baseURL = baseURL
        self.transport = transport
    }

    public func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) async throws -> ModelReply {
        var headers = ["x-api-key": apiKey, "anthropic-version": Self.apiVersion]
        settings.mergeExtraHeaders(into: &headers)
        let envelope = try await ProviderHTTP.post(
            requestBody(instructions: instructions, messages: messages, output: output, settings: settings),
            to: baseURL.appendingPathComponent("v1/messages"),
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
        var system = output.instructions(instructions)
        var outputConfig = JSONObject()
        var tools: JSONObject = [:]
        switch output.mode {
        case .native:
            outputConfig["format"] = .object(["type": .string("json_schema"), "schema": output.schema])
        case .prompted:
            break
        case .tool:
            // Forced tool_choice is HTTP 400 on current Claude models: a strict tool, auto choice
            // and a system instruction to call it.
            tools["tools"] = .array([
                .object([
                    "name": .string(output.name),
                    "description": .string(output.toolDescription),
                    "input_schema": output.schema,
                    "strict": .bool(true),
                ]),
            ])
            tools["tool_choice"] = .object(["type": .string("auto")])
            system += "\n\nCall the tool `\(output.name)` exactly once with your answer."
        }

        var body: JSONObject = [
            "model": .string(requestedModel),
            "max_tokens": .int(settings.maxTokens ?? Self.defaultMaxTokens),
            "system": .string(system),
            "messages": .array(messages.map(Self.encode)),
        ]
        for (key, value) in tools.pairs {
            body[key] = value
        }
        if settings.thinks {
            // `thinking: true` is adaptive with the effort left to the API (pydantic-ai does the same).
            body["thinking"] = .object(["type": .string("adaptive")])
            if let effort = settings.thinkingEffort {
                outputConfig["effort"] = .string(Self.effort(effort))
            }
        } else {
            // The API rejects sampling parameters (temperature, top_p, top_k) once thinking is on.
            if let temperature = settings.temperature { body["temperature"] = .double(temperature) }
            if let topP = settings.topP { body["top_p"] = .double(topP) }
            if let topK = settings.topK { body["top_k"] = .int(topK) }
        }
        if let stop = settings.stopSequencesJSON { body["stop_sequences"] = stop }
        if let tier = Self.serviceTier(settings.serviceTier) { body["service_tier"] = .string(tier) }
        if !outputConfig.isEmpty {
            body["output_config"] = .object(outputConfig)
        }
        settings.mergeExtraBody(into: &body)
        return body
    }

    /// pydantic-ai's unified service_tier mapping: `auto` -> `auto`, `default` -> `standard_only`;
    /// `flex` and `priority` are not exposed by this field and are dropped.
    static func serviceTier(_ tier: String?) -> String? {
        switch tier {
        case "auto": "auto"
        case "default": "standard_only"
        default: nil
        }
    }

    static func effort(_ level: ThinkingLevel) -> String {
        switch level {
        case .none, .minimal, .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        }
    }

    private static func encode(_ message: ChatMessage) -> JSONValue {
        let blocks: [JSONValue] = switch message.role {
        case .assistant: [.object(["type": .string("text"), "text": .string(message.text)])]
        case .user: message.content.map(block)
        }
        return .object(["role": .string(message.role.rawValue), "content": .array(blocks)])
    }

    private static func block(_ content: UserContent) -> JSONValue {
        switch content {
        case let .text(text):
            .object(["type": .string("text"), "text": .string(text)])
        case let .image(data, mediaType):
            .object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(mediaType),
                    "data": .string(data.base64EncodedString()),
                ]),
            ])
        }
    }

    // MARK: Reply

    static func parse(_ envelope: JSONValue, mode: OutputMode) throws -> ModelReply {
        if envelope.field("stop_reason")?.stringValue == "refusal" {
            let explanation = envelope.field("stop_details")?.field("explanation")?.stringValue
            throw ModelError.malformedReply("refusal: \(explanation ?? "no explanation given")")
        }
        guard let blocks = envelope.field("content")?.arrayValue else {
            let detail = envelope.field("error")?.field("message")?.stringValue ?? "no content blocks in reply"
            throw ModelError.malformedReply(detail)
        }
        let text: String
        let toolUse = blocks.first { $0.field("type")?.stringValue == "tool_use" }
        if mode == .tool, let input = toolUse?.field("input") {
            text = input.pythonDumps()
        } else if let block = blocks.first(where: { $0.field("type")?.stringValue == "text" }),
                  let content = block.field("text")?.stringValue, !content.isEmpty {
            text = ReplyText.unfenced(content)
        } else {
            let stop = envelope.field("stop_reason")?.stringValue ?? "unknown"
            throw ModelError.malformedReply(
                "reply has no \(mode == .tool ? "tool_use or " : "")text block (stop_reason \(stop))"
            )
        }
        let usage = envelope.field("usage")
        return ModelReply(
            text: text,
            servedModel: envelope.field("model")?.stringValue,
            usage: TokenUsage(
                inputTokens: usage?.field("input_tokens")?.intValue,
                outputTokens: usage?.field("output_tokens")?.intValue
            )
        )
    }
}
