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
        bearerAuth: Bool = false
    ) async throws -> JSONValue {
        let response = try StubTransport.json(anthropic
            ? ["content": [["type": "text", "text": caption]]]
            : ["candidates": [["content": ["parts": [["text": caption]]]]]])
        let transport = StubTransport { _ in response }
        let client: any ModelClient = anthropic
            ? AnthropicClient(apiKey: "test", model: model, transport: transport)
            : GeminiClient(apiKey: "test", model: model, transport: transport, bearerAuth: bearerAuth)
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
            "gemini-3.1-flash-image-preview", settings: RequestSettings(thinking: .medium), bearerAuth: true
        )
        #expect(body.field("generationConfig")?.field("thinkingConfig")?.field("thinkingLevel")?
            .stringValue == "medium")
    }

    @Test func openAIRejectionNamesModelAndEffort() async throws {
        let providerMessage = #"{"error":{"message":"Unsupported parameter: reasoning_effort"}}"#
        let transport = StubTransport { _ in HTTPResponse(status: 400, body: Data(providerMessage.utf8)) }
        let client = OpenAICompatibleClient(
            baseURL: OpenAICompatibleClient.openAIBaseURL, apiKey: "test", model: "gpt-4o", transport: transport
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
}
