// Gemini generateContent over URLSession: responseMimeType application/json + responseJsonSchema,
// inlineData images, thinkingConfig.

import Foundation

public struct GeminiClient: ModelClient {
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

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
        var headers = ["x-goog-api-key": apiKey]
        settings.mergeExtraHeaders(into: &headers)
        let envelope = try await ProviderHTTP.post(
            requestBody(instructions: instructions, messages: messages, output: output, settings: settings),
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
        if let level = settings.thinkingEffort.flatMap(Self.thinkingLevel) {
            generation["thinkingConfig"] = .object(["thinkingLevel": .string(level)])
        } else if settings.thinks {
            // `thinking: true`: pydantic-ai sends includeThoughts with no level (the model's default).
            generation["thinkingConfig"] = .object(["includeThoughts": .bool(true)])
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

    static func thinkingLevel(_ level: ThinkingLevel) -> String? {
        switch level {
        case .none: nil
        case .minimal, .low: "low"
        case .medium: "medium"
        case .high, .xhigh: "high"
        }
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
