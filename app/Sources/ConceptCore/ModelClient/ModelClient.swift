// The model-facing protocol and its value types. Python counterpart: pydantic-ai's Model layer
// as used by stages.py.

import Foundation

public enum UserContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mediaType: String)
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case user, assistant
    }

    public var role: Role
    public var content: [UserContent]

    public init(role: Role, content: [UserContent]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: [.text(text)])
    }

    public static func user(_ content: [UserContent]) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    public static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: [.text(text)])
    }

    /// The text parts joined; what an assistant turn carries on the wire.
    var text: String {
        content.compactMap {
            if case let .text(text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }
}

public struct OutputRequest: Sendable, Equatable {
    /// Schema / tool name, e.g. "Caption".
    public var name: String
    public var schema: JSONValue
    public var mode: OutputMode

    public init(name: String, schema: JSONValue, mode: OutputMode) {
        self.name = name
        self.schema = schema
        self.mode = mode
    }

    /// pydantic-ai's `DEFAULT_PROMPTED_OUTPUT_TEMPLATE` (profiles/__init__.py) verbatim, appended to
    /// the instructions in prompted mode. The wording is part of the contract: both implementations
    /// must send the same system prompt for the same job.
    var promptedInstructionSuffix: String {
        "\n\nAlways respond with a JSON object that's compatible with this schema:\n\n" + schema.pythonDumps()
            + "\n\nDon't include any text or Markdown fencing before or after."
    }

    /// `instructions` with the prompted-mode suffix when the mode asks for it.
    func instructions(_ instructions: String) -> String {
        mode == .prompted ? instructions + promptedInstructionSuffix : instructions
    }

    /// The one-line description every provider gets for the output tool.
    var toolDescription: String {
        "Return the \(name) object."
    }
}

/// The pydantic-ai `ModelSettings` key set, typed. `EndpointSpec.settings` in a job file is a
/// language-neutral contract, so every unified key pydantic-ai accepts is accepted here; each
/// client sends the ones its API expresses (see the per-client doc comments and CORE-SPEC) and
/// silently drops the rest, as pydantic-ai does. Provider-prefixed keys (`openai_*`,
/// `anthropic_*`, `google_*`) are not part of the unified set and stay unsupported.
public struct RequestSettings: Sendable, Equatable {
    /// The pydantic-ai `service_tier` literal.
    public static let serviceTiers = ["auto", "default", "flex", "priority"]
    /// Unified keys accepted for portability that no client expresses: `timeout` (the transport's
    /// timeout governs), `tool_choice` (the output tool is forced by the stage) and `cache` (no
    /// prompt caching in these clients). They are recorded in `ignoredKeys` so a UI can say so.
    public static let acceptedButIgnored = ["timeout", "tool_choice", "cache"]

    /// The effort level. `thinking: true` in settings sets `thinkingAtProviderDefault` instead;
    /// clients read `thinks` and `thinkingEffort` rather than this field directly.
    public var thinking: ThinkingLevel
    /// pydantic-ai `thinking=True`: thinking on, effort left to the provider (OpenAI
    /// `reasoning_effort: medium`, Anthropic adaptive without `effort`, Gemini `includeThoughts`).
    public var thinkingAtProviderDefault: Bool
    public var temperature: Double?
    public var maxTokens: Int?
    public var seed: Int?
    public var topP: Double?
    /// Anthropic and Gemini; Chat Completions has no top_k (vLLM takes it via `extra_body`).
    public var topK: Int?
    public var stopSequences: [String]?
    /// OpenAI-compatible and Gemini; Anthropic has no penalties.
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    /// OpenAI-compatible only.
    public var logitBias: [String: Int]?
    /// OpenAI-compatible only, and only in tool mode (the single forced tool makes it moot elsewhere).
    public var parallelToolCalls: Bool?
    /// One of `serviceTiers`. OpenAI-compatible as is; Anthropic `auto` -> `auto`, `default` ->
    /// `standard_only`, the rest dropped (pydantic-ai's mapping); Gemini has no tier.
    public var serviceTier: String?
    /// Added to every provider request, on top of the client's own headers (pydantic-ai semantics).
    public var extraHeaders: [String: String]
    /// Merged into the provider request body last (vLLM extra_body and the like).
    public var extraBody: JSONObject
    /// Keys from `acceptedButIgnored` that the settings carried, in file order.
    public var ignoredKeys: [String]

    public init(
        thinking: ThinkingLevel = .none,
        thinkingAtProviderDefault: Bool = false,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        seed: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        stopSequences: [String]? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        logitBias: [String: Int]? = nil,
        parallelToolCalls: Bool? = nil,
        serviceTier: String? = nil,
        extraHeaders: [String: String] = [:],
        extraBody: JSONObject = [:],
        ignoredKeys: [String] = []
    ) {
        self.thinking = thinking
        self.thinkingAtProviderDefault = thinkingAtProviderDefault
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.seed = seed
        self.topP = topP
        self.topK = topK
        self.stopSequences = stopSequences
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.logitBias = logitBias
        self.parallelToolCalls = parallelToolCalls
        self.serviceTier = serviceTier
        self.extraHeaders = extraHeaders
        self.extraBody = extraBody
        self.ignoredKeys = ignoredKeys
    }

    /// Whether the request thinks at all (a level other than `none`, or `thinking: true`).
    public var thinks: Bool {
        thinkingAtProviderDefault || thinking != .none
    }

    /// The effort to send; nil when thinking is off or left to the provider's default.
    public var thinkingEffort: ThinkingLevel? {
        thinkingAtProviderDefault || thinking == .none ? nil : thinking
    }

    /// From EndpointSpec.settings, with `thinking` as the job-level default (Python
    /// `models._settings`: the file's own `thinking` wins). Every pydantic-ai `ModelSettings` key
    /// is accepted and type-checked; `thinking` takes a level string, `true` (provider default
    /// effort) or `false` (off); `acceptedButIgnored` keys are recorded in `ignoredKeys`; any
    /// other key is a ConfigurationError so typos surface at resolve time. `null` values are
    /// treated as absent.
    public init(settings: JSONObject, thinking: ThinkingLevel) throws {
        self.init(thinking: thinking)
        for (key, value) in settings.pairs {
            if case .null = value { continue }
            if try applySampling(key: key, value: value) { continue }
            try applyStructured(key: key, value: value)
        }
    }

    /// The numeric keys. False when `key` is not one of them.
    private mutating func applySampling(key: String, value: JSONValue) throws -> Bool {
        switch key {
        case "temperature": temperature = try Self.number(value, key: key)
        case "max_tokens": maxTokens = try Self.integer(value, key: key)
        case "seed": seed = try Self.integer(value, key: key)
        case "top_p": topP = try Self.number(value, key: key)
        case "top_k": topK = try Self.integer(value, key: key)
        case "presence_penalty": presencePenalty = try Self.number(value, key: key)
        case "frequency_penalty": frequencyPenalty = try Self.number(value, key: key)
        default: return false
        }
        return true
    }

    /// Everything that is not a plain number; an unknown key is a ConfigurationError.
    /// Request-body keys that control what the provider retains or attributes; never from a job file.
    static let privacyBodyKeys: Set<String> = ["store", "metadata", "user", "safety_identifier"]

    private mutating func applyStructured(key: String, value: JSONValue) throws {
        switch key {
        case "stop_sequences": stopSequences = try Self.strings(value, key: key)
        case "logit_bias": logitBias = try Self.integerMap(value, key: key)
        case "parallel_tool_calls": parallelToolCalls = try Self.boolean(value, key: key)
        case "extra_headers":
            let headers = try Self.stringMap(value, key: key)
            for header in headers.keys {
                let name = header.lowercased().replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "_", with: "")
                if name.contains("authorization") || name.contains("apikey") || name.hasSuffix("token")
                    || ["cookie", "setcookie", "host"].contains(name) {
                    throw ConfigurationError("job setting header '\(header)' is not allowed")
                }
            }
            extraHeaders = headers
        case "service_tier": serviceTier = try Self.serviceTier(value)
        case "thinking": try applyThinking(value)
        case "extra_body":
            guard let object = value.objectValue else {
                throw ConfigurationError("setting 'extra_body' must be a mapping")
            }
            // extra_body is merged over the request body last, so a downloaded job could switch
            // provider-side retention back on with it. Retention is not the job file's to set.
            for key in object.keys where Self.privacyBodyKeys.contains(key.lowercased()) {
                throw ConfigurationError("job setting extra_body may not set '\(key)'")
            }
            extraBody = object
        case _ where Self.acceptedButIgnored.contains(key):
            ignoredKeys.append(key)
        default:
            throw ConfigurationError("unsupported setting '\(key)'")
        }
    }

    private static func serviceTier(_ value: JSONValue) throws -> String {
        guard let tier = value.stringValue, serviceTiers.contains(tier) else {
            throw ConfigurationError("setting 'service_tier' must be one of \(serviceTiers.joined(separator: ", "))")
        }
        return tier
    }

    /// pydantic-ai `ThinkingLevel = bool | ThinkingEffort`, plus this package's `none` spelling.
    private mutating func applyThinking(_ value: JSONValue) throws {
        if let flag = value.boolValue {
            thinkingAtProviderDefault = flag
            if !flag { thinking = .none }
            return
        }
        guard let raw = value.stringValue, let level = ThinkingLevel(rawValue: raw) else {
            let levels = ThinkingLevel.allCases.map(\.rawValue).joined(separator: ", ")
            throw ConfigurationError("setting 'thinking' must be true, false or one of \(levels)")
        }
        thinking = level
        thinkingAtProviderDefault = false
    }

    private static func number(_ value: JSONValue, key: String) throws -> Double {
        guard let number = value.doubleValue else {
            throw ConfigurationError("setting '\(key)' must be a number")
        }
        return number
    }

    private static func integer(_ value: JSONValue, key: String) throws -> Int {
        guard let number = value.intValue else {
            throw ConfigurationError("setting '\(key)' must be an integer")
        }
        return number
    }

    private static func boolean(_ value: JSONValue, key: String) throws -> Bool {
        guard let flag = value.boolValue else {
            throw ConfigurationError("setting '\(key)' must be true or false")
        }
        return flag
    }

    private static func strings(_ value: JSONValue, key: String) throws -> [String] {
        guard let items = value.arrayValue else {
            throw ConfigurationError("setting '\(key)' must be a list of strings")
        }
        return try items.map {
            guard let text = $0.stringValue else {
                throw ConfigurationError("setting '\(key)' must be a list of strings")
            }
            return text
        }
    }

    private static func stringMap(_ value: JSONValue, key: String) throws -> [String: String] {
        guard let object = value.objectValue else {
            throw ConfigurationError("setting '\(key)' must be a mapping of strings")
        }
        var map: [String: String] = [:]
        for (name, item) in object.pairs {
            guard let text = item.stringValue else {
                throw ConfigurationError("setting '\(key)' must be a mapping of strings")
            }
            map[name] = text
        }
        return map
    }

    private static func integerMap(_ value: JSONValue, key: String) throws -> [String: Int] {
        guard let object = value.objectValue else {
            throw ConfigurationError("setting '\(key)' must be a mapping of integers")
        }
        var map: [String: Int] = [:]
        for (name, item) in object.pairs {
            guard let number = item.intValue else {
                throw ConfigurationError("setting '\(key)' must be a mapping of integers")
            }
            map[name] = number
        }
        return map
    }

    /// Put `extraBody` on top of a provider request body (keys replace in place).
    func mergeExtraBody(into body: inout JSONObject) {
        for (key, value) in extraBody.pairs {
            body[key] = value
        }
    }

    /// `extraHeaders` on top of a client's own headers.
    func mergeExtraHeaders(into headers: inout [String: String]) {
        headers.merge(extraHeaders) { _, fromSettings in fromSettings }
    }

    /// `logitBias` as the JSON object Chat Completions takes, in sorted key order (stable bodies).
    var logitBiasJSON: JSONValue? {
        guard let logitBias else { return nil }
        return .object(JSONObject(logitBias.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) }))
    }

    var stopSequencesJSON: JSONValue? {
        stopSequences.map { .array($0.map(JSONValue.string)) }
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static let unknown = TokenUsage()

    /// Sum across requests; a side stays nil only when no request reported it.
    func adding(_ other: TokenUsage) -> TokenUsage {
        func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            switch (lhs, rhs) {
            case (nil, nil): nil
            default: (lhs ?? 0) + (rhs ?? 0)
            }
        }
        return TokenUsage(
            inputTokens: sum(inputTokens, other.inputTokens),
            outputTokens: sum(outputTokens, other.outputTokens)
        )
    }
}

public struct ModelReply: Sendable, Equatable {
    /// The structured JSON as text (tool arguments in tool mode), fences stripped.
    public var text: String
    /// The model name the provider reports.
    public var servedModel: String?
    public var usage: TokenUsage
    /// HTTP requests this reply cost.
    public var requestCount: Int

    public init(text: String, servedModel: String?, usage: TokenUsage = .unknown, requestCount: Int = 1) {
        self.text = text
        self.servedModel = servedModel
        self.usage = usage
        self.requestCount = requestCount
    }
}

public protocol ModelClient: Sendable {
    /// The model name as requested (for the response record).
    var requestedModel: String { get }

    /// One provider round trip over the whole conversation (first message is a user turn).
    func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) async throws -> ModelReply
}

public extension ModelClient {
    /// Single-turn convenience: wraps `user` in one user message.
    func request(
        instructions: String,
        user: [UserContent],
        output: OutputRequest,
        settings: RequestSettings
    ) async throws -> ModelReply {
        try await request(instructions: instructions, messages: [.user(user)], output: output, settings: settings)
    }
}

// MARK: - Reply text

enum ReplyText {
    /// Strip a leading ```` ```json ```` (or bare ```` ``` ````) fence and a trailing ```` ``` ````
    /// fence, then surrounding whitespace. Clean JSON passes through unchanged.
    static func unfenced(_ text: String) -> String {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard body.hasPrefix("```") else { return String(body) }
        body = body.dropFirst(3)
        // An optional language tag ("json") runs up to the first newline.
        let tagEnd = body.firstIndex { !($0.isLetter || $0.isNumber) } ?? body.endIndex
        if tagEnd == body.endIndex || body[tagEnd].isNewline {
            body = body[tagEnd...].dropFirst()
        }
        if body.hasSuffix("```") {
            body = body.dropLast(3)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - JSON envelope navigation

extension JSONValue {
    /// `self[key]` when this is an object.
    func field(_ key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// `self[index]` when this is an array with that index.
    func element(_ index: Int) -> JSONValue? {
        guard let items = arrayValue, items.indices.contains(index) else { return nil }
        return items[index]
    }
}
