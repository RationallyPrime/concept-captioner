// EndpointSpec.settings is a language-neutral contract: every unified pydantic-ai ModelSettings
// key the Python package forwards must be accepted here and reach the wire the way pydantic-ai
// sends it. See docs/CORE-SPEC.md, `RequestSettings` and each client's `settings:` line.

import ConceptCore
import CoreGraphics
import Foundation
import Testing

private extension JSONValue {
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

private enum Support {
    static let keys = StaticKeyStore([.google: "g-key", .anthropic: "a-key", .openai: "o-key", .openrouter: "r-key"])
    static let png = Fixtures.syntheticPNG(seed: 1, size: CGSize(width: 24, height: 24))
    static let instructions = "You caption images."
    static let captionJSON = #"{"caption": "A photo of NORA7.", "usable": true, "note": null}"#
    static let turn: [ChatMessage] = [.user([.text("Inspect this image."), .image(data: png, mediaType: "image/png")])]

    static func output(_ mode: OutputMode) -> OutputRequest {
        OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: mode)
    }

    static func replying(_ object: Any) throws -> StubTransport {
        let response = try StubTransport.json(object)
        return StubTransport { _ in response }
    }

    static func body(_ transport: StubTransport) async throws -> JSONValue {
        try await JSONValue(parsing: transport.requests[0].httpBody ?? Data())
    }
}

@Suite("modelclient settings")
struct RequestSettingsTests {
    /// Every unified pydantic-ai ModelSettings key is accepted, so a job file runs under both implementations.
    @Test func acceptsThePydanticAISettingsKeySet() throws {
        let settings = try RequestSettings(
            settings: [
                "top_k": .int(40),
                "stop_sequences": .array([.string("\n\n"), .string("END")]),
                "presence_penalty": .double(0.1),
                "frequency_penalty": .int(1),
                "logit_bias": .object(["50256": .int(-100)]),
                "parallel_tool_calls": .bool(false),
                "service_tier": .string("flex"),
                "extra_headers": .object(["X-Title": .string("concept-captioner")]),
                "timeout": .int(120),
                "tool_choice": .string("auto"),
                "cache": .bool(true),
                "extra_body": .object(["min_p": .double(0.05)]),
            ],
            thinking: .low
        )
        #expect(settings.topK == 40)
        #expect(settings.stopSequences == ["\n\n", "END"])
        #expect(settings.presencePenalty == 0.1)
        #expect(settings.frequencyPenalty == 1)
        #expect(settings.logitBias == ["50256": -100])
        #expect(settings.parallelToolCalls == false)
        #expect(settings.serviceTier == "flex")
        #expect(settings.extraHeaders == ["X-Title": "concept-captioner"])
        #expect(settings.ignoredKeys == ["timeout", "tool_choice", "cache"])
        #expect(settings.extraBody["min_p"] == .double(0.05))
        #expect(settings.thinking == .low)
        #expect(settings.thinkingEffort == .low)

        // The review scenario: the same job file resolves in Swift as it runs in Python.
        let resolved = try Endpoints.resolve(
            EndpointSpec(
                kind: "vllm",
                model: "Qwen/x",
                baseURL: "http://localhost:8000/v1",
                settings: ["top_k": .int(40), "stop_sequences": .array([.string("\n\n")])]
            ),
            keys: StaticKeyStore([:])
        )
        #expect(resolved.settings.topK == 40)
        #expect(resolved.settings.stopSequences == ["\n\n"])
    }

    @Test func rejectsMistypedValues() throws {
        for bad: JSONObject in [
            ["thinking": .string("lots")], ["thinking": .int(1)],
            ["stop_sequences": .string("\n\n")], ["stop_sequences": .array([.int(1)])],
            ["logit_bias": .object(["50256": .string("-100")])], ["extra_headers": .object(["X-A": .int(1)])],
            ["parallel_tool_calls": .string("yes")], ["service_tier": .string("turbo")], ["top_k": .double(0.5)],
        ] {
            #expect(throws: ConfigurationError.self) { try RequestSettings(settings: bad, thinking: .none) }
        }
        let prefixed = #expect(throws: ConfigurationError.self) {
            try RequestSettings(settings: ["openai_reasoning_effort": .string("low")], thinking: .none)
        }
        #expect(prefixed?.message == "unsupported setting 'openai_reasoning_effort'")
    }

    /// pydantic-ai `thinking: bool | effort`: true is on at the provider's default effort, false is off.
    @Test func booleanThinking() throws {
        let on = try RequestSettings(settings: ["thinking": .bool(true)], thinking: .none)
        #expect(on.thinks)
        #expect(on.thinkingAtProviderDefault)
        #expect(on.thinkingEffort == nil)

        let off = try RequestSettings(settings: ["thinking": .bool(false)], thinking: .high)
        #expect(!off.thinks)
        #expect(off.thinking == .none)
        #expect(off.thinkingEffort == nil)

        let level = try RequestSettings(settings: ["thinking": .string("medium")], thinking: .none)
        #expect(level.thinks)
        #expect(!level.thinkingAtProviderDefault)
        #expect(level.thinkingEffort == .medium)

        let viaResolve = try Endpoints.resolve(
            EndpointSpec(kind: "anthropic", model: "claude-opus-5-5", settings: ["thinking": .bool(true)]),
            thinking: .low,
            keys: Support.keys
        )
        #expect(viaResolve.settings.thinks)
        #expect(viaResolve.settings.thinkingEffort == nil)
    }
}

@Suite("modelclient settings on the wire")
struct SettingsOnTheWireTests {
    /// The unified keys Chat Completions expresses, and `thinking: true` as pydantic-ai sends it.
    @Test func openAICompatible() async throws {
        let base = try #require(URL(string: "http://pod:8000/v1"))
        let transport = try Support.replying([
            "model": "gpt-5.2",
            "choices": [["message": [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [["type": "function", "function": ["name": "Caption", "arguments": Support.captionJSON]]],
            ]]],
        ])
        _ = try await OpenAICompatibleClient(baseURL: base, apiKey: "sk-test", model: "gpt-5.2", transport: transport)
            .request(
                instructions: Support.instructions,
                messages: Support.turn,
                output: Support.output(.tool),
                settings: RequestSettings(
                    thinkingAtProviderDefault: true,
                    topK: 40,
                    stopSequences: ["\n\n"],
                    presencePenalty: 0.1,
                    frequencyPenalty: 0.2,
                    logitBias: ["50256": -100],
                    parallelToolCalls: false,
                    serviceTier: "flex",
                    extraHeaders: ["X-Title": "concept-captioner"]
                )
            )
        let request = await transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "X-Title") == "concept-captioner")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try await Support.body(transport)
        #expect(body["reasoning_effort"]?.stringValue == "medium", "thinking: true is medium in pydantic-ai's map")
        #expect(body["stop"] == .array([.string("\n\n")]))
        #expect(body["presence_penalty"] == .double(0.1))
        #expect(body["frequency_penalty"] == .double(0.2))
        #expect(body["logit_bias"] == .object(["50256": .int(-100)]))
        #expect(body["service_tier"]?.stringValue == "flex")
        #expect(body["parallel_tool_calls"] == .bool(false))
        #expect(body["top_k"] == nil, "not a Chat Completions parameter; pydantic-ai drops it too")

        let native = try Support.replying([
            "model": "gpt-5.2",
            "choices": [["message": ["role": "assistant", "content": Support.captionJSON]]],
        ])
        _ = try await OpenAICompatibleClient(baseURL: base, apiKey: nil, model: "gpt-5.2", transport: native)
            .request(
                instructions: Support.instructions,
                messages: Support.turn,
                output: Support.output(.native),
                settings: RequestSettings(parallelToolCalls: true)
            )
        let nativeBody = try await Support.body(native)
        #expect(nativeBody["parallel_tool_calls"] == nil, "only sent alongside tools")
    }

    /// top_k joins the sampling trio, stop_sequences and service_tier map as pydantic-ai maps them,
    /// and `thinking: true` is adaptive with the effort left to the API.
    @Test func anthropic() async throws {
        let reply: [String: Any] = [
            "model": "claude-opus-5-5",
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": Support.captionJSON]],
        ]
        let sampling = try Support.replying(reply)
        _ = try await AnthropicClient(apiKey: "ak-test", model: "claude-opus-5-5", transport: sampling).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.native),
            settings: RequestSettings(
                topK: 40,
                stopSequences: ["\n\n"],
                presencePenalty: 0.5,
                serviceTier: "default",
                extraHeaders: ["anthropic-beta": "example-2026-01-01"]
            )
        )
        let request = await sampling.requests[0]
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "example-2026-01-01")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "ak-test")
        var body = try await Support.body(sampling)
        #expect(body["top_k"] == .int(40))
        #expect(body["stop_sequences"] == .array([.string("\n\n")]))
        #expect(body["service_tier"]?.stringValue == "standard_only")
        #expect(body["presence_penalty"] == nil, "the Messages API has no penalties")
        #expect(body["thinking"] == nil)

        let thinking = try Support.replying(reply)
        _ = try await AnthropicClient(apiKey: "ak-test", model: "claude-opus-5-5", transport: thinking).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.native),
            settings: RequestSettings(thinkingAtProviderDefault: true, temperature: 0.3, topK: 40, serviceTier: "flex")
        )
        body = try await Support.body(thinking)
        #expect(body["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(body["output_config"]?["effort"] == nil, "thinking: true leaves the effort to the API")
        #expect(body["temperature"] == nil)
        #expect(body["top_k"] == nil, "sampling parameters are dropped once thinking is on")
        #expect(body["service_tier"] == nil, "flex is not exposed by the Messages API")
    }

    /// generationConfig takes topK, stopSequences and both penalties; `thinking: true` is
    /// includeThoughts without a level, as pydantic-ai sends it.
    @Test func gemini() async throws {
        let transport = try Support.replying([
            "modelVersion": "gemini-3.8-flash",
            "candidates": [["content": ["role": "model", "parts": [["text": Support.captionJSON]]]]],
        ])
        _ = try await GeminiClient(apiKey: "gk-test", model: "gemini-3.8-flash", transport: transport).request(
            instructions: Support.instructions,
            messages: Support.turn,
            output: Support.output(.native),
            settings: RequestSettings(
                thinkingAtProviderDefault: true,
                topK: 40,
                stopSequences: ["\n\n"],
                presencePenalty: 0.1,
                frequencyPenalty: 0.2,
                logitBias: ["1": 1],
                serviceTier: "auto",
                extraHeaders: ["X-Title": "concept-captioner"]
            )
        )
        let request = await transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "X-Title") == "concept-captioner")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gk-test")
        let body = try await Support.body(transport)
        let generation = body["generationConfig"]
        #expect(generation?["thinkingConfig"] == .object(["includeThoughts": .bool(true)]))
        #expect(generation?["topK"] == .int(40))
        #expect(generation?["stopSequences"] == .array([.string("\n\n")]))
        #expect(generation?["presencePenalty"] == .double(0.1))
        #expect(generation?["frequencyPenalty"] == .double(0.2))
        #expect(generation?["logitBias"] == nil)
        #expect(body["serviceTier"] == nil)
        #expect(body["service_tier"] == nil)
    }
}
