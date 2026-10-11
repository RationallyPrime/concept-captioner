@testable import ConceptCore
import Foundation
import Testing

private enum ThinkingWire {
    static let output = OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .prompted)
    static let caption = #"{"caption":"NORA7","usable":true,"note":null}"#

    static func body(
        _ model: String,
        settings: RequestSettings,
        anthropic: Bool = false,
        api: GeminiClient.API = .developer
    ) async throws -> JSONValue {
        let response = try StubTransport.json(anthropic
            ? ["content": [["type": "text", "text": caption]]]
            : ["candidates": [["content": ["parts": [["text": caption]]]]]])
        let transport = StubTransport { _ in response }
        let client: any ModelClient = anthropic
            ? AnthropicClient(apiKey: "test", model: model, transport: transport)
            : GeminiClient(apiKey: "test", model: model, transport: transport, api: api)
        _ = try await client.request(
            instructions: "Caption.", messages: [.user("Image.")], output: output, settings: settings
        )
        return try await JSONValue(parsing: #require(transport.requests.first?.httpBody))
    }
}

@Suite("provider thinking families")
struct ProviderThinkingTests {
    @Test(arguments: [
        (ThinkingLevel.minimal, 1024), (.low, 2048), (.medium, 10000), (.high, 16384), (.xhigh, 32768),
    ])
    func claudeBudget(level: ThinkingLevel, budget: Int) async throws {
        let body = try await ThinkingWire.body(
            "claude-sonnet-4-5", settings: RequestSettings(thinking: level), anthropic: true
        )
        #expect(body.field("thinking") == .object(["type": .string("enabled"), "budget_tokens": .int(budget)]))
        #expect(body.field("output_config")?.field("effort") == nil)
        #expect((body.field("max_tokens")?.intValue ?? 0) > budget)
    }

    @Test func claudeBooleanBudgetAndExplicitLimit() async throws {
        let body = try await ThinkingWire.body(
            "claude-sonnet-4-5", settings: RequestSettings(thinkingAtProviderDefault: true), anthropic: true
        )
        #expect(body.field("thinking")?.field("budget_tokens") == .int(10000))
        let error = await #expect(throws: ConfigurationError.self) {
            try await ThinkingWire.body(
                "claude-sonnet-4-5", settings: RequestSettings(thinking: .high, maxTokens: 16000), anthropic: true
            )
        }
        #expect(error?.message.contains("max_tokens greater than 16384") == true)
    }

    @Test(arguments: [
        ("claude-opus-4-5", "enabled", "max"), ("claude-opus-4-6", "adaptive", "max"),
        ("claude-sonnet-4-6", "adaptive", "max"), ("claude-opus-4-7", "adaptive", "xhigh"),
        ("claude-opus-5-5", "adaptive", "xhigh"),
    ])
    func claudeEffort(model: String, type: String, effort: String) async throws {
        let body = try await ThinkingWire.body(model, settings: RequestSettings(thinking: .xhigh), anthropic: true)
        #expect(body.field("thinking")?.field("type")?.stringValue == type)
        #expect(body.field("output_config")?.field("effort")?.stringValue == effort)
    }

    @Test(arguments: [
        (ThinkingLevel.minimal, 128), (.low, 2048), (.medium, 8192), (.high, 24576), (.xhigh, 24576),
    ])
    func geminiBudget(level: ThinkingLevel, budget: Int) async throws {
        let body = try await ThinkingWire.body("gemini-2.5-flash", settings: RequestSettings(thinking: level))
        let config = body.field("generationConfig")?.field("thinkingConfig")
        #expect(config?.field("thinkingBudget") == .int(budget))
        #expect(config?.field("thinkingLevel") == nil)
        #expect(config?.field("includeThoughts") == .bool(true))
    }

    @Test(arguments: [
        ("gemini-3-pro-preview", ThinkingLevel.medium, "low"),
        ("gemini-3.1-pro-preview", .medium, "medium"),
        ("gemini-3.8-flash", .minimal, "low"),
        ("gemini-3-flash-preview", .minimal, "minimal"),
        ("gemini-3.1-flash-image-preview", .medium, "high"),
    ])
    func geminiSupportedLevel(model: String, level: ThinkingLevel, expected: String) async throws {
        let body = try await ThinkingWire.body(model, settings: RequestSettings(thinking: level))
        #expect(body.field("generationConfig")?.field("thinkingConfig")?.field("thinkingLevel")?
            .stringValue == expected)
    }

    @Test(arguments: ["gemini-2.0-flash", "gemini-pro"])
    func olderGeminiOmitsThinking(_ model: String) async throws {
        let body = try await ThinkingWire.body(model, settings: RequestSettings(thinking: .medium))
        #expect(body.field("generationConfig")?.field("thinkingConfig") == nil)
    }

    @Test func vertexKeepsItsFullImageModelThinkingScale() async throws {
        let body = try await ThinkingWire.body(
            "gemini-3.1-flash-image-preview", settings: RequestSettings(thinking: .medium), api: .vertex
        )
        #expect(body.field("generationConfig")?.field("thinkingConfig")?.field("thinkingLevel")?
            .stringValue == "medium")
    }

    @Test(arguments: [false, true])
    func openAIRejectionNamesModelAndEffort(responses: Bool) async throws {
        let parameter = responses ? "reasoning.effort" : "reasoning_effort"
        let providerMessage = #"{"error":{"message":"Unsupported parameter: "# + parameter + #""}}"#
        let transport = StubTransport { _ in HTTPResponse(status: 400, body: Data(providerMessage.utf8)) }
        let client: any ModelClient = responses
            ? OpenAIResponsesClient(
                baseURL: OpenAIResponsesClient.openAIBaseURL, apiKey: "test", model: "gpt-4o", transport: transport
            )
            : try OpenAICompatibleClient(
                baseURL: #require(URL(string: "http://pod:8000/v1")), apiKey: "test", model: "gpt-4o",
                transport: transport
            )
        let error = await #expect(throws: ModelError.self) {
            try await client.request(
                instructions: "Caption.", messages: [.user("Image.")], output: ThinkingWire.output,
                settings: RequestSettings(thinking: .low)
            )
        }
        guard case let .http(status, body) = error else { Issue.record("expected HTTP error"); return }
        #expect(status == 400)
        #expect(body.contains("model 'gpt-4o' rejected thinking 'low'"))
        #expect(body.contains(providerMessage))
        #expect(await transport.requests.count == 1)
    }

    @Test func gatewayBearerAuthDoesNotChangeTheGeminiAPIFlavour() async throws {
        let response = try StubTransport
            .json(["candidates": [["content": ["parts": [["text": ThinkingWire.caption]]]]]])
        let transport = StubTransport { _ in response }
        let client = GeminiClient(
            apiKey: "test", model: "gemini-3.1-flash-image-preview", transport: transport, bearerAuth: true
        )
        _ = try await client.request(
            instructions: "Caption.", messages: [.user("Image.")], output: ThinkingWire.output,
            settings: RequestSettings(thinking: .medium)
        )
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        let body = try JSONValue(parsing: #require(request.httpBody))
        // Developer API scale [minimal, high]: medium rounds to high, as without bearer auth.
        #expect(body.field("generationConfig")?.field("thinkingConfig")?.field("thinkingLevel")?
            .stringValue == "high")
    }

    @Test func reasoningDialectComesFromTheClientNotTheHost() async throws {
        let reply = try StubTransport.json(["choices": [["message": ["content": ThinkingWire.caption]]]])
        for dialect in [OpenAICompatibleClient.ReasoningDialect.reasoningEffort, .openRouter] {
            let transport = StubTransport { _ in reply }
            let client = OpenAICompatibleClient(
                baseURL: OpenAICompatibleClient.openRouterBaseURL, apiKey: "test", model: "m", transport: transport,
                reasoningDialect: dialect
            )
            _ = try await client.request(
                instructions: "Caption.", messages: [.user("Image.")], output: ThinkingWire.output,
                settings: RequestSettings(thinking: .high)
            )
            let body = try await JSONValue(parsing: #require(transport.requests.first?.httpBody))
            #expect((body.field("reasoning_effort") != nil) == (dialect == .reasoningEffort))
            #expect((body.field("reasoning") != nil) == (dialect == .openRouter))
        }
    }
}
