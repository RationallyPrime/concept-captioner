@testable import ConceptCore
import Foundation
import Testing

private enum GatewayWire {
    static let caption = #"{"caption":"NORA7","usable":true,"note":null}"#
    static let keys = StaticKeyStore([
        .openrouter: "router-key", .vercel: "vercel-key", .gateway: "pylf_v1_us_test",
        .openai: "direct-openai", .anthropic: "direct-anthropic", .google: "direct-google",
    ])

    static func transport() throws -> StubTransport {
        let reply = try StubTransport.json([
            "model": "served", "modelVersion": "served",
            "choices": [["message": ["content": caption]]],
            "content": [["type": "text", "text": caption]],
            "candidates": [["content": ["parts": [["text": caption]]]]],
            "output": [["type": "message", "content": [["type": "output_text", "text": caption]]]],
        ])
        return StubTransport { _ in reply }
    }

    static func request(_ resolved: ResolvedEndpoint) async throws -> ModelReply {
        try await resolved.client.request(
            instructions: "Caption.",
            messages: [.user([.text("Image."), .image(data: Data([1, 2]), mediaType: "image/png")])],
            output: OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: resolved.outputMode),
            settings: resolved.settings
        )
    }
}

@Suite("gateway routing and authentication")
struct GatewayTests {
    @Test(arguments: [
        ("openrouter", "anthropic/claude-opus-5", "https://openrouter.ai/api/v1/chat/completions"),
        ("vercel", "anthropic/claude-opus-5", "https://ai-gateway.vercel.sh/v1/chat/completions"),
        ("gateway/openai", "gpt-5.2", "https://gateway-us.pydantic.dev/proxy/openai/responses"),
        ("gateway/openai-responses", "gpt-5.2", "https://gateway-us.pydantic.dev/proxy/openai/responses"),
        ("gateway/openai-chat", "gpt-5.2", "https://gateway-us.pydantic.dev/proxy/openai/chat/completions"),
        ("gateway/responses", "gpt-5.2", "https://gateway-us.pydantic.dev/proxy/openai/responses"),
        ("gateway/chat", "gpt-5.2", "https://gateway-us.pydantic.dev/proxy/openai/chat/completions"),
        ("openai", "gpt-5.2", "https://api.openai.com/v1/responses"),
        ("gateway/anthropic", "claude-opus-5", "https://gateway-us.pydantic.dev/proxy/anthropic/v1/messages"),
        (
            "gateway/google",
            "gemini-3.8-flash",
            "https://gateway-us.pydantic.dev/proxy/google-vertex/v1beta1/publishers/google/models/gemini-3.8-flash:generateContent"
        ),
        (
            "gateway/google-cloud",
            "gemini-3.8-flash",
            "https://gateway-us.pydantic.dev/proxy/google-vertex/v1beta1/publishers/google/models/gemini-3.8-flash:generateContent"
        ),
    ])
    func nativeWire(kind: String, model: String, url: String) async throws {
        let transport = try GatewayWire.transport()
        let resolved = try Endpoints.resolve("\(kind):\(model)", keys: GatewayWire.keys, transport: transport)
        let reply = try await GatewayWire.request(resolved)
        #expect(reply.text == GatewayWire.caption)
        #expect(resolved.requested == model)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == url)
        let key = switch kind {
        case _ where kind.hasPrefix("gateway/"): "pylf_v1_us_test"
        case "vercel": "vercel-key"
        case "openai": "direct-openai"
        default: "router-key"
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == (kind.contains("google") ? key : nil))
        let body = try JSONValue(parsing: #require(request.httpBody))
        #expect(body.field("model")?.stringValue == (kind.contains("google") ? nil : model))
        // Every Responses request opts out of retention; Chat Completions bodies carry no store.
        #expect(body.field("store") == (url.hasSuffix("/responses") ? .bool(false) : nil))
    }

    @Test(arguments: ["us", "eu"])
    func keyRegionChoosesFixedHost(_ region: String) async throws {
        let transport = try GatewayWire.transport()
        let resolved = try Endpoints.resolve(
            "gateway/openai:gpt-5.2", keys: StaticKeyStore([.gateway: "pylf_v1_\(region)_test"]), transport: transport
        )
        _ = try await GatewayWire.request(resolved)
        #expect(await transport.requests.first?.url?.host() == "gateway-\(region).pydantic.dev")
    }

    @Test(arguments: ["openrouter", "vercel", "gateway/openai", "gateway/anthropic", "gateway/google"])
    func refusesJobHost(kind: String) throws {
        let error = #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(
                EndpointSpec(kind: kind, model: "model", baseURL: "https://job-controlled.test"), keys: GatewayWire.keys
            )
        }
        #expect(error?.message == "base_url is only meaningful for kind vllm, not '\(kind)'")
    }

    @Test(arguments: ["gateway", "gateway/", "gateway/evil", "gateway/bedrock", "gateway/groq"])
    func unsupportedProviderIsConfigurationError(_ kind: String) throws {
        #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve(EndpointSpec(kind: kind, model: "model"), keys: GatewayWire.keys)
        }
    }

    @Test(arguments: ["not-regional", "pylf_v1_evil_test", "pylf_vX_us_test", "pylf_v1_us_", "pylf_v1_us_test\n"])
    func invalidGatewayKeyIsConfigurationError(_ key: String) throws {
        let error = #expect(throws: ConfigurationError.self) {
            try Endpoints.resolve("gateway/openai:gpt-5.2", keys: StaticKeyStore([.gateway: key]))
        }
        #expect(error?.message == "Pydantic AI Gateway key must encode the supported us or eu region")
    }

    @Test func requiresOwnKey() throws {
        for (spec, provider): (String, Provider) in [
            ("vercel:openai/gpt-5.2", .vercel),
            ("gateway/openai:gpt-5.2", .gateway),
        ] {
            let error = #expect(throws: ModelError.self) {
                try Endpoints.resolve(spec, keys: StaticKeyStore([.openai: "direct", .anthropic: "direct"]))
            }
            guard case let .missingKey(actual) = error else { Issue.record("expected missing key"); continue }
            #expect(actual == provider)
        }
    }

    @Test(arguments: [(ThinkingLevel.minimal, "low"), (.medium, "medium"), (.xhigh, "high")])
    func openRouterReasoning(level: ThinkingLevel, effort: String) async throws {
        let transport = try GatewayWire.transport()
        let resolved = try Endpoints.resolve(
            "openrouter:openai/gpt-5.2", thinking: level, keys: GatewayWire.keys, transport: transport
        )
        _ = try await GatewayWire.request(resolved)
        let body = try JSONValue(parsing: #require(await transport.requests.first?.httpBody))
        #expect(body.field("reasoning") == .object(["effort": .string(effort), "enabled": .bool(true)]))
        #expect(body.field("reasoning_effort") == nil)
    }
}

@Suite("Responses gateway wire")
struct ResponsesGatewayTests {
    @Test(arguments: [OutputMode.native, .tool, .prompted])
    func outputModes(_ mode: OutputMode) async throws {
        let response = try StubTransport.json([
            "model": "gpt-5.2-served",
            "output": mode == .tool
                ? [["type": "function_call", "name": "Caption", "arguments": GatewayWire.caption]]
                : [["type": "message", "content": [["type": "output_text", "text": GatewayWire.caption]]]],
            "usage": ["input_tokens": 8, "output_tokens": 13],
        ])
        let transport = StubTransport { _ in response }
        let resolved = try Endpoints.resolve(
            EndpointSpec(kind: "gateway/openai", model: "gpt-5.2", outputMode: mode, settings: [
                "max_tokens": .int(300), "top_p": .double(0.7), "extra_headers": .object(["X-Title": .string("test")]),
            ]),
            thinking: .low, keys: GatewayWire.keys, transport: transport
        )
        let reply = try await GatewayWire.request(resolved)
        #expect(reply.text == GatewayWire.caption)
        #expect(reply.servedModel == "gpt-5.2-served")
        #expect(reply.usage == TokenUsage(inputTokens: 8, outputTokens: 13))
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Title") == "test")
        let body = try JSONValue(parsing: #require(request.httpBody))
        let input = try #require(body.field("input")?.arrayValue)
        // The system prompt is `instructions`, except prompted mode, where json_object needs it in input.
        let user = mode == .prompted ? input[1] : input[0]
        #expect(input.count == (mode == .prompted ? 2 : 1))
        #expect(input[0].field("role")?.stringValue == (mode == .prompted ? "system" : "user"))
        if mode == .prompted {
            #expect(body.field("instructions") == nil)
        } else {
            #expect(body.field("instructions")?.stringValue?.hasPrefix("Caption.") == true)
        }
        #expect(user.field("content")?.element(0)?.field("type")?.stringValue == "input_text")
        #expect(user.field("content")?.element(1)?.field("image_url")?.stringValue == "data:image/png;base64,AQI=")
        #expect(body.field("store") == .bool(false))
        #expect(body.field("max_output_tokens") == .int(300))
        #expect(body.field("reasoning") == .object(["effort": .string("low")]))
        if mode == .tool {
            #expect(body.field("tools")?.element(0)?.field("parameters") == Caption.jsonSchema)
            #expect(body.field("tool_choice") == .object(["type": .string("function"), "name": .string("Caption")]))
            #expect(body.field("text") == nil)
        } else {
            let type = mode == .native ? "json_schema" : "json_object"
            #expect(body.field("text")?.field("format")?.field("type")?.stringValue == type)
            if mode == .native { #expect(body.field("text")?.field("format")?.field("schema") == Caption.jsonSchema) }
            if mode == .prompted { #expect(input[0].field("content")?.stringValue?.contains("JSON object") == true) }
        }
    }

    @Test func extraBodyCannotTurnRetentionBackOn() {
        let body = OpenAIResponsesClient.body(
            model: "gpt-5.2", instructions: "Caption.", messages: [.user("Image.")],
            output: OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .native),
            settings: RequestSettings(extraBody: ["store": .bool(true)])
        )
        #expect(body["store"] == .bool(false))
    }

    @Test func refusalAndMalformedRepliesAreErrors() throws {
        for response: JSONValue in [
            .object(["output": .array([])]),
            .object(["output": .array([.object(["type": .string("message"), "content": .array([
                .object(["type": .string("refusal"), "refusal": .string("declined")]),
            ])])])]),
        ] {
            #expect(throws: ModelError.self) { try OpenAIResponsesClient.parse(response, mode: .native) }
        }
    }
}
