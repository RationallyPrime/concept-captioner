// OpenAI Responses wire format: direct `openai`, Pydantic AI Gateway's default OpenAI route, and
// (through the shared `body` encoder) the ChatGPT plan route.

import Foundation

public struct OpenAIResponsesClient: ModelClient {
    public static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!

    public let baseURL: URL
    public let apiKey: String
    public let requestedModel: String
    public let transport: any HTTPTransport

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        requestedModel = model
        self.transport = transport
    }

    public func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) async throws -> ModelReply {
        var headers = ["Authorization": "Bearer \(apiKey)"]
        settings.mergeExtraHeaders(into: &headers)
        let body = Self.body(
            model: requestedModel, instructions: instructions, messages: messages, output: output, settings: settings
        )
        let envelope: JSONValue
        do {
            envelope = try await ProviderHTTP.post(
                body, to: baseURL.appendingPathComponent("responses"), headers: headers, transport: transport
            )
        } catch let error as ModelError {
            throw ProviderHTTP.explainThinkingRejection(error, model: requestedModel, settings: settings)
        }
        return try Self.parse(envelope, mode: output.mode)
    }

    /// The one Responses request body; ChatGPTModelClient adds only `stream`.
    ///
    /// The system prompt goes in the top-level `instructions` field, except in prompted mode:
    /// `json_object` requires the word "JSON" in an input message and OpenAI does not count
    /// `instructions`, so there it leads `input` as a system message (as pydantic-ai does).
    /// `store` is always false: captions and images are not retained at OpenAI.
    static func body(
        model: String,
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) -> JSONObject {
        let system = output.instructions(instructions)
        var input = messages.map(encode)
        var body: JSONObject = ["model": .string(model)]
        if output.mode == .prompted {
            input.insert(.object(["role": .string("system"), "content": .string(system)]), at: 0)
        } else {
            body["instructions"] = .string(system)
        }
        body["input"] = .array(input)
        switch output.mode {
        case .native, .prompted:
            body["text"] = textFormat(output)
        case .tool:
            body["tools"] = .array([.object([
                "type": .string("function"), "name": .string(output.name),
                "description": .string(output.toolDescription), "parameters": output.schema, "strict": .bool(true),
            ])])
            body["tool_choice"] = .object(["type": .string("function"), "name": .string(output.name)])
            if let parallel = settings.parallelToolCalls { body["parallel_tool_calls"] = .bool(parallel) }
        }
        body["reasoning"] = reasoning(settings, model: model)
        if let temperature = settings.temperature { body["temperature"] = .double(temperature) }
        if let maxTokens = settings.maxTokens { body["max_output_tokens"] = .int(maxTokens) }
        if let topP = settings.topP { body["top_p"] = .double(topP) }
        if let tier = settings.serviceTier { body["service_tier"] = .string(tier) }
        // Responses has no seed, top_k, stop, penalties or logit_bias parameters.
        settings.mergeExtraBody(into: &body)
        body["store"] = .bool(false)
        return body
    }

    static func textFormat(_ output: OutputRequest) -> JSONValue {
        let format: JSONValue = output.mode == .native ? .object([
            "type": .string("json_schema"), "name": .string(output.name),
            "schema": output.schema, "strict": .bool(true),
        ]) : .object(["type": .string("json_object")])
        return .object(["format": format])
    }

    static func reasoning(_ settings: RequestSettings, model: String) -> JSONValue? {
        guard settings.thinks else { return nil }
        var effort = settings.thinkingEffort?.rawValue ?? "medium"
        if effort == "minimal", model.hasPrefix("gpt-5.6") || model.hasPrefix("gpt-6") {
            effort = "low"
        }
        return .object(["effort": .string(effort)])
    }

    static func encode(_ message: ChatMessage) -> JSONValue {
        if message.role == .assistant {
            return .object(["role": .string("assistant"), "content": .string(message.text)])
        }
        let content: [JSONValue] = message.content.map { part in
            switch part {
            case let .text(text):
                .object(["type": .string("input_text"), "text": .string(text)])
            case let .image(data, mediaType):
                .object([
                    "type": .string("input_image"),
                    "image_url": .string("data:\(mediaType);base64,\(data.base64EncodedString())"),
                ])
            }
        }
        return .object(["role": .string("user"), "content": .array(content)])
    }

    static func parse(_ envelope: JSONValue, mode: OutputMode) throws -> ModelReply {
        guard let output = envelope.field("output")?.arrayValue else {
            throw ModelError
                .malformedReply(envelope.field("error")?.field("message")?.stringValue ?? "no output in reply")
        }
        let text: String
        if mode == .tool,
           let call = output.first(where: { $0.field("type")?.stringValue == "function_call" }),
           let arguments = call.field("arguments")?.stringValue {
            text = arguments
        } else {
            let blocks = output.filter { $0.field("type")?.stringValue == "message" }
                .flatMap { $0.field("content")?.arrayValue ?? [] }
            if let refusal = blocks.first(where: { $0.field("type")?.stringValue == "refusal" }) {
                throw ModelError
                    .malformedReply("refusal: \(refusal.field("refusal")?.stringValue ?? "no explanation given")")
            }
            let content = blocks.filter { $0.field("type")?.stringValue == "output_text" }
                .compactMap { $0.field("text")?.stringValue }.joined()
            guard !content.isEmpty else {
                throw ModelError.malformedReply("reply has no \(mode == .tool ? "function call or " : "")text output")
            }
            text = ReplyText.unfenced(content)
        }
        let usage = envelope.field("usage")
        return ModelReply(
            text: text, servedModel: envelope.field("model")?.stringValue,
            usage: TokenUsage(
                inputTokens: usage?.field("input_tokens")?.intValue,
                outputTokens: usage?.field("output_tokens")?.intValue
            )
        )
    }
}
