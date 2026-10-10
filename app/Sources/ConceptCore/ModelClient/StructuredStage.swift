// Structured output with one validation retry in the same conversation. Mirrors pydantic-ai's
// Agent(output_type=..., retries=1) plus an output validator raising ModelRetry.

import Foundation

public struct StageRun<Output: Sendable>: Sendable {
    public let output: Output
    /// The whole conversation including the final assistant turn.
    public let messages: [ChatMessage]
    public let servedModel: String?
    /// Provider requests made in this run (1 or 2).
    public let requests: Int
    public let usage: TokenUsage

    public init(output: Output, messages: [ChatMessage], servedModel: String?, requests: Int, usage: TokenUsage) {
        self.output = output
        self.messages = messages
        self.servedModel = servedModel
        self.requests = requests
        self.usage = usage
    }
}

public enum StageFailure: Error, LocalizedError, Sendable {
    /// The validator rejected the reply `retries + 1` times.
    case rejected(problems: [String], lastReply: ModelReply, requests: Int, servedModel: String?)
    /// The reply could not be decoded `retries + 1` times.
    case undecodable(reason: String, lastReply: ModelReply, requests: Int, servedModel: String?)

    public var errorDescription: String? {
        switch self {
        case let .rejected(problems, _, requests, _):
            "output rejected after \(requests) requests: \(problems.joined(separator: "; "))"
        case let .undecodable(reason, _, requests, _):
            "output undecodable after \(requests) requests: \(reason)"
        }
    }
}

/// Why a reply did not decode, as pydantic would report it.
///
/// `type`, `loc` and `msg` are the fields of one pydantic `ErrorDetails` record (`loc` holds
/// field names and array indices); `message` is the same failure in one human-readable line
/// for `StageFailure.undecodable`. `JSONDecoder` stops at the first problem, so a reply with
/// several wrong fields yields one record where pydantic would list them all.
public struct DecodeFailure: Error, Sendable, Equatable {
    public let type: String
    public let loc: [JSONValue]
    public let msg: String
    public let message: String

    public init(type: String, loc: [JSONValue], msg: String, message: String) {
        self.type = type
        self.loc = loc
        self.msg = msg
        self.message = message
    }

    /// The pydantic `ErrorDetails` record as pydantic-ai renders it for a native-output retry
    /// (`ctx` and `input` excluded).
    public var record: JSONValue {
        .object(["type": .string(type), "loc": .array(loc), "msg": .string(msg)])
    }
}

/// The user turn that asks the model to try again: byte for byte what pydantic-ai 2.55
/// (`RetryPromptPart.model_response`) sends for the same failure. Swift sends it as a plain
/// user turn in every output mode (CORE-SPEC decision 7), so in tool mode the text is what
/// pydantic-ai would put in the tool-return part.
public enum RetryPrompt {
    /// Appended to every retry turn.
    public static let suffix = "\n\nFix the errors and try again."

    /// An output validator's feedback (pydantic-ai `ModelRetry`). Native and prompted output
    /// carry no tool name, so pydantic-ai prefixes `"Validation feedback:\n"`; tool output
    /// sends the bare message.
    public static func validator(_ feedback: String, mode: OutputMode) -> String {
        let description = mode == .tool ? feedback : "Validation feedback:\n" + feedback
        return description + suffix
    }

    /// A reply that did not decode (pydantic `ValidationError`): the error record as a JSON
    /// block. Always one record (see `DecodeFailure`), and `input` is omitted in every mode
    /// where pydantic-ai keeps it for tool-output retries.
    public static func undecodable(_ failure: DecodeFailure) -> String {
        let errors = JSONValue.array([failure.record]).pythonDumps(indent: 2)
        return "1 validation error:\n```json\n" + errors + "\n```" + suffix
    }
}

public struct StructuredStage<Output: Decodable & Sendable>: Sendable {
    /// Appended to every retry turn (pydantic-ai RetryPromptPart.model_response).
    public static var retrySuffix: String {
        RetryPrompt.suffix
    }

    public let name: String
    public let endpoint: ResolvedEndpoint
    public let output: OutputRequest
    public let retries: Int

    public init(name: String, endpoint: ResolvedEndpoint, schemaName: String, schema: JSONValue, retries: Int = 1) {
        self.name = name
        self.endpoint = endpoint
        output = OutputRequest(name: schemaName, schema: schema, mode: endpoint.outputMode)
        self.retries = retries
    }

    /// Sends the conversation, decodes the reply, runs `validate`; on problems appends the
    /// assistant text and a retry user turn and asks once more, `retries` times.
    ///
    /// Validator problems retry with `RetryPrompt.validator(retryMessage(problems), mode:)`;
    /// decode failures with `RetryPrompt.undecodable`. Either way the retry turn ends with
    /// `RetryPrompt.suffix`.
    public func run(
        instructions: String,
        messages: [ChatMessage],
        validate: @Sendable (Output) -> [String] = { _ in [] },
        retryMessage: @Sendable ([String]) -> String = { $0.joined(separator: "; ") }
    ) async throws -> StageRun<Output> {
        var conversation = messages
        var requests = 0
        var usage = TokenUsage.unknown
        var servedModel: String?
        let retries = max(retries, 0)

        for attempt in 0 ... retries {
            let reply = try await endpoint.client.request(
                instructions: instructions,
                messages: conversation,
                output: output,
                settings: endpoint.settings
            )
            requests += reply.requestCount
            usage = usage.adding(reply.usage)
            servedModel = reply.servedModel ?? servedModel
            let text = ReplyText.unfenced(reply.text)
            conversation.append(.assistant(text))

            let retryText: String
            switch Self.decode(text) {
            case let .success(decoded):
                let problems = validate(decoded)
                if problems.isEmpty {
                    return StageRun(
                        output: decoded,
                        messages: conversation,
                        servedModel: servedModel,
                        requests: requests,
                        usage: usage
                    )
                }
                if attempt == retries {
                    throw StageFailure.rejected(
                        problems: problems,
                        lastReply: reply,
                        requests: requests,
                        servedModel: servedModel
                    )
                }
                retryText = RetryPrompt.validator(retryMessage(problems), mode: output.mode)
            case let .failure(failure):
                if attempt == retries {
                    throw StageFailure.undecodable(
                        reason: failure.message,
                        lastReply: reply,
                        requests: requests,
                        servedModel: servedModel
                    )
                }
                retryText = RetryPrompt.undecodable(failure)
            }
            conversation.append(.user(retryText))
        }
        // `retries` is never negative in practice; the loop above always returns or throws.
        preconditionFailure("StructuredStage.run fell through its retry loop")
    }

    /// Decodes a reply as `Output`, mapping a `JSONDecoder` failure onto pydantic's error
    /// vocabulary (`missing`, `string_type`, `json_invalid`, ...).
    public static func decode(_ text: String) -> Result<Output, DecodeFailure> {
        do {
            return try .success(JSONDecoder().decode(Output.self, from: Data(text.utf8)))
        } catch let error as DecodingError {
            return .failure(describe(error))
        } catch {
            let reason = ProviderHTTP.describe(error)
            return .failure(DecodeFailure(type: "value_error", loc: [], msg: "Value error, \(reason)", message: reason))
        }
    }

    private static func describe(_ error: DecodingError) -> DecodeFailure {
        func loc(_ context: DecodingError.Context) -> [JSONValue] {
            context.codingPath.map { key in key.intValue.map(JSONValue.int) ?? .string(key.stringValue) }
        }
        func location(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "" : " at \(path)"
        }
        func wrongType(_ type: Any.Type, _ context: DecodingError.Context, message: String) -> DecodeFailure {
            let (type, name) = pydanticType(type)
            return DecodeFailure(
                type: "\(type)_type",
                loc: loc(context),
                msg: "Input should be a valid \(name)",
                message: message
            )
        }
        switch error {
        case let .keyNotFound(key, context):
            return DecodeFailure(
                type: "missing",
                loc: loc(context) + [.string(key.stringValue)],
                msg: "Field required",
                message: "missing key '\(key.stringValue)'\(location(context))"
            )
        case let .typeMismatch(type, context):
            return wrongType(type, context, message: "expected \(type)\(location(context))")
        case let .valueNotFound(type, context):
            return wrongType(type, context, message: "missing \(type) value\(location(context))")
        case let .dataCorrupted(context):
            let detail = context.debugDescription.isEmpty ? "invalid JSON" : context.debugDescription
            if context.codingPath.isEmpty {
                return DecodeFailure(type: "json_invalid", loc: [], msg: "Invalid JSON: \(detail)", message: detail)
            }
            return DecodeFailure(
                type: "value_error",
                loc: loc(context),
                msg: "Value error, \(detail)",
                message: "\(detail)\(location(context))"
            )
        @unknown default:
            let detail = String(describing: error)
            return DecodeFailure(type: "value_error", loc: [], msg: "Value error, \(detail)", message: detail)
        }
    }

    /// pydantic's (error type prefix, human name) for the Swift type `JSONDecoder` wanted.
    private static func pydanticType(_ type: Any.Type) -> (String, String) {
        let name = String(describing: type)
        switch name {
        case "String": return ("string", "string")
        case "Bool": return ("bool", "boolean")
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return ("int", "integer")
        case "Double", "Float": return ("float", "number")
        case _ where name.hasPrefix("Array<"): return ("list", "list")
        case _ where name.hasPrefix("Dictionary<"): return ("dict", "dictionary")
        default:
            let lowered = name.lowercased()
            return (lowered, lowered)
        }
    }
}
