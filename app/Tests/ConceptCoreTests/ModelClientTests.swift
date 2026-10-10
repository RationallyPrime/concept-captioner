// resolve and the three HTTP clients over StubTransport. StructuredStage retries are in
// StructuredStageTests.swift. See docs/CORE-SPEC.md, module `modelclient`.

import ConceptCore
import CoreGraphics
import Foundation
import Testing

// MARK: - Shared helpers

private extension JSONValue {
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard let items = arrayValue, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

private extension ModelError {
    var httpStatus: Int? {
        if case let .http(status, _) = self { status } else { nil }
    }

    var httpBody: String? {
        if case let .http(_, body) = self { body } else { nil }
    }

    var isTransport: Bool {
        if case .transport = self { true } else { false }
    }

    var malformed: String? {
        if case let .malformedReply(message) = self { message } else { nil }
    }

    var missingKey: Provider? {
        if case let .missingKey(provider) = self { provider } else { nil }
    }
}

private enum Support {
    static let keys = StaticKeyStore([.google: "g-key", .anthropic: "a-key", .openai: "o-key", .openrouter: "r-key"])
    static let png = Fixtures.syntheticPNG(seed: 1, size: CGSize(width: 24, height: 24))
    static let instructions = "You caption images."
    static let captionJSON = #"{"caption": "A photo of NORA7.", "usable": true, "note": null}"#
    static let promptedSuffix = "\n\nDon't include any text or Markdown fencing before or after."
    static let turn: [ChatMessage] = [.user([.text("Inspect this image."), .image(data: png, mediaType: "image/png")])]

    static func output(_ mode: OutputMode) -> OutputRequest {
        OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: mode)
    }

    /// A transport that always answers with this JSON object (built outside the closure: `Any` is not Sendable).
    static func replying(_ object: Any, status: Int = 200) throws -> StubTransport {
        let response = try StubTransport.json(object, status: status)
        return StubTransport { _ in response }
    }

    static func body(_ transport: StubTransport) async throws -> JSONValue {
        try await JSONValue(parsing: transport.requests[0].httpBody ?? Data())
    }

    /// The ModelError a native-mode request fails with; records an issue when it does not throw one.
    static func failure(_ client: some ModelClient) async -> ModelError? {
        await #expect(throws: ModelError.self) {
            try await client.request(instructions: "", messages: turn, output: output(.native), settings: .init())
        }
    }

    static func caption(_ text: String) throws -> Caption {
        try JSONValue(parsing: text).decode(Caption.self)
    }
}

@Suite("modelclient resolve")
struct ResolveTests {
    @Test(
        "the five documented kinds resolve to their client",
        arguments: [
            ("google:gemini-3.8-flash", "GeminiClient", nil),
            ("anthropic:claude-opus-5-5", "AnthropicClient", nil),
            ("openai:gpt-5.2", "OpenAICompatibleClient", "https://api.openai.com/v1"),
            ("openrouter:anthropic/claude-sonnet-4-6", "OpenAICompatibleClient", "https://openrouter.ai/api/v1"),
            ("vllm:Qwen/Qwen3-VL-32B-Instruct", "OpenAICompatibleClient", "http://localhost:8000/v1"),
        ] as [(String, String, String?)]
    )
    func documentedKinds(spec: String, typeName: String, baseURL: String?) throws {
        var endpoint = try Endpoints.parseSpec(spec)
        if endpoint.kind == "vllm" { endpoint.baseURL = baseURL }
        let resolved = try Endpoints.resolve(endpoint, thinking: .low, keys: Support.keys)
        #expect(String(describing: type(of: resolved.client)) == typeName)
        #expect((resolved.client as? OpenAICompatibleClient)?.baseURL.absoluteString == baseURL)
        #expect(resolved.requested == String(spec.split(separator: ":", maxSplits: 1)[1]))
        #expect(resolved.settings.thinking == .low)
        #expect(resolved.outputMode == .native)
    }

    @Test func baseURLAndOutputModes() throws {
        let vllm = try Endpoints.resolve(
            EndpointSpec(kind: "vllm", model: "Qwen/x", baseURL: "http://pod:8000/v1", outputMode: .prompted),
            keys: StaticKeyStore([:])
        )
        let client = try #require(vllm.client as? OpenAICompatibleClient)
        #expect(client.baseURL == URL(string: "http://pod:8000/v1"))
        #expect(client.apiKey == nil)
        #expect(vllm.outputMode == .prompted)
        #expect(vllm.settings.thinking == .none)

        let other = try Endpoints.resolve(
            EndpointSpec(
                kind: "vllm",
                model: "m",
                baseURL: "http://127.0.0.1:8000/v1",
                outputMode: .tool,
                settings: ["temperature": .double(0.2)],
                concurrency: 2
            ),
            keys: StaticKeyStore([.vllm: "v-key"], vllmBaseURL: "http://127.0.0.1:8000/v1")
        )
        #expect((other.client as? OpenAICompatibleClient)?.baseURL == URL(string: "http://127.0.0.1:8000/v1"))
        #expect((other.client as? OpenAICompatibleClient)?.apiKey == "v-key")
        #expect(other.outputMode == .tool)
        #expect(other.settings.temperature == 0.2)
        #expect(other.settings.thinking == .none)
        #expect(other.concurrency == 2)
    }

    @Test func settingsAreLiftedStrictly() throws {
        let settings = try RequestSettings(
            settings: [
                "temperature": .double(0.5),
                "max_tokens": .int(900),
                "seed": .int(7),
                "top_p": .double(0.9),
                "thinking": .string("high"),
                "extra_body": .object(["chat_template_kwargs": .object(["enable_thinking": .bool(false)])]),
            ],
            thinking: .low
        )
        #expect(settings.temperature == 0.5)
        #expect(settings.maxTokens == 900)
        #expect(settings.seed == 7)
        #expect(settings.topP == 0.9)
        #expect(settings.thinking == .high)
        #expect(settings.extraBody["chat_template_kwargs"]?["enable_thinking"] == .bool(false))

        let typo = #expect(throws: ConfigurationError.self) {
            try RequestSettings(settings: ["temp": .double(1)], thinking: .none)
        }
        #expect(typo?.message == "unsupported setting 'temp'")
        for bad: JSONObject in [["thinking": .string("lots")], ["max_tokens": .string("many")]] {
            #expect(throws: ConfigurationError.self) { try RequestSettings(settings: bad, thinking: .none) }
        }
        // The rest of the pydantic-ai key set and boolean thinking: ModelClientSettingsTests.swift.
    }

    @Test func rejectsBadSpecs() throws {
        let gemini = #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve("gemini:gemini-3.8-flash", keys: Support.keys)
        }
        #expect(gemini?.message.contains("kind: google") == true)
        let noColon = #expect(throws: ConfigurationError.self) { try Endpoints.parseSpec("no-colon") }
        #expect(noColon?.message == "endpoint spec must look like provider:model, got 'no-colon'")
        #expect(throws: ConfigurationError.self) { try Endpoints.parseSpec("openai: ") }
        #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(EndpointSpec(kind: "google", model: "x", baseURL: "http://nope"), keys: Support.keys)
        }
        let noBase = #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve("vllm:Qwen/x", keys: Support.keys)
        }
        #expect(noBase?.message == "kind vllm needs base_url")
        let unknown = #expect(throws: ConfigurationError.self) { try Endpoints.resolve("foo:bar", keys: Support.keys) }
        #expect(unknown?.message.contains("unknown endpoint kind 'foo'; expected one of") == true)
        #expect(unknown?.message.contains("vercel") == true)
        #expect(unknown?.message.contains("gateway/openai") == true)
        let noKey = #expect(throws: ModelError.self) {
            try Endpoints.resolve("anthropic:claude-opus-5-5", keys: StaticKeyStore([:]))
        }
        #expect(noKey?.missingKey == .anthropic)
    }
}

@Suite("modelclient openai")
struct OpenAIClientTests {
    static let base = URL(string: "http://pod:8000/v1")!

    func client(_ transport: StubTransport, key: String? = "sk-test") -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: Self.base, apiKey: key, model: "gpt-5.2", transport: transport)
    }

    @Test func nativeMode() async throws {
        let transport = try Support.replying([
            "model": "gpt-5.2-2026-01-01",
            "choices": [["message": ["role": "assistant", "content": Support.captionJSON]]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5],
        ])
        let reply = try await client(transport).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.native),
            settings: RequestSettings(thinking: .low, temperature: 0.2, maxTokens: 400, seed: 3, topP: 0.9)
        )
        #expect(reply.text == Support.captionJSON)
        #expect(reply.servedModel == "gpt-5.2-2026-01-01")
        #expect(reply.usage == TokenUsage(inputTokens: 10, outputTokens: 5))

        let request = await transport.requests[0]
        #expect(request.url?.absoluteString == "http://pod:8000/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try await Support.body(transport)
        #expect(body["model"]?.stringValue == "gpt-5.2")
        #expect(body["messages"]?[0]?["role"]?.stringValue == "system")
        #expect(body["messages"]?[0]?["content"]?.stringValue == Support.instructions)
        #expect(body["messages"]?[1]?["content"]?[0]?["text"]?.stringValue == "Inspect this image.")
        let url = body["messages"]?[1]?["content"]?[1]?["image_url"]?["url"]?.stringValue ?? ""
        #expect(url.hasPrefix("data:image/png;base64,"))
        let format = body["response_format"]
        #expect(format?["type"]?.stringValue == "json_schema")
        #expect(format?["json_schema"]?["strict"] == .bool(true))
        #expect(format?["json_schema"]?["name"]?.stringValue == "Caption")
        #expect(format?["json_schema"]?["schema"] == Caption.jsonSchema)
        #expect(body["reasoning_effort"]?.stringValue == "low")
        #expect(body["temperature"] == .double(0.2))
        #expect(body["max_completion_tokens"] == .int(400))
        #expect(body["seed"] == .int(3))
        #expect(body["top_p"] == .double(0.9))
    }

    @Test func toolModeAndHistory() async throws {
        let transport = try Support.replying([
            "model": "gpt-5.2",
            "choices": [["message": [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [["type": "function", "function": ["name": "Caption", "arguments": Support.captionJSON]]],
            ]]],
        ])
        let history = Support.turn + [.assistant(#"{"caption": "first"}"#), .user("Try again.")]
        let reply = try await client(transport, key: nil).request(
            instructions: Support.instructions,
            messages: history,
            output: Support.output(.tool),
            settings: RequestSettings(extraBody: ["chat_template_kwargs": .object(["enable_thinking": .bool(false)])])
        )
        #expect(reply.text == Support.captionJSON)
        let request = await transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try await Support.body(transport)
        #expect(body["tools"]?[0]?["function"]?["name"]?.stringValue == "Caption")
        #expect(body["tools"]?[0]?["function"]?["strict"] == .bool(true))
        #expect(body["tools"]?[0]?["function"]?["parameters"] == Caption.jsonSchema)
        #expect(body["tool_choice"]?["function"]?["name"]?.stringValue == "Caption")
        #expect(body["response_format"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["messages"]?[2]?["role"]?.stringValue == "assistant")
        #expect(body["messages"]?[2]?["content"]?.stringValue == #"{"caption": "first"}"#)
        #expect(body["messages"]?[3]?["content"]?[0]?["text"]?.stringValue == "Try again.")
        #expect(body["chat_template_kwargs"]?["enable_thinking"] == .bool(false))
    }

    @Test func promptedModeUnfencesAndAppendsSchema() async throws {
        let transport = try Support.replying([
            "model": "Qwen/x",
            "choices": [["message": ["role": "assistant", "content": "```json\n\(Support.captionJSON)\n```"]]],
        ])
        let reply = try await client(transport).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.prompted),
            settings: RequestSettings()
        )
        #expect(reply.text == Support.captionJSON)
        let body = try await Support.body(transport)
        #expect(body["response_format"]?["type"]?.stringValue == "json_object")
        let system = body["messages"]?[0]?["content"]?.stringValue ?? ""
        // pydantic-ai DEFAULT_PROMPTED_OUTPUT_TEMPLATE, word for word.
        #expect(system.hasPrefix(
            Support.instructions + "\n\nAlways respond with a JSON object that's compatible with this schema:\n\n"
        ))
        #expect(system.contains(Caption.jsonSchema.pythonDumps()))
        #expect(system.hasSuffix(Support.promptedSuffix))
    }

    @Test func errorsMapToModelError() async throws {
        let http = try Support.replying(["error": ["message": "slow down"]], status: 429)
        let httpError = await Support.failure(client(http))
        #expect(httpError?.httpStatus == 429)
        #expect(httpError?.httpBody?.contains("slow down") == true)

        struct Offline: Error {}
        let broken = StubTransport { _ in throw Offline() }
        #expect(await Support.failure(client(broken))?.isTransport == true)

        let empty = try Support.replying(["model": "m", "choices": [["message": ["role": "assistant"]]]])
        #expect(await Support.failure(client(empty))?.malformed != nil)
    }
}

@Suite("modelclient anthropic")
struct AnthropicClientTests {
    func client(_ transport: StubTransport) -> AnthropicClient {
        AnthropicClient(apiKey: "ak-test", model: "claude-opus-5-5", transport: transport)
    }

    static func textReply() -> [String: Any] {
        [
            "model": "claude-opus-5-5-20260101",
            "stop_reason": "end_turn",
            "content": [["type": "thinking", "thinking": "hmm"], ["type": "text", "text": Support.captionJSON]],
            "usage": ["input_tokens": 12, "output_tokens": 6],
        ]
    }

    @Test func nativeModeWithThinking() async throws {
        let transport = try Support.replying(Self.textReply())
        let reply = try await client(transport).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.native),
            settings: RequestSettings(thinking: .high, temperature: 0.3, maxTokens: 2048)
        )
        #expect(reply.text == Support.captionJSON)
        #expect(reply.servedModel == "claude-opus-5-5-20260101")
        #expect(reply.usage == TokenUsage(inputTokens: 12, outputTokens: 6))

        let request = await transport.requests[0]
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "ak-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try await Support.body(transport)
        #expect(body["model"]?.stringValue == "claude-opus-5-5")
        #expect(body["max_tokens"] == .int(2048))
        #expect(body["system"]?.stringValue == Support.instructions)
        let image = body["messages"]?[0]?["content"]?[1]
        #expect(body["messages"]?[0]?["role"]?.stringValue == "user")
        #expect(image?["type"]?.stringValue == "image")
        #expect(image?["source"]?["type"]?.stringValue == "base64")
        #expect(image?["source"]?["media_type"]?.stringValue == "image/png")
        #expect(body["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(body["output_config"]?["format"]?["schema"] == Caption.jsonSchema)
        #expect(body["output_config"]?["effort"]?.stringValue == "high")
        #expect(body["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(body["temperature"] == nil, "sampling parameters are dropped once thinking is on")
    }

    @Test func noThinkingKeepsSamplingAndDefaults() async throws {
        let transport = try Support.replying(Self.textReply())
        _ = try await client(transport).request(
            instructions: Support.instructions,
            messages: Support.turn + [.assistant("{}"), .user("Again.")],
            output: Support.output(.prompted),
            settings: RequestSettings(temperature: 0.3, seed: 9, topP: 0.8)
        )
        let body = try await Support.body(transport)
        #expect(body["thinking"] == nil)
        #expect(body["output_config"] == nil)
        #expect(body["max_tokens"] == .int(AnthropicClient.defaultMaxTokens))
        #expect(body["temperature"] == .double(0.3))
        #expect(body["top_p"] == .double(0.8))
        #expect(body["seed"] == nil)
        #expect(body["messages"]?[1]?["role"]?.stringValue == "assistant")
        #expect(body["messages"]?[1]?["content"]?[0]?["text"]?.stringValue == "{}")
        #expect(body["system"]?.stringValue?.hasSuffix(Support.promptedSuffix) == true)
    }

    @Test func toolMode() async throws {
        let transport = try Support.replying([
            "model": "claude-opus-5-5",
            "stop_reason": "tool_use",
            "content": [["type": "tool_use", "id": "t1", "name": "Caption", "input": [
                "caption": "A photo of NORA7.", "usable": true, "note": NSNull(),
            ]]],
        ])
        let reply = try await client(transport).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.tool),
            settings: RequestSettings(thinking: .minimal)
        )
        #expect(try Support.caption(reply.text) == Caption(caption: "A photo of NORA7."))
        let body = try await Support.body(transport)
        #expect(body["tool_choice"]?["type"]?.stringValue == "auto")
        #expect(body["tools"]?[0]?["name"]?.stringValue == "Caption")
        #expect(body["tools"]?[0]?["strict"] == .bool(true))
        #expect(body["tools"]?[0]?["input_schema"] == Caption.jsonSchema)
        let system = body["system"]?.stringValue ?? ""
        #expect(system.hasSuffix("Call the tool `Caption` exactly once with your answer."))
        #expect(body["output_config"]?["effort"]?.stringValue == "low")
        #expect(body["output_config"]?["format"] == nil)
    }

    @Test func refusalIsMalformedReply() async throws {
        let transport = try Support.replying([
            "model": "claude-opus-5-5",
            "stop_reason": "refusal",
            "stop_details": ["type": "refusal", "explanation": "policy"],
            "content": [],
        ])
        #expect(await Support.failure(client(transport))?.malformed == "refusal: policy")
    }
}

@Suite("modelclient gemini")
struct GeminiClientTests {
    func client(_ transport: StubTransport) -> GeminiClient {
        GeminiClient(apiKey: "gk-test", model: "gemini-3.8-flash", transport: transport)
    }

    @Test func nativeMode() async throws {
        let transport = try Support.replying([
            "modelVersion": "gemini-3.8-flash-001",
            "candidates": [["content": ["role": "model", "parts": [
                ["text": "thinking...", "thought": true], ["text": Support.captionJSON],
            ]], "finishReason": "STOP"]],
            "usageMetadata": ["promptTokenCount": 20, "candidatesTokenCount": 8],
        ])
        let reply = try await client(transport).request(
            instructions: Support.instructions,
            messages: Support.turn + [.assistant("{}"), .user("Again.")],
            output: Support.output(.native),
            settings: RequestSettings(thinking: .xhigh, temperature: 0.1, maxTokens: 300, seed: 5, topP: 0.7)
        )
        #expect(reply.text == Support.captionJSON)
        #expect(reply.servedModel == "gemini-3.8-flash-001")
        #expect(reply.usage == TokenUsage(inputTokens: 20, outputTokens: 8))

        let request = await transport.requests[0]
        let url = request.url?.absoluteString ?? ""
        #expect(url.hasSuffix("models/gemini-3.8-flash:generateContent"))
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gk-test")
        let body = try await Support.body(transport)
        #expect(body["systemInstruction"]?["parts"]?[0]?["text"]?.stringValue == Support.instructions)
        #expect(body["contents"]?[0]?["role"]?.stringValue == "user")
        #expect(body["contents"]?[0]?["parts"]?[1]?["inlineData"]?["mimeType"]?.stringValue == "image/png")
        #expect(body["contents"]?[1]?["role"]?.stringValue == "model")
        let generation = body["generationConfig"]
        #expect(generation?["responseMimeType"]?.stringValue == "application/json")
        #expect(generation?["responseJsonSchema"] == Caption.jsonSchema)
        #expect(generation?["thinkingConfig"]?["thinkingLevel"]?.stringValue == "high")
        #expect(generation?["temperature"] == .double(0.1))
        #expect(generation?["maxOutputTokens"] == .int(300))
        #expect(generation?["seed"] == .int(5))
        #expect(generation?["topP"] == .double(0.7))
    }

    @Test func toolMode() async throws {
        let transport = try Support.replying([
            "modelVersion": "gemini-3.8-flash",
            "candidates": [["content": ["role": "model", "parts": [
                ["functionCall": ["name": "Caption", "args": ["caption": "A photo of NORA7.", "usable": true]]],
            ]]]],
        ])
        let reply = try await client(transport).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.tool),
            settings: RequestSettings(thinking: .medium)
        )
        #expect(try Support.caption(reply.text) == Caption(caption: "A photo of NORA7."))
        let body = try await Support.body(transport)
        let declaration = body["tools"]?[0]?["functionDeclarations"]?[0]
        #expect(declaration?["name"]?.stringValue == "Caption")
        #expect(declaration?["parametersJsonSchema"] == Caption.jsonSchema)
        let calling = body["toolConfig"]?["functionCallingConfig"]
        #expect(calling?["mode"]?.stringValue == "ANY")
        #expect(calling?["allowedFunctionNames"]?[0]?.stringValue == "Caption")
        #expect(body["generationConfig"]?["responseMimeType"] == nil)
        #expect(body["generationConfig"]?["thinkingConfig"]?["thinkingLevel"]?.stringValue == "medium")
    }

    @Test func blockedPromptIsMalformedReply() async throws {
        let transport = try Support.replying(["promptFeedback": ["blockReason": "SAFETY"]])
        #expect(await Support.failure(client(transport))?.malformed?.contains("SAFETY") == true)
    }
}

@Suite("modelclient transport", .serialized)
struct URLSessionTransportTests {
    func send(_ path: String) async throws -> (HTTPResponse, [URLRequest]) {
        let transport = URLSessionTransport(session: RedirectStubProtocol.session(), timeout: 5)
        var request = URLRequest(url: URL(string: "https://origin.test\(path)")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        return (response, RedirectStubProtocol.seen.withLock { $0 })
    }

    @Test func dropsAuthorizationWhenRedirectLeavesTheHost() async throws {
        let (response, seen) = try await send("/cross")
        #expect(response.status == 200)
        #expect(String(bytes: response.body, encoding: .utf8) == "ok")
        #expect(seen.count == 2)
        #expect(seen.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(seen.last?.url?.host() == "cdn.test")
        #expect(seen.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func keepsAuthorizationOnTheSameHost() async throws {
        let (response, seen) = try await send("/same")
        #expect(response.status == 200)
        #expect(seen.count == 2)
        #expect(seen.last?.url?.path() == "/final")
        #expect(seen.last?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }
}
