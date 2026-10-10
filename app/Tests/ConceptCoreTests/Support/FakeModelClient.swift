// A scripted ModelClient that records every request. Python counterpart: conftest.function_model.

import ConceptCore
import Foundation

public actor FakeModelClient: ModelClient {
    public struct Request: Sendable {
        public let instructions: String
        public let messages: [ChatMessage]
        public let output: OutputRequest
        public let settings: RequestSettings

        /// Images attached anywhere in the conversation.
        public var images: [UserContent] {
            messages.flatMap(\.content).filter {
                if case .image = $0 { return true }
                return false
            }
        }

        /// The last message's text parts joined.
        public var lastText: String {
            messages.last?.content.compactMap {
                if case let .text(text) = $0 { return text }
                return nil
            }.joined(separator: "\n") ?? ""
        }
    }

    public struct Reply: Sendable {
        public var text: String
        public var servedModel: String?

        public init(text: String, servedModel: String? = nil) {
            self.text = text
            self.servedModel = servedModel
        }

        public init(encoding value: some Encodable, servedModel: String? = nil) throws {
            guard let encoded = try String(bytes: JSONEncoder().encode(value), encoding: .utf8) else {
                throw ConfigurationError("reply is not UTF-8")
            }
            text = encoded
            self.servedModel = servedModel
        }
    }

    public nonisolated let requestedModel: String
    public private(set) var requests: [Request] = []
    public private(set) var inFlight = 0
    public private(set) var maxInFlight = 0

    private let respond: @Sendable (Request) async throws -> Reply

    public init(model: String = "fake", respond: @escaping @Sendable (Request) async throws -> Reply) {
        requestedModel = model
        self.respond = respond
    }

    public func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) async throws -> ModelReply {
        let request = Request(instructions: instructions, messages: messages, output: output, settings: settings)
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        let reply = try await respond(request)
        return ModelReply(text: reply.text, servedModel: reply.servedModel ?? requestedModel)
    }

    /// Always returns this caption.
    public static func caption(_ caption: Caption, model: String = "fake") -> FakeModelClient {
        FakeModelClient(model: model) { _ in try Reply(encoding: caption) }
    }

    /// Always returns this critique.
    public static func critique(_ critique: Critique, model: String = "fake") -> FakeModelClient {
        FakeModelClient(model: model) { _ in try Reply(encoding: critique) }
    }
}
