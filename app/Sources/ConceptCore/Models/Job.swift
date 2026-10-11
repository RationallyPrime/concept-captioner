// The Job: concepts, per-sample subject mappings, the skill and profile, the endpoints.
// Python counterpart: job.py. Validation messages are copied from there.

import Foundation
import Yams

public enum TargetConcept: String, Codable, Sendable, CaseIterable {
    case facialIdentity = "facial_identity"
    case fullIdentity = "full_identity"
    case style
    case object
    case motion
    case characterDesign = "character_design"
    case custom
}

public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case none, minimal, low, medium, high, xhigh
}

public enum OutputMode: String, Codable, Sendable, CaseIterable {
    case native, tool, prompted
}

/// `job.py::_literal_text`: nonblank, no surrounding whitespace, no control characters.
func literalText(_ value: String, what: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value else {
        throw ConfigurationError("\(what) must be nonblank text without surrounding whitespace")
    }
    guard !value.unicodeScalars.contains(where: { $0.value < 32 }) else {
        throw ConfigurationError("\(what) must not contain control characters")
    }
    return value
}

private func nonblankItems(_ items: [String]) throws -> [String] {
    guard !items.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw ConfigurationError("list items must be nonblank strings")
    }
    return items
}

/// What one trigger stands for, and where its boundary lies.
public struct Concept: Sendable, Equatable {
    public static let defaultTraitsToLearn = ["distinctive facial identity"]
    public static let defaultAttributesToDescribe = [
        "clothing and removable accessories",
        "hair presentation",
        "expression and gaze",
        "pose",
        "setting",
        "lighting",
        "framing and visible image treatment",
    ]

    public var trigger: String
    public var classNoun: String
    public var targetConcept: TargetConcept
    public var traitsToLearn: [String]
    public var attributesToDescribe: [String]
    public var explicitBoundaryDecisions: OrderedDictionary<String, String>

    public init(
        trigger: String,
        classNoun: String = "person",
        targetConcept: TargetConcept = .facialIdentity,
        traitsToLearn: [String]? = nil,
        attributesToDescribe: [String]? = nil,
        explicitBoundaryDecisions: OrderedDictionary<String, String> = [:]
    ) throws {
        self.trigger = try literalText(trigger, what: "trigger/class_noun")
        self.classNoun = try literalText(classNoun, what: "trigger/class_noun")
        self.targetConcept = targetConcept
        self.traitsToLearn = try nonblankItems(traitsToLearn ?? Concept.defaultTraitsToLearn)
        self.attributesToDescribe = try nonblankItems(attributesToDescribe ?? Concept.defaultAttributesToDescribe)
        self.explicitBoundaryDecisions = explicitBoundaryDecisions
    }

    /// Strict decoding from an ordered JSON value; unknown keys are a ConfigurationError.
    public init(json: JSONValue, context: String = "concept") throws {
        var reader = try ObjectReader(json, context: context)
        let trigger = try reader.string("trigger") ?? reader.missing("trigger")
        let classNoun = try reader.string("class_noun") ?? "person"
        let targetConcept = try reader.enumeration("target_concept", TargetConcept.self) ?? .facialIdentity
        let traits = try reader.strings("traits_to_learn")
        let attributes = try reader.strings("attributes_to_describe")
        let decisions = try reader.stringMap("explicit_boundary_decisions") ?? [:]
        try reader.finish()
        try self.init(
            trigger: trigger,
            classNoun: classNoun,
            targetConcept: targetConcept,
            traitsToLearn: traits,
            attributesToDescribe: attributes,
            explicitBoundaryDecisions: decisions
        )
    }

    /// Ordered exactly as `Concept.model_dump()`.
    public var jsonValue: JSONValue {
        .object([
            "trigger": .string(trigger),
            "class_noun": .string(classNoun),
            "target_concept": .string(targetConcept.rawValue),
            "traits_to_learn": .array(traitsToLearn.map(JSONValue.string)),
            "attributes_to_describe": .array(attributesToDescribe.map(JSONValue.string)),
            "explicit_boundary_decisions": JSONValue(stringMap: explicitBoundaryDecisions),
        ])
    }
}

/// A model endpoint: `kind` is the provider prefix, exactly as the README spells it.
public struct EndpointSpec: Sendable, Equatable {
    public var kind: String
    public var model: String
    public var baseURL: String?
    public var outputMode: OutputMode
    public var settings: JSONObject
    public var concurrency: Int

    public init(
        kind: String,
        model: String,
        baseURL: String? = nil,
        outputMode: OutputMode = .native,
        settings: JSONObject = [:],
        concurrency: Int = 4
    ) throws {
        self.kind = try literalText(kind, what: "endpoint kind/model")
        self.model = try literalText(model, what: "endpoint kind/model")
        guard (1 ... 64).contains(concurrency) else {
            throw ConfigurationError("concurrency must be between 1 and 64, got \(concurrency)")
        }
        self.baseURL = baseURL
        self.outputMode = outputMode
        self.settings = settings
        self.concurrency = concurrency
    }

    public init(json: JSONValue, context: String = "endpoint") throws {
        var reader = try ObjectReader(json, context: context)
        let kind = try reader.string("kind") ?? reader.missing("kind")
        let model = try reader.string("model") ?? reader.missing("model")
        let baseURL = try reader.string("base_url")
        let outputMode = try reader.enumeration("output_mode", OutputMode.self) ?? .native
        let settings = try reader.object("settings") ?? [:]
        let concurrency = try reader.int("concurrency") ?? 4
        try reader.finish()
        try self.init(
            kind: kind,
            model: model,
            baseURL: baseURL,
            outputMode: outputMode,
            settings: settings,
            concurrency: concurrency
        )
    }

    public var spec: String {
        "\(kind):\(model)"
    }

    /// `model_dump(mode="json", exclude_none=True)` order; `base_url` omitted when nil.
    public var jsonValue: JSONValue {
        var object: JSONObject = ["kind": .string(kind), "model": .string(model)]
        if let baseURL { object["base_url"] = .string(baseURL) }
        object["output_mode"] = .string(outputMode.rawValue)
        object["settings"] = .object(settings)
        object["concurrency"] = .int(concurrency)
        return .object(object)
    }
}

public struct Endpoints: Sendable, Equatable {
    public var captioner: EndpointSpec
    public var critic: EndpointSpec?

    public init(captioner: EndpointSpec, critic: EndpointSpec? = nil) {
        self.captioner = captioner
        self.critic = critic
    }

    public init(json: JSONValue, context: String = "endpoints") throws {
        var reader = try ObjectReader(json, context: context)
        guard let captionerJSON = try reader.value("captioner") else { throw reader.missingError("captioner") }
        let captioner = try EndpointSpec(json: captionerJSON, context: "\(context).captioner")
        let critic = try reader.value("critic").map { try EndpointSpec(json: $0, context: "\(context).critic") }
        try reader.finish()
        self.init(captioner: captioner, critic: critic)
    }

    public var jsonValue: JSONValue {
        var object: JSONObject = ["captioner": captioner.jsonValue]
        if let critic { object["critic"] = critic.jsonValue }
        return .object(object)
    }
}

/// A captioning job: concepts, per-sample subject mappings, skill, profile, endpoints.
public struct Job: Sendable, Equatable {
    public typealias Mapping = OrderedDictionary<String, String>

    /// A skill directory path. Relative paths resolve against `directory`, the folder that holds
    /// the job file, never against the process's working directory (see `resolvedURL(for:)`).
    public var skill: String?
    /// A profile name in the skill, or a path to a `.md` file, resolved like `skill`.
    public var profile: String
    public var concepts: [Concept]
    public var samples: OrderedDictionary<String, Mapping?>
    public var singleSubjectOnly: Bool
    public var endpoints: Endpoints?
    public var captionerThinking: ThinkingLevel
    public var criticThinking: ThinkingLevel
    public var policyOverrides: OrderedDictionary<String, String>
    /// The directory that holds the job file this job was loaded from (`load(contentsOf:)` sets
    /// it). Relative `skill` and `.md` profile paths resolve against it. nil for a job built in
    /// memory or parsed from text, whose relative paths resolve against the working directory.
    /// Not part of the job file and not part of equality.
    public var directory: URL?

    /// Validates like `Job._check`: at least one concept, unique triggers, every sample mapping.
    public init(
        skill: String? = nil,
        profile: String = "h3-still",
        concepts: [Concept],
        samples: OrderedDictionary<String, Mapping?> = [:],
        singleSubjectOnly: Bool = false,
        endpoints: Endpoints? = nil,
        captionerThinking: ThinkingLevel = .low,
        criticThinking: ThinkingLevel = .high,
        policyOverrides: OrderedDictionary<String, String> = [:]
    ) throws {
        self.skill = skill
        self.profile = profile
        self.concepts = concepts
        self.samples = samples
        self.singleSubjectOnly = singleSubjectOnly
        self.endpoints = endpoints
        self.captionerThinking = captionerThinking
        self.criticThinking = criticThinking
        self.policyOverrides = policyOverrides
        try check()
    }

    /// Equality is the job file's content (`jsonValue`), so a field added to the job file is
    /// compared without touching this; where the job was loaded from (`directory`) does not count.
    public static func == (lhs: Job, rhs: Job) -> Bool {
        lhs.jsonValue == rhs.jsonValue
    }

    /// A path from the job file as a file URL: `~` expanded, an absolute path as is, a relative
    /// one against `directory` (the working directory when `directory` is nil).
    public func resolvedURL(for path: String, isDirectory: Bool = false) -> URL {
        Skills.resolve(path, relativeTo: directory, isDirectory: isDirectory)
    }

    public var triggers: [String] {
        concepts.map(\.trigger)
    }

    public func concept(for trigger: String) -> Concept? {
        concepts.first { $0.trigger == trigger }
    }

    public func mapping(for sampleID: String) -> Mapping? {
        samples[sampleID] ?? nil
    }

    /// Sample ids with no mapping: held for review, never captioned.
    public func unmapped(_ sampleIDs: [String]) -> [String] {
        sampleIDs.filter { mapping(for: $0) == nil }
    }

    public mutating func setMapping(_ mapping: Mapping?, for sampleID: String) throws {
        try checkMapping(sampleID, mapping)
        samples[sampleID] = .some(mapping)
    }

    private func check() throws {
        guard !triggers.isEmpty else { throw ConfigurationError("a job needs at least one concept") }
        guard Set(triggers).count == triggers.count else {
            throw ConfigurationError("concept triggers must be unique")
        }
        for (sampleID, mapping) in samples {
            try checkMapping(sampleID, mapping)
        }
    }

    private func checkMapping(_ sampleID: String, _ mapping: Mapping?) throws {
        guard let mapping else { return }
        guard !mapping.isEmpty else {
            throw ConfigurationError("sample '\(sampleID)': mapping must name at least one trigger")
        }
        let unknown = Set(mapping.keys).subtracting(triggers)
        if !unknown.isEmpty {
            let listed = unknown
                .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
                .map { "'\($0)'" }
                .joined(separator: ", ")
            throw ConfigurationError("sample '\(sampleID)': unknown triggers [\(listed)]")
        }
        guard !mapping.values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConfigurationError("sample '\(sampleID)': each trigger needs a locator sentence")
        }
        if singleSubjectOnly, mapping.count != 1 {
            throw ConfigurationError("single_subject_only jobs map exactly one trigger per sample")
        }
    }

    /// What the model sees for one sample: only the mapped concepts and their locators.
    public func sampleView(mapping: Mapping) -> JSONValue {
        .object([
            "training": .object(["profile": .string(profile), "trigger_handling": .string("literal")]),
            "concepts": .array(concepts.filter { mapping[$0.trigger] != nil }.map(\.jsonValue)),
            "inputs": .object([
                "actual_trainer_conditioning": .array([]),
                "audio_status": .string("not_applicable"),
                "subject_mapping": JSONValue(stringMap: mapping),
                "evidence": .string("attached_target_image"),
            ]),
            "single_subject_only": .bool(singleSubjectOnly),
            "output": .object(["caption_language": .string("English"), "delivery": .string("json_caption_field")]),
        ])
    }

    /// Strict decoding: unknown keys are a ConfigurationError, as pydantic `extra="forbid"`.
    public init(json: JSONValue) throws {
        var reader = try ObjectReader(json, context: "job")
        let skill = try reader.string("skill")
        let profile = try reader.string("profile") ?? "h3-still"
        guard let conceptsJSON = try reader.value("concepts") else { throw reader.missingError("concepts") }
        guard let conceptItems = conceptsJSON.arrayValue
        else { throw ConfigurationError("job.concepts must be a list") }
        let concepts = try conceptItems.enumerated().map { try Concept(json: $1, context: "concepts[\($0)]") }
        let samples = try reader.samples("samples")
        let singleSubjectOnly = try reader.bool("single_subject_only") ?? false
        let endpoints = try reader.value("endpoints").map { try Endpoints(json: $0) }
        let captionerThinking = try reader.enumeration("captioner_thinking", ThinkingLevel.self) ?? .low
        let criticThinking = try reader.enumeration("critic_thinking", ThinkingLevel.self) ?? .high
        let policyOverrides = try reader.stringMap("policy_overrides") ?? [:]
        try reader.finish()
        try self.init(
            skill: skill,
            profile: profile,
            concepts: concepts,
            samples: samples,
            singleSubjectOnly: singleSubjectOnly,
            endpoints: endpoints,
            captionerThinking: captionerThinking,
            criticThinking: criticThinking,
            policyOverrides: policyOverrides
        )
    }

    /// Ordered as `model_dump(mode="json")`; nil fields omitted, null samples kept.
    public var jsonValue: JSONValue {
        var object = JSONObject()
        if let skill { object["skill"] = .string(skill) }
        object["profile"] = .string(profile)
        object["concepts"] = .array(concepts.map(\.jsonValue))
        var sampleObject = JSONObject()
        for (sampleID, mapping) in samples {
            sampleObject[sampleID] = mapping.map { JSONValue(stringMap: $0) } ?? .null
        }
        object["samples"] = .object(sampleObject)
        object["single_subject_only"] = .bool(singleSubjectOnly)
        if let endpoints { object["endpoints"] = endpoints.jsonValue }
        object["captioner_thinking"] = .string(captionerThinking.rawValue)
        object["critic_thinking"] = .string(criticThinking.rawValue)
        object["policy_overrides"] = JSONValue(stringMap: policyOverrides)
        return .object(object)
    }

    public static func load(contentsOf url: URL) throws -> Job {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigurationError("cannot read job file \(url.path): \(error.localizedDescription)")
        }
        var job = try load(yaml: text)
        job.directory = url.standardizedFileURL.deletingLastPathComponent()
        return job
    }

    public static func load(yaml: String) throws -> Job {
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            throw ConfigurationError("job file is not valid YAML: \(error)")
        }
        guard let node, case .mapping = node else { throw ConfigurationError("job file must be a YAML mapping") }
        return try Job(json: JSONValue(yamlNode: node))
    }

    /// YAML in declaration order, block style, as `yaml.safe_dump(sort_keys=False)` lays it out.
    public func dump() throws -> String {
        do {
            return try Yams.serialize(node: jsonValue.yamlNode(), allowUnicode: true)
        } catch {
            throw ConfigurationError("cannot serialize job: \(error)")
        }
    }

    public func save(to url: URL) throws {
        try Data(dump().utf8).write(to: url, options: .atomic)
    }
}

extension JSONValue {
    /// An ordered `{string: string}` object.
    init(stringMap: OrderedDictionary<String, String>) {
        self = .object(JSONObject(stringMap.map { ($0.key, JSONValue.string($0.value)) }))
    }
}

/// Strict field access over an ordered JSON object: every key must be consumed, else
/// `finish()` reports the extras, as pydantic `extra="forbid"` does. Null reads as absent.
struct ObjectReader {
    let object: JSONObject
    let context: String
    private var seen: Set<String> = []

    init(_ value: JSONValue, context: String) throws {
        guard let object = value.objectValue else { throw ConfigurationError("\(context) must be a mapping") }
        self.object = object
        self.context = context
    }

    mutating func value(_ key: String) throws -> JSONValue? {
        seen.insert(key)
        guard let value = object[key], value != .null else { return nil }
        return value
    }

    func missingError(_ key: String) -> ConfigurationError {
        ConfigurationError("\(context): field '\(key)' is required")
    }

    func missing<T>(_ key: String) throws -> T {
        throw missingError(key)
    }

    private func mismatch(_ key: String, _ expected: String) -> ConfigurationError {
        ConfigurationError("\(context).\(key) must be \(expected)")
    }

    mutating func string(_ key: String) throws -> String? {
        guard let value = try value(key) else { return nil }
        guard let text = value.stringValue else { throw mismatch(key, "a string") }
        return text
    }

    mutating func bool(_ key: String) throws -> Bool? {
        guard let value = try value(key) else { return nil }
        guard let flag = value.boolValue else { throw mismatch(key, "a boolean") }
        return flag
    }

    mutating func int(_ key: String) throws -> Int? {
        guard let value = try value(key) else { return nil }
        if let number = value.intValue { return number }
        if let number = value.doubleValue, number == number.rounded(), let exact = Int(exactly: number) {
            return exact
        }
        throw mismatch(key, "an integer")
    }

    mutating func object(_ key: String) throws -> JSONObject? {
        guard let value = try value(key) else { return nil }
        guard let object = value.objectValue else { throw mismatch(key, "a mapping") }
        return object
    }

    mutating func enumeration<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T?
        where T.RawValue == String {
        guard let text = try string(key) else { return nil }
        guard let member = T(rawValue: text) else {
            let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw ConfigurationError("\(context).\(key) must be one of \(allowed), got '\(text)'")
        }
        return member
    }

    mutating func strings(_ key: String) throws -> [String]? {
        guard let value = try value(key) else { return nil }
        guard let items = value.arrayValue else { throw mismatch(key, "a list of strings") }
        return try items.map { item in
            guard let text = item.stringValue else { throw mismatch(key, "a list of strings") }
            return text
        }
    }

    mutating func stringMap(_ key: String) throws -> OrderedDictionary<String, String>? {
        guard let object = try object(key) else { return nil }
        return try OrderedDictionary(object.pairs.map { pair in
            guard let text = pair.value.stringValue else { throw mismatch(key, "a mapping of strings") }
            return (pair.key, text)
        })
    }

    /// `samples`: id -> `{trigger: locator}` or null (kept as an explicit nil entry).
    mutating func samples(_ key: String) throws -> OrderedDictionary<String, Job.Mapping?> {
        guard let object = try object(key) else { return [:] }
        var samples: OrderedDictionary<String, Job.Mapping?> = [:]
        for (sampleID, value) in object.pairs {
            switch value {
            case .null:
                samples[sampleID] = .some(nil)
            case let .object(mapping):
                samples[sampleID] = try .some(OrderedDictionary(mapping.pairs.map { pair in
                    guard let text = pair.value.stringValue else {
                        throw ConfigurationError("sample '\(sampleID)': each trigger needs a locator sentence")
                    }
                    return (pair.key, text)
                }))
            default:
                throw ConfigurationError(
                    "sample '\(sampleID)': mapping must be a mapping of trigger to locator or null"
                )
            }
        }
        return samples
    }

    func finish() throws {
        let extra = object.keys.filter { !seen.contains($0) }
        guard extra.isEmpty else {
            throw ConfigurationError("\(context): extra fields not permitted: \(extra.joined(separator: ", "))")
        }
    }
}
