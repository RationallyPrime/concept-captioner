// ChatGPT plan inference uses OAuth credentials and the fixed public Responses endpoint.

import Foundation

public struct ChatGPTInferenceError: Error, LocalizedError, Sendable {
    public let status: Int?
    public let code: String?
    public let parameter: String?
    public let requestID: String?
    public let body: String

    public var errorDescription: String? {
        problem + " " + recovery
    }

    private var problem: String {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": "ChatGPT usage limit reached."
        case "subscription_sharing_user_not_eligible": "This ChatGPT account or workspace cannot use its plan here."
        case "subscription_sharing_unsupported_capability":
            parameter.map { "ChatGPT could not use the \($0) setting." } ?? "ChatGPT does not support this request."
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized",
             "chatpass_v2_invalid_authorization_context": "This ChatGPT connection cannot authorize this request."
        case "subscription_sharing_usage_unavailable": "ChatGPT could not check your available usage."
        case "subscription_sharing_user_unavailable": "ChatGPT could not load the selected account."
        case "subscription_sharing_invalid_user": "ChatGPT could not verify the selected account."
        default:
            switch status {
            case 401: "ChatGPT did not accept this sign-in."
            case 403: "ChatGPT blocked this request."
            case 503: "ChatGPT is temporarily unavailable."
            default: "ChatGPT could not complete this request."
            }
        }
    }

    private var recovery: String {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            "Pause captioning and check ChatGPT Settings → Usage. No API-key billing was used."
        case "subscription_sharing_user_not_eligible":
            "ChatGPT plan use is unavailable for this account or workspace. Choose an eligible account."
        case "subscription_sharing_unsupported_capability":
            "Remove the unsupported setting or choose a supported model, then try again."
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized",
             "chatpass_v2_invalid_authorization_context":
            "Check this integration's ChatGPT permissions. No other billing route was used."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            "ChatGPT availability could not be checked. Keep the account connected and try again later."
        case "subscription_sharing_invalid_user":
            "Check the selected ChatGPT account and its sign-in permission."
        default:
            switch status {
            case 401: "Check the selected ChatGPT account and granted plan-use permission."
            case 403: "ChatGPT blocked this request because of an account, workspace or regional restriction."
            case 503: "ChatGPT is temporarily unavailable. Keep the account connected and try again later."
            default: "Check the selected ChatGPT model and settings before trying again."
            }
        }
    }

    init(status: Int? = nil, headers: [String: String], envelope: JSONValue?, body: String) {
        self.status = status
        let error = envelope?.field("error") ?? envelope?.field("response")?.field("error") ?? envelope
        code = error?.field("code")?.stringValue
        parameter = error?.field("param")?.stringValue
        requestID = headers["x-request-id"]
        self.body = body
    }
}

public struct ChatGPTModelClient: ModelClient {
    public let requestedModel: String
    public let transport: any HTTPStreamingTransport
    private let accessToken: @Sendable () async throws -> String
    private let onUsageLimit: (@Sendable (ChatGPTInferenceError) async -> Void)?
    private let usageLimit = ChatGPTUsageLimit()

    public init(
        model: String,
        accessToken: @escaping @Sendable () async throws -> String,
        onUsageLimit: (@Sendable (ChatGPTInferenceError) async -> Void)? = nil,
        transport: any HTTPStreamingTransport = URLSessionTransport()
    ) {
        requestedModel = model
        self.accessToken = accessToken
        self.onUsageLimit = onUsageLimit
        self.transport = transport
    }

    public func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) async throws -> ModelReply {
        let body = try requestBody(instructions: instructions, messages: messages, output: output, settings: settings)
        try await usageLimit.check()
        try Task.checkCancellation()
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ConfigurationError("Connect your ChatGPT account before captioning.")
        }
        try Task.checkCancellation()
        try await usageLimit.check()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = JSONValue.object(body).pythonDumpsData()
        do {
            let response = try await transport.stream(request)
            defer { response.cancel() }
            guard (200 ..< 300).contains(response.status) else { throw try await httpFailure(response) }
            return try await completedReply(response, mode: output.mode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChatGPTInferenceError {
            if error.code == "subscription_sharing_usage_limit_exceeded", await usageLimit.record(error) {
                await onUsageLimit?(error)
            }
            throw error
        } catch let error as ModelError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ModelError.transport(ProviderHTTP.describe(error))
        }
    }

    func requestBody(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) throws -> JSONObject {
        guard !requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError("Choose a model available to your connected ChatGPT account.")
        }
        try Self.validate(settings: settings, outputMode: output.mode)
        var body: JSONObject = [
            "model": .string(requestedModel),
            "instructions": .string(output.instructions(instructions)),
            "input": .array(messages.map(OpenAIResponsesClient.encode)),
            "text": OpenAIResponsesClient.textFormat(output),
            "store": .bool(false), "stream": .bool(true),
        ]
        body["reasoning"] = OpenAIResponsesClient.reasoning(settings, model: requestedModel)
        return body
    }

    public static func validate(settings: RequestSettings, outputMode: OutputMode) throws {
        guard outputMode != .tool else {
            throw ConfigurationError(
                "ChatGPT captioning supports Native or Prompted JSON output. Select one of those modes."
            )
        }
        let unsupported: [(String, Bool)] = [
            ("temperature", settings.temperature != nil), ("max_tokens", settings.maxTokens != nil),
            ("seed", settings.seed != nil), ("top_p", settings.topP != nil), ("top_k", settings.topK != nil),
            ("stop_sequences", settings.stopSequences != nil), ("presence_penalty", settings.presencePenalty != nil),
            ("frequency_penalty", settings.frequencyPenalty != nil), ("logit_bias", settings.logitBias != nil),
            ("parallel_tool_calls", settings.parallelToolCalls != nil), ("service_tier", settings.serviceTier != nil),
            ("extra_headers", !settings.extraHeaders.isEmpty), ("extra_body", !settings.extraBody.isEmpty),
        ]
        let names = unsupported.filter(\.1).map(\.0) + settings.ignoredKeys
        guard names.isEmpty else {
            throw ConfigurationError(
                "ChatGPT plan captioning does not support these settings: \(names.joined(separator: ", ")). "
                    + "Remove them for this account. Your API-key providers keep their own settings."
            )
        }
    }

    private func httpFailure(_ response: HTTPStreamResponse) async throws -> ChatGPTInferenceError {
        var body = Data()
        for try await line in response.lines {
            try Task.checkCancellation()
            body.append(contentsOf: line.utf8)
            if body.count >= ProviderHTTP.errorBodyLimit { break }
            body.append(10)
        }
        try Task.checkCancellation()
        return ChatGPTInferenceError(
            status: response.status, headers: response.headers,
            envelope: try? JSONValue(parsing: body), body: ProviderHTTP.truncatedText(body)
        )
    }

    private func completedReply(_ response: HTTPStreamResponse, mode: OutputMode) async throws -> ModelReply {
        var data: [String] = []
        var event = ""
        for try await line in response.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if let reply = try terminalReply(data, event: event, response: response, mode: mode) {
                    return reply
                }
                data = []
                event = ""
            } else if line.hasPrefix("data:") {
                data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
        }
        try Task.checkCancellation()
        if let reply = try terminalReply(data, event: event, response: response, mode: mode) { return reply }
        throw ModelError
            .malformedReply("ChatGPT stream ended without response.completed. No caption was saved; try again.")
    }

    private func terminalReply(
        _ data: [String], event: String, response: HTTPStreamResponse, mode: OutputMode
    ) throws -> ModelReply? {
        guard !data.isEmpty else { return nil }
        let text = data.joined(separator: "\n")
        guard text != "[DONE]" else { return nil }
        guard let envelope = try? JSONValue(parsing: Data(text.utf8)) else {
            throw ModelError.malformedReply("ChatGPT returned an invalid stream event. No caption was saved.")
        }
        switch envelope.field("type")?.stringValue ?? event {
        case "response.completed":
            guard let completed = envelope.field("response"),
                  completed.field("status")?.stringValue == "completed" else {
                throw ModelError.malformedReply("ChatGPT completion event did not contain a completed response.")
            }
            return try OpenAIResponsesClient.parse(completed, mode: mode)
        case "response.failed", "error":
            throw ChatGPTInferenceError(
                status: response.status,
                headers: response.headers,
                envelope: envelope,
                body: ProviderHTTP.truncatedText(Data(text.utf8))
            )
        case "response.incomplete":
            let reason = envelope.field("response")?.field("incomplete_details")?.field("reason")?.stringValue
                ?? "unknown reason"
            throw ModelError
                .malformedReply("ChatGPT response is incomplete (\(reason)). No caption was saved; try again.")
        default: return nil
        }
    }
}

private actor ChatGPTUsageLimit {
    private var failure: ChatGPTInferenceError?

    func check() throws {
        if let failure { throw failure }
    }

    func record(_ error: ChatGPTInferenceError) -> Bool {
        guard failure == nil else { return false }
        failure = error
        return true
    }
}
