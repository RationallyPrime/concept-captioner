@testable import ConceptCore
import Foundation
import Synchronization
import Testing

private actor ChatGPTStreamWire: HTTPStreamingTransport {
    private(set) var requests: [URLRequest] = []
    private let reply: @Sendable (URLRequest) async throws -> HTTPStreamResponse

    init(_ reply: @escaping @Sendable (URLRequest) async throws -> HTTPStreamResponse) {
        self.reply = reply
    }

    func send(_: URLRequest) async throws -> HTTPResponse {
        throw ConfigurationError("ChatGPT must use the streaming transport")
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        requests.append(request)
        return try await reply(request)
    }
}

private actor ChatGPTTokenCounter {
    private(set) var count = 0
    func next() -> String {
        count += 1; return "oauth-token-\(count)"
    }
}

private actor UsageLimitObserver {
    private(set) var errors: [ChatGPTInferenceError] = []
    func record(_ error: ChatGPTInferenceError) {
        errors.append(error)
    }
}

private actor StreamStarted {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
        started = true; waiter?.resume(); waiter = nil
    }

    func wait() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
}

/// Serves a scripted event stream through the real URLSession loading system. The script is
/// chosen by the request's bearer token, so parallel tests never share state.
private final class ChatGPTStreamingProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {}

    override func startLoading() {
        guard let client, let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let script = switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer offline-full-stream": ChatGPTWire.realisticStream(ending: ChatGPTWire.completed())
        case "Bearer offline-failed-stream": ChatGPTWire.realisticStream(ending: ChatGPTWire.failed())
        default: ChatGPTWire.event(ChatGPTWire.completed()).joined(separator: "\n") + "\n"
        }
        // HTTP chunk boundaries fall mid-JSON, mid-line and between the two newlines of an event
        // boundary; none of them may split or merge an event.
        var chunk = Data()
        for byte in Data(script.utf8) {
            chunk.append(byte)
            if byte == 0x0A || chunk.count == 23 {
                client.urlProtocol(self, didLoad: chunk)
                chunk = Data()
            }
        }
        if !chunk.isEmpty { client.urlProtocol(self, didLoad: chunk) }
        client.urlProtocolDidFinishLoading(self)
    }
}

private enum ChatGPTWire {
    static let caption = #"{"caption":"NORA7 wears a jacket.","usable":true,"note":null}"#
    static let output = OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .native)
    static let messages: [ChatMessage] = [
        .user([.text("Caption this image."), .image(data: Data([1, 2]), mediaType: "image/png")]),
    ]

    static func completed(status: String = "completed") -> JSONValue {
        .object([
            "type": .string("response.completed"),
            "response": .object([
                "status": .string(status), "model": .string("gpt-6.1-sol-served"),
                "output": .array([.object([
                    "type": .string("message"),
                    "content": .array([.object(["type": .string("output_text"), "text": .string(caption)])]),
                ])]),
                "usage": .object(["input_tokens": .int(8), "output_tokens": .int(13)]),
            ]),
        ])
    }

    static func failed() -> JSONValue {
        .object([
            "type": .string("response.failed"),
            "response": .object([
                "status": .string("failed"),
                "error": .object(["code": .string("server_error"), "message": .string("The model failed.")]),
            ]),
        ])
    }

    static func event(_ value: JSONValue) -> [String] {
        ["event: \(value.field("type")?.stringValue ?? "message")", "data: \(value.pythonDumps())", ""]
    }

    /// The shape of a real Responses stream: lifecycle events, the output item and its text
    /// deltas, then a terminal event. Every event ends in a blank line.
    static func realisticStream(ending terminal: JSONValue) -> String {
        let pending: JSONValue = .object(["status": .string("in_progress"), "model": .string("gpt-6.1-sol-served")])
        let item: JSONValue = .object(["type": .string("message"), "role": .string("assistant")])
        var events: [JSONValue] = [
            .object(["type": .string("response.created"), "sequence_number": .int(0), "response": pending]),
            .object(["type": .string("response.in_progress"), "sequence_number": .int(1), "response": pending]),
            .object(["type": .string("response.output_item.added"), "output_index": .int(0), "item": item]),
        ]
        let half = caption.index(caption.startIndex, offsetBy: caption.count / 2)
        for piece in [String(caption[..<half]), String(caption[half...])] {
            events.append(.object(["type": .string("response.output_text.delta"), "delta": .string(piece)]))
        }
        events.append(.object(["type": .string("response.output_text.done"), "text": .string(caption)]))
        events.append(terminal)
        return events.flatMap(event).joined(separator: "\n") + "\n"
    }

    /// A stream body delivering each line (plus its newline) as one chunk.
    static func response(_ lines: [String], status: Int = 200, headers: [String: String] = [:]) -> HTTPStreamResponse {
        HTTPStreamResponse(status: status, headers: headers, body: AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(Data((line + "\n").utf8))
            }
            continuation.finish()
        })
    }

    static func request(_ client: ChatGPTModelClient, output: OutputRequest = output) async throws -> ModelReply {
        try await client.request(
            instructions: "Keep the concept boundary.",
            messages: messages,
            output: output,
            settings: .init()
        )
    }
}

@Suite("ChatGPT plan captioning")
struct ChatGPTModelClientTests {
    private static func offlineClient(token: String, session: URLSession) -> ChatGPTModelClient {
        ChatGPTModelClient(
            model: "gpt-6.1-sol",
            accessToken: { token },
            transport: URLSessionTransport(session: session)
        )
    }

    private static func offlineSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTStreamingProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func urlSessionTransportConsumesSSEWithoutNetwork() async throws {
        let session = Self.offlineSession()
        defer { session.invalidateAndCancel() }
        let reply = try await ChatGPTWire.request(Self.offlineClient(token: "offline-oauth", session: session))
        #expect(reply.text == ChatGPTWire.caption)
    }

    @Test func urlSessionTransportSeparatesEveryEventOfARealisticStream() async throws {
        let session = Self.offlineSession()
        defer { session.invalidateAndCancel() }
        let reply = try await ChatGPTWire.request(Self.offlineClient(token: "offline-full-stream", session: session))
        #expect(reply.text == ChatGPTWire.caption)
        #expect(reply.servedModel == "gpt-6.1-sol-served")
        #expect(reply.usage == TokenUsage(inputTokens: 8, outputTokens: 13))
    }

    @Test func urlSessionTransportReportsAStreamThatEndsInFailure() async throws {
        let session = Self.offlineSession()
        defer { session.invalidateAndCancel() }
        let client = Self.offlineClient(token: "offline-failed-stream", session: session)
        let caught = await #expect(throws: ChatGPTInferenceError.self) { try await ChatGPTWire.request(client) }
        #expect(caught?.code == "server_error")
        #expect(caught?.status == 200)
        #expect(caught?.body.contains("The model failed.") == true)
    }

    @Test(arguments: [OutputMode.native, .prompted])
    func imageAndStructuredRequestUsesFreshOAuthToken(_ mode: OutputMode) async throws {
        let wire = ChatGPTStreamWire { _ in ChatGPTWire.response(ChatGPTWire.event(ChatGPTWire.completed())) }
        let tokens = ChatGPTTokenCounter()
        let client = ChatGPTModelClient(model: "gpt-6.1-sol", accessToken: { await tokens.next() }, transport: wire)
        let output = OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: mode)
        for _ in 0 ..< 2 {
            let reply = try await ChatGPTWire.request(client, output: output)
            #expect(reply.text == ChatGPTWire.caption)
            #expect(reply.servedModel == "gpt-6.1-sol-served")
            #expect(reply.usage == TokenUsage(inputTokens: 8, outputTokens: 13))
        }
        let requests = await wire.requests
        #expect(await tokens.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token-\(index + 1)")
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            let body = try JSONValue(parsing: #require(request.httpBody))
            #expect(body.field("store") == .bool(false))
            #expect(body.field("stream") == .bool(true))
            // Prompted (json_object) mode carries the system prompt as the leading input message.
            let system = mode == .native ? body.field("instructions") : body.field("input")?.element(0)?
                .field("content")
            #expect(system?.stringValue?.contains("Keep the concept boundary.") == true)
            let user = body.field("input")?.element(mode == .native ? 0 : 1)
            #expect(user?.field("role") == .string("user"))
            let parts = user?.field("content")
            #expect(parts?.element(0)?.field("type") == .string("input_text"))
            #expect(parts?.element(1)?.field("image_url") == .string("data:image/png;base64,AQI="))
            let format = body.field("text")?.field("format")
            if mode == .native {
                #expect(format?.field("schema") == Caption.jsonSchema)
                #expect(format?.field("strict") == .bool(true))
            } else {
                #expect(format?.field("type") == .string("json_object"))
                #expect(body.field("input")?.element(0)?.field("role") == .string("system"))
                #expect(system?.stringValue?.contains("JSON object") == true)
            }
            let keys: Set = ["model", "input", "text", "store", "stream"]
            #expect(try Set(#require(body.objectValue).keys) == keys.union(mode == .native ? ["instructions"] : []))
        }
    }

    @Test func replayedConversationAndThinkingUseExistingResponsesEncoders() throws {
        let client = ChatGPTModelClient(model: "gpt-6.1-sol", accessToken: { "unused" })
        let messages = ChatGPTWire.messages + [.assistant("Bad first caption."), .user("Fix the boundary.")]
        let body = try client.requestBody(
            instructions: "Policy", messages: messages, output: ChatGPTWire.output, settings: .init(thinking: .minimal)
        )
        #expect(body["reasoning"] == .object(["effort": .string("low")]))
        #expect(body["input"]?.element(1)?.field("role") == .string("assistant"))
        #expect(body["input"]?.element(1)?.field("content") == .string("Bad first caption."))
        #expect(body["input"]?.element(2)?.field("role") == .string("user"))
    }

    @Test func unsupportedSettingsCannotReadOrRedirectCredentials() async throws {
        let tokens = ChatGPTTokenCounter()
        let wire = ChatGPTStreamWire { _ in
            Issue.record("Unsupported request reached transport"); return ChatGPTWire.response([])
        }
        let client = ChatGPTModelClient(model: "gpt-6.1-sol", accessToken: { await tokens.next() }, transport: wire)
        let settings: [RequestSettings] = [
            .init(maxTokens: 400), .init(temperature: 0.2), .init(topP: 0.5), .init(seed: 5), .init(topK: 4),
            .init(stopSequences: ["END"]), .init(presencePenalty: 0.1), .init(frequencyPenalty: 0.2),
            .init(logitBias: ["12": 1]), .init(parallelToolCalls: false), .init(serviceTier: "priority"),
            .init(extraHeaders: ["Authorization": "another-secret"]), .init(extraHeaders: ["Host": "untrusted.test"]),
            .init(extraBody: ["store": .bool(true), "stream": .bool(false), "previous_response_id": .string("other")]),
            .init(ignoredKeys: ["timeout"]),
        ]
        for settings in settings {
            let error = await #expect(throws: ConfigurationError.self) {
                try await client.request(
                    instructions: "Policy",
                    messages: ChatGPTWire.messages,
                    output: ChatGPTWire.output,
                    settings: settings
                )
            }
            #expect(error?.message.contains("Remove them") == true)
        }
        let tool = OutputRequest(name: Caption.schemaName, schema: Caption.jsonSchema, mode: .tool)
        await #expect(throws: ConfigurationError.self) { try await ChatGPTWire.request(client, output: tool) }
        #expect(await tokens.count == 0)
        #expect(await wire.requests.isEmpty)
    }

    @Test(arguments: ["", "has space", "token\r\ninjected-header"])
    func invalidTokenNeverReachesHTTP(_ token: String) async {
        let wire = ChatGPTStreamWire { _ in
            Issue.record("Invalid token reached HTTP"); return ChatGPTWire.response([])
        }
        let client = ChatGPTModelClient(model: "gpt-6.1-sol", accessToken: { token }, transport: wire)
        await #expect(throws: ConfigurationError.self) { try await ChatGPTWire.request(client) }
        #expect(await wire.requests.isEmpty)
    }

    @Test func deltasCannotReplaceTheTerminalCompletedResponse() async throws {
        let delta: JSONValue = .object(["type": .string("response.output_text.delta"), "delta": .string("partial")])
        var lines = [": heartbeat", ""] + ChatGPTWire.event(delta)
        // An SSE event may span several data lines; preserve its JSON rather than treating each as a reply.
        lines += ["event: response.completed", "data: {\"type\":\"response.completed\",", "data: \"response\":"]
        let response = try #require(ChatGPTWire.completed().field("response"))
        lines += ["data: \(response.pythonDumps())}", ""]
        let script = lines
        let wire = ChatGPTStreamWire { _ in ChatGPTWire.response(script) }
        let reply = try await ChatGPTWire.request(ChatGPTModelClient(
            model: "gpt-6.1-sol",
            accessToken: { "oauth" },
            transport: wire
        ))
        #expect(reply.text == ChatGPTWire.caption)
    }

    @Test(arguments: ["response.failed", "response.incomplete", "error", "truncated", "malformed", "wrong-status"])
    func partialValidJSONDoesNotMakeFailureSuccessful(_ kind: String) async {
        let delta: JSONValue = .object([
            "type": .string("response.output_text.delta"),
            "delta": .string(ChatGPTWire.caption),
        ])
        var lines = ChatGPTWire.event(delta)
        switch kind {
        case "response.failed":
            lines += ChatGPTWire.event(.object(["type": .string(kind), "response": .object([
                "error": .object(["code": .string("server_error"), "message": .string("failed")]),
            ])]))
        case "error":
            lines += ChatGPTWire.event(.object([
                "type": .string(kind),
                "code": .string("server_error"),
                "message": .string("failed"),
            ]))
        case "response.incomplete":
            lines += ChatGPTWire.event(.object(["type": .string(kind), "response": .object([
                "incomplete_details": .object(["reason": .string("max_output_tokens")]),
            ])]))
        case "malformed": lines += ["data: {invalid", ""]
        case "wrong-status": lines += ChatGPTWire.event(ChatGPTWire.completed(status: "incomplete"))
        default: lines += ["data: [DONE]", ""]
        }
        let script = lines
        let wire = ChatGPTStreamWire { _ in ChatGPTWire.response(script) }
        let client = ChatGPTModelClient(model: "gpt-6.1-sol", accessToken: { "oauth" }, transport: wire)
        await #expect(throws: (any Error).self) { try await ChatGPTWire.request(client) }
    }

    @Test(arguments: [false, true])
    func usageLimitStopsLaterRequestsAndReportsOnce(streamed: Bool) async throws {
        let error: JSONValue = .object([
            "code": .string("subscription_sharing_usage_limit_exceeded"),
            "message": .string("limit reached"),
        ])
        let failure: JSONValue = streamed ? .object([
            "type": .string("response.failed"),
            "response": .object(["error": error]),
        ])
            : .object(["error": error])
        let wire = ChatGPTStreamWire { _ in
            ChatGPTWire.response(
                streamed ? ChatGPTWire.event(failure) : [failure.pythonDumps()],
                status: streamed ? 200 : 429,
                headers: ["x-request-id": "plan-limit-request"]
            )
        }
        let tokens = ChatGPTTokenCounter()
        let observer = UsageLimitObserver()
        let client = ChatGPTModelClient(
            model: "gpt-6.1-sol",
            accessToken: { await tokens.next() },
            onUsageLimit: { await observer.record($0) },
            transport: wire
        )
        let copy = client
        for current in [client, copy] {
            let caught = await #expect(throws: ChatGPTInferenceError.self) { try await ChatGPTWire.request(current) }
            #expect(caught?.code == "subscription_sharing_usage_limit_exceeded")
            #expect(caught?.status == (streamed ? 200 : 429))
            #expect(caught?.requestID == "plan-limit-request")
            #expect(caught?.localizedDescription.contains("Settings → Usage") == true)
            #expect(caught?.localizedDescription.hasPrefix("ChatGPT usage limit reached.") == true)
            #expect(caught?.localizedDescription.contains("plan-limit-request") == false)
            #expect(caught?.localizedDescription.contains("subscription_sharing_usage_limit_exceeded") == false)
            #expect(caught?.localizedDescription.contains("{") == false)
        }
        #expect(await wire.requests.count == 1)
        #expect(await tokens.count == 1)
        #expect(await observer.errors.count == 1)
    }

    @Test func admissionFailurePreservesStatusDetailAndRequestID() async throws {
        let wire = ChatGPTStreamWire { _ in
            ChatGPTWire.response(
                [#"{"detail":"permission not accepted"}"#],
                status: 401,
                headers: ["x-request-id": "admission-1"]
            )
        }
        let client = ChatGPTModelClient(model: "gpt-6.1-sol", accessToken: { "oauth" }, transport: wire)
        let caught = await #expect(throws: ChatGPTInferenceError.self) { try await ChatGPTWire.request(client) }
        #expect(caught?.status == 401)
        #expect(caught?.code == nil)
        #expect(caught?.body.contains("permission not accepted") == true)
        #expect(caught?.requestID == "admission-1")
        #expect(caught?.localizedDescription.contains("granted plan-use permission") == true)
    }

    @Test func cancellationStopsAnOpenStreamWithoutReturningPartialCaption() async throws {
        let started = StreamStarted()
        let cancelled = Mutex(false)
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let wire = ChatGPTStreamWire { _ in
            await started.signal()
            return HTTPStreamResponse(status: 200, body: body, cancel: {
                cancelled.withLock { $0 = true }
                continuation.finish()
            })
        }
        let client = ChatGPTModelClient(model: "gpt-6.1-sol", accessToken: { "oauth" }, transport: wire)
        let request = Task { try await ChatGPTWire.request(client) }
        await started.wait()
        for line in ChatGPTWire.event(.object([
            "type": .string("response.output_text.delta"),
            "delta": .string(ChatGPTWire.caption),
        ])) {
            continuation.yield(Data((line + "\n").utf8))
        }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(cancelled.withLock { $0 })
    }
}
