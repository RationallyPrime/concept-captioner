@testable import ConceptCore
import Foundation
import Synchronization
import Testing

@Suite("native video caption input")
struct VideoCaptionTests {
    @Test func geminiReceivesExactVideoBytesWithStructuredSchema() async throws {
        let bytes = Data("selected-mp4-target-bytes".utf8)
        let transport = StubTransport { request in
            let body = try JSONValue(parsing: #require(request.httpBody))
            let blob = try #require(body.field("contents")?.element(0)?.field("parts")?.element(1)?.field("inlineData"))
            #expect(blob.field("mimeType") == .string("video/mp4"))
            #expect(blob.field("data") == .string(bytes.base64EncodedString()))
            #expect(body.field("contents")?.element(0)?.field("parts")?.element(1)?
                .field("videoMetadata")?.field("fps") == .int(24))
            #expect(body.field("generationConfig")?.field("responseJsonSchema") == Caption.jsonSchema)
            return try StubTransport
                .json(
                    [
                        "candidates": [
                            ["content": ["parts": [["text": "{\"caption\":\"NORA7 moves across the room.\"}"]]]],
                        ],
                    ]
                )
        }
        let client = GeminiClient(apiKey: "fixture", model: "gemini-3.8-flash", transport: transport)
        let reply = try await client.request(
            instructions: "Inspect the exact selected segment in chronological order.",
            messages: [.user([.text("Caption this clip."), .video(data: bytes, mediaType: "video/mp4")])],
            output: OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .native),
            settings: RequestSettings()
        )
        #expect(reply.text.contains("NORA7"))
        #expect(await transport.requests.count == 1)
    }

    @Test func unsupportedProvidersRefuseBeforeTransportAndChatGPTTokenAccess() async throws {
        let transport = StubTransport { _ in
            Issue.record("Unsupported video reached transport"); return HTTPResponse(status: 500)
        }
        let clients: [any ModelClient] = try [
            AnthropicClient(apiKey: "fixture", model: "claude-fixture", transport: transport),
            OpenAICompatibleClient(
                baseURL: #require(URL(string: "https://fixture.invalid/v1")),
                apiKey: "fixture",
                model: "fixture",
                transport: transport
            ),
            OpenAIResponsesClient(
                baseURL: OpenAIResponsesClient.openAIBaseURL,
                apiKey: "fixture",
                model: "gpt-fixture",
                transport: transport
            ),
        ]
        let messages: [ChatMessage] = [.user([.video(data: Data([1, 2, 3]), mediaType: "video/mp4")])]
        let output = OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .native)
        for client in clients {
            await #expect(throws: ConfigurationError.self) {
                try await client.request(
                    instructions: "Caption.",
                    messages: messages,
                    output: output,
                    settings: RequestSettings()
                )
            }
        }
        let reads = Mutex(0)
        let chatGPT = ChatGPTModelClient(
            model: "gpt-fixture",
            accessToken: { reads.withLock { $0 += 1 }; return "fixture" }
        )
        await #expect(throws: ConfigurationError.self) {
            try await chatGPT.request(
                instructions: "Caption.",
                messages: messages,
                output: output,
                settings: RequestSettings()
            )
        }
        #expect(reads.withLock { $0 } == 0)
        #expect(await transport.requests.isEmpty)
    }

    @Test func oversizedVideoDoesNotReachTransportOrSubstituteFrames() async throws {
        let transport = StubTransport { _ in
            Issue.record("Oversized video reached transport"); return HTTPResponse(status: 500)
        }
        let client = GeminiClient(apiKey: "fixture", model: "gemini-3.8-flash", transport: transport)
        await #expect(throws: ConfigurationError.self) {
            try await client.request(
                instructions: "Caption.", messages: [.user([.video(
                    data: Data(count: 16 * 1024 * 1024),
                    mediaType: "video/mp4"
                )])],
                output: OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .native),
                settings: RequestSettings()
            )
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func localVideoTargetsPreserveIdsBytesAndStemCollisionRule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([8, 9, 10])
        try bytes.write(to: directory.appendingPathComponent("clip.mp4"))
        try Data([1]).write(to: directory.appendingPathComponent("image.png"))
        let source = try LocalFolderSource(directory: directory)
        #expect(source.files.map(\.lastPathComponent) == ["clip.mp4", "image.png"])
        var samples: [Sample] = []
        for try await sample in source.samples(only: ["clip.mp4"]) {
            samples.append(sample)
        }
        #expect(samples.map(\.sampleID) == ["clip.mp4"])
        #expect(samples[0].data == bytes)
        #expect(try MediaInput.content(data: samples[0].data, suffix: samples[0].suffix) == .video(
            data: bytes,
            mediaType: "video/mp4"
        ))
        try Data([1]).write(to: directory.appendingPathComponent("clip.png"))
        #expect(throws: ConfigurationError.self) { try LocalFolderSource(directory: directory) }
    }
}
