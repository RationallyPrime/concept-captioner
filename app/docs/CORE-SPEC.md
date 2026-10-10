# ConceptCore: Swift design with parity to `concept_captioner` (Python)

Status: architecture, 2026-10-10. The Python package under `src/concept_captioner/` is the
reference implementation; `docs/v0.2-plan.md` (including "Beyond v0.2") and `README.md` are the
design it was built to. This document is the Swift port's contract. Every implementer edits only
the files assigned to them and follows the signatures here; signature changes are proposed in
this document first.

## Package

```
app/
  Package.swift                      swift-tools-version 6.0, Swift 6 language mode, macOS 15
  docs/CORE-SPEC.md                  this file
  Sources/ConceptCore/               library target ConceptCore
    ConceptCore.swift                module doc, `ConceptCore.version`, `ConceptCore.defaultSkillURL`
    Models/Errors.swift              ConfigurationError, ModelError, HubError
    Models/JSONValue.swift           JSONValue / JSONObject, Python-compatible serialization, Yams bridge
    Models/Job.swift                 Job, Concept, Endpoints, EndpointSpec, TargetConcept, ThinkingLevel, OutputMode
    Models/Schemas.swift             Caption, Critique (+ their JSON Schemas)
    Models/Records.swift             SampleStatus, ModelNames, ResponseRecord, Outcome, RunSummary
    Skills/Skill.swift               Skill, Skills.load, frontmatter parsing
    Prompt/Prompt.swift              Prompt.userTurn, captionerTask, criticTask, captionerInstructions, criticInstructions, criticUserTurn
    Triggers/Triggers.swift          CaptionDeps, Triggers.exactTriggerSpans, triggerProblems, retryMessage
    Images/ProviderImage.swift       Images.providerImage
    ModelClient/ModelClient.swift    ModelClient, UserContent, ChatMessage, OutputRequest, RequestSettings, ModelReply, TokenUsage
    ModelClient/HTTPTransport.swift  HTTPTransport, URLSessionTransport, HTTPResponse
    ModelClient/OpenAICompatibleClient.swift
    ModelClient/AnthropicClient.swift
    ModelClient/GeminiClient.swift
    ModelClient/Resolve.swift        Provider, KeyStore, StaticKeyStore, ResolvedEndpoint, Endpoints.resolve / parseSpec
    ModelClient/StructuredStage.swift StructuredStage<Output>, StageRun, StageFailure, RetryPrompt
    Runner/Runner.swift              Runner
    Sources/Sample.swift             Sample, ImageSource, CaptionSink, Sources.imageSuffixes
    Sources/LocalFolderSource.swift
    Sources/SidecarSink.swift        SidecarSink, AtomicFile
    Hub/HubClient.swift              RepoID, HubFile, CommitOperation, CommitResult, HubClient
    Hub/ImageFolderMetadata.swift    MetadataRow, ImageFolderMetadata (metadata.jsonl read/write)
    Hub/HubFolderSource.swift
    Hub/HubFolderSink.swift
    Resources/Skills/diffusion-training-captioner/   copied verbatim from src/concept_captioner/skills/
  Sources/ConceptStudio/main.swift   placeholder executable (a later workflow owns the app)
  Tests/ConceptCoreTests/
    Support/FakeModelClient.swift    scripted ModelClient that records requests
    Support/Fixtures.swift           synthetic PNGs (CoreGraphics), the NORA7/IVAN9 job, h3(), goodCaption()
    Support/StubTransport.swift      scripted HTTPTransport that records URLRequests
    ModelsTests.swift SkillsTests.swift PromptTests.swift TriggersTests.swift ImagesTests.swift
    ModelClientTests.swift ResolveBaseURLTests.swift RunnerTests.swift SourcesTests.swift HubTests.swift
```

Conventions (non-negotiable):

- Swift 6 strict concurrency. Every public type is `Sendable`; shared mutable state lives in
  actors (`HubFolderSink`, `FakeModelClient`, `StubTransport`). No `@unchecked Sendable`
  without a comment saying why.
- Dependencies: Yams only. Foundation, ImageIO/CoreGraphics, CryptoKit, URLSession otherwise.
- Tests: Swift Testing. No network: model clients and the Hub client take an injected
  `HTTPTransport`; the runner takes a `FakeModelClient`.
- Errors: `ConfigurationError` for anything the user got wrong (bad job, bad skill, bad spec);
  `ModelError` for provider/transport problems; `HubError` for Hub HTTP problems. All carry a
  human-readable `message` and conform to `LocalizedError`.
- `swiftformat` and `swiftlint lint --quiet` clean (configs in `app/.swiftformat`,
  `app/.swiftlint.yml`).
- Fixtures use the placeholder triggers `NORA7` / `IVAN9`. No real concept names anywhere.
- Key names in JSON/YAML are the Python snake_case names, always. Swift property names are
  camelCase; `CodingKeys` (or explicit `JSONObject` construction) maps them.

### The language-neutral contract (shared with Python, must not drift)

| Artifact | Shape |
| --- | --- |
| job file | YAML mapping, keys and validation rules of `job.py` (below) |
| skill directory | `SKILL.md` frontmatter + body, `references/`, `references/profiles/*.md` |
| profile | a Markdown file, used as text |
| response record | one JSON object per captioned image, keys of `runner.py::_base_record` |
| sidecars | `<stem>.txt` caption, `<stem>.json` record, `_summary.json` (CLI/app) |
| Hub dataset | imagefolder convention: images + `metadata.jsonl` with `file_name`, `caption`, `caption_response` |

### Deviations from the Python code, decided here

1. **Double trigger failure ends `rejected`, with a record.** `runner.py` currently lets
   pydantic-ai's `UnexpectedModelBehavior` escape and reports `failed` with no record; the plan
   and the runner's own docstring say `rejected`. Swift follows the design. (Python fix to file.)
2. **`Job.dump()` keeps `null` samples.** `yaml.safe_dump(model_dump(exclude_none=True))` in
   Python drops `samples: {x.png: null}` entries, losing "held for review". Swift keeps them;
   they are the documented shape. (Python fix to file.)
3. **Anthropic structured output uses `output_config.format` (JSON Schema), not a forced
   tool.** Forced `tool_choice` returns HTTP 400 on current Claude models; `output_config.format`
   is GA. Tool mode uses a `strict: true` tool with `tool_choice: {type: "auto"}` plus a system
   instruction to call it. Thinking maps to `thinking: {type: "adaptive"}` + `output_config.effort`.
4. **`resolve` accepts exactly five kinds** (`google`, `anthropic`, `openai`, `openrouter`,
   `vllm`). Python forwards unknown prefixes to pydantic-ai; Swift has no such registry and
   raises `ConfigurationError`. `gemini` raises a message that names `kind: google`.
5. **Keys come from an injected `KeyStore`**, never from the environment inside the library.
   The app's Keychain-backed store and the CLI's environment store both conform to it.
6. **Parquet-backed Hub datasets are out of scope for the Swift core in v1.** The Hub source
   and sink speak the imagefolder convention only (image files + `metadata.jsonl`). A dataset
   whose images live in parquet shards is rejected with a `HubError` naming this limitation.
7. **Retry prompts render as plain user turns** in every output mode (pydantic-ai renders a
   tool-return retry in tool mode). The text is what pydantic-ai 2.55's
   `RetryPromptPart.model_response()` would send for the same failure (see `RetryPrompt`).
   Conversation history is text in, text out: an assistant turn is the JSON the model
   returned, as text.
8. `CLAUDE.md` in the repository root predates v0.2 (receipts, `POLICY_VERSION`,
   `require_model_match`); those rules no longer exist in either implementation. The v0.2 plan
   governs.

---

## Module `models`

Python counterparts: `job.py`, `schemas.py`, `types.py`, the record dict in `runner.py`.
Files: `Models/Errors.swift`, `Models/JSONValue.swift`, `Models/Job.swift`,
`Models/Schemas.swift`, `Models/Records.swift`.

### Errors (`Models/Errors.swift`)

```swift
public struct ConfigurationError: Error, Equatable, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String)
    public var errorDescription: String? { message }
}

public enum ModelError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)          // non-2xx from a provider
    case transport(String)                        // URLSession failure, described
    case malformedReply(String)                   // envelope did not contain text/JSON
    case missingKey(Provider)                     // KeyStore returned nil for a provider that needs one
    public var errorDescription: String? { get }
}

public enum HubError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case transport(String)
    case malformed(String)                        // unexpected JSON / Link header
    case unsupported(String)                      // e.g. parquet-backed dataset, multipart LFS
    public var errorDescription: String? { get }
}
```

### JSONValue (`Models/JSONValue.swift`)

An ordered JSON model. The prompt embeds `json.dumps(job.sample_view(mapping), ensure_ascii=False)`
and the sidecar record is `json.dumps(record, ensure_ascii=False, indent=1)`; both are
insertion-ordered with Python's default separators. `JSONEncoder` cannot reproduce either, so the
library serializes JSON itself.

```swift
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// Insertion-ordered string-keyed object. Equality is order-insensitive (like a Python dict).
public struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public init()
    public init(_ pairs: [(String, JSONValue)])
    public var keys: [String] { get }                  // insertion order
    public var pairs: [(key: String, value: JSONValue)] { get }
    public subscript(key: String) -> JSONValue? { get set }   // set appends when new, replaces in place when present
    public mutating func removeValue(forKey key: String)
    public var count: Int { get }
}

extension JSONValue {
    // Convenience accessors (nil when the case does not match).
    public var stringValue: String? { get }
    public var boolValue: Bool? { get }
    public var intValue: Int? { get }
    public var doubleValue: Double? { get }
    public var arrayValue: [JSONValue]? { get }
    public var objectValue: JSONObject? { get }

    /// Parse with JSONSerialization, preserving key order (walk the raw bytes for ordering;
    /// a small hand-written recursive-descent parser is acceptable and simpler).
    public init(parsing data: Data) throws              // ConfigurationError on invalid JSON
    public init(parsing text: String) throws

    /// Python `json.dumps(value, ensure_ascii=False)` byte-for-byte:
    /// separators `", "` and `": "`, insertion order, `true/false/null`, ints without exponent,
    /// doubles via Python `repr` rules (shortest round-trip; `.0` for integral values),
    /// escapes only `"`, `\`, and control characters < 0x20 (as \n \r \t \b \f or \u00XX).
    /// `indent: nil` is the single-line form. `indent: n` reproduces `json.dumps(indent=n)`:
    /// items separated by `,\n` + indentation, `": "` after keys, empty containers as `{}`/`[]`.
    public func pythonDumps(indent: Int? = nil) -> String
    public func pythonDumpsData(indent: Int? = nil) -> Data   // UTF-8

    /// Bridge to/from Codable types through JSONDecoder/JSONEncoder (order is irrelevant there).
    public func decode<T: Decodable>(_ type: T.Type) throws -> T
    public init<T: Encodable>(encoding value: T) throws

    /// Bridge to/from Yams nodes for the job file and SKILL.md frontmatter.
    /// Scalars resolve with Yams' default resolver (null/bool/int/float/string); mapping keys
    /// must be strings (ConfigurationError otherwise); order is preserved.
    public init(yamlNode node: Yams.Node) throws
    public func yamlNode() -> Yams.Node
}
```

### Job (`Models/Job.swift`)

```swift
public enum TargetConcept: String, Codable, Sendable, CaseIterable {
    case facialIdentity = "facial_identity", fullIdentity = "full_identity", style, object, motion,
         characterDesign = "character_design", custom
}
public enum ThinkingLevel: String, Codable, Sendable, CaseIterable { case none, minimal, low, medium, high, xhigh }
public enum OutputMode: String, Codable, Sendable, CaseIterable { case native, tool, prompted }

public struct Concept: Sendable, Equatable {
    public var trigger: String
    public var classNoun: String = "person"                       // class_noun
    public var targetConcept: TargetConcept = .facialIdentity     // target_concept
    public var traitsToLearn: [String] = ["distinctive facial identity"]
    public var attributesToDescribe: [String] = [
        "clothing and removable accessories", "hair presentation", "expression and gaze",
        "pose", "setting", "lighting", "framing and visible image treatment",
    ]
    public var explicitBoundaryDecisions: [String: String] = [:]  // explicit_boundary_decisions; ORDER PRESERVED on dump (see note)
    public init(trigger: String, classNoun: String = "person", targetConcept: TargetConcept = .facialIdentity,
                traitsToLearn: [String]? = nil, attributesToDescribe: [String]? = nil,
                explicitBoundaryDecisions: OrderedDictionary<String, String> = [:]) throws
    /// Ordered JSON exactly as `Concept.model_dump()`: trigger, class_noun, target_concept,
    /// traits_to_learn, attributes_to_describe, explicit_boundary_decisions.
    public var jsonValue: JSONValue { get }
}
```

Note on ordered dictionaries: `explicit_boundary_decisions`, `samples`, each sample's mapping and
`policy_overrides` are insertion-ordered in Python and that order reaches the prompt. They are
`OrderedDictionary<Key, Value>`, a small `Equatable, ExpressibleByDictionaryLiteral, Sequence`
struct in `JSONValue.swift` (keys, values, subscript get/set preserving position, `removeValue`,
`count`, `isEmpty`; `Sendable`/`Equatable` conditionally). The job types are deliberately NOT
`Codable`: `JSONDecoder`/`YAMLDecoder` lose key order and cannot forbid unknown keys, so the
contract types convert through `init(json:)` / `jsonValue` only. `Caption` and `Critique` are
`Codable` because model replies are decoded with `JSONDecoder` and their order is irrelevant.

```swift
public struct EndpointSpec: Sendable, Equatable {
    public var kind: String                 // provider prefix, exactly as the README spells it
    public var model: String
    public var baseURL: String? = nil       // base_url
    public var outputMode: OutputMode = .native
    public var settings: JSONObject = [:]   // passthrough: temperature, seed, max_tokens, top_p, extra_body, ...
    public var concurrency: Int = 4         // 1...64
    public init(kind: String, model: String, baseURL: String? = nil, outputMode: OutputMode = .native,
                settings: JSONObject = [:], concurrency: Int = 4) throws
    public var spec: String { "\(kind):\(model)" }
}

public struct Endpoints: Sendable, Equatable {
    public var captioner: EndpointSpec
    public var critic: EndpointSpec? = nil  // absent: no critic pass
}

public struct Job: Sendable, Equatable {
    public var skill: String? = nil                      // skill directory; nil: the bundled default
    public var profile: String = "h3-still"
    public var concepts: [Concept]
    public var samples: OrderedDictionary<String, OrderedDictionary<String, String>?> = [:]
    public var singleSubjectOnly: Bool = false           // single_subject_only
    public var endpoints: Endpoints? = nil
    public var captionerThinking: ThinkingLevel = .low   // captioner_thinking
    public var criticThinking: ThinkingLevel = .high     // critic_thinking
    public var policyOverrides: OrderedDictionary<String, String> = [:]  // policy_overrides

    /// Validates like `Job._check`: at least one concept, unique triggers, every sample mapping.
    public init(skill: String? = nil, profile: String = "h3-still", concepts: [Concept],
                samples: OrderedDictionary<String, OrderedDictionary<String, String>?> = [:],
                singleSubjectOnly: Bool = false, endpoints: Endpoints? = nil,
                captionerThinking: ThinkingLevel = .low, criticThinking: ThinkingLevel = .high,
                policyOverrides: OrderedDictionary<String, String> = [:]) throws

    public var triggers: [String] { get }
    public func concept(for trigger: String) -> Concept?
    public func mapping(for sampleID: String) -> OrderedDictionary<String, String>?
    public func unmapped(_ sampleIDs: [String]) -> [String]          // ids whose mapping is nil or absent
    public mutating func setMapping(_ mapping: OrderedDictionary<String, String>?, for sampleID: String) throws
    public func sampleView(mapping: OrderedDictionary<String, String>) -> JSONValue

    /// Strict decoding from an ordered JSON value (what YAML parses to): unknown keys are
    /// ConfigurationError ("extra fields not permitted"), as pydantic `extra="forbid"`.
    public init(json: JSONValue) throws
    public var jsonValue: JSONValue { get }          // ordered as model_dump(mode="json"); nil fields omitted except null samples

    public static func load(contentsOf url: URL) throws -> Job     // ConfigurationError for any problem
    public static func load(yaml: String) throws -> Job
    public func dump() throws -> String                            // YAML, keys in declaration order
    public func save(to url: URL) throws
}
```

Validation rules (all `ConfigurationError`, messages as in Python where it has one):

- `trigger`, `class_noun`, endpoint `kind`/`model`: non-blank, no surrounding whitespace, no
  control characters (`"\(what) must be nonblank text without surrounding whitespace"`,
  `"\(what) must not contain control characters"`).
- `traits_to_learn`, `attributes_to_describe`: no blank items.
- `concurrency` in 1...64.
- `"a job needs at least one concept"`, `"concept triggers must be unique"`.
- per sample: `"sample '<id>': mapping must name at least one trigger"` (empty mapping),
  `"sample '<id>': unknown triggers [...]"` (sorted), `"sample '<id>': each trigger needs a locator sentence"`,
  `"single_subject_only jobs map exactly one trigger per sample"`.
- `load`: a non-mapping document is `"job file must be a YAML mapping"`.

`sampleView(mapping:)` returns, in this order, exactly:

```
{"training": {"profile": <profile>, "trigger_handling": "literal"},
 "concepts": [<concept.jsonValue> for each concept whose trigger is in mapping, in job order],
 "inputs": {"actual_trainer_conditioning": [], "audio_status": "not_applicable",
            "subject_mapping": <mapping, in mapping order>, "evidence": "attached_target_image"},
 "single_subject_only": <bool>,
 "output": {"caption_language": "English", "delivery": "json_caption_field"}}
```

Reference output for the fixture job (`Concept(trigger: "NORA7", classNoun: "woman")`,
`Concept(trigger: "IVAN9", classNoun: "man")`, profile `h3-still`), mapping
`{"NORA7": "The only person in the crop."}`, as `pythonDumps()`:

```
{"training": {"profile": "h3-still", "trigger_handling": "literal"}, "concepts": [{"trigger": "NORA7", "class_noun": "woman", "target_concept": "facial_identity", "traits_to_learn": ["distinctive facial identity"], "attributes_to_describe": ["clothing and removable accessories", "hair presentation", "expression and gaze", "pose", "setting", "lighting", "framing and visible image treatment"], "explicit_boundary_decisions": {}}], "inputs": {"actual_trainer_conditioning": [], "audio_status": "not_applicable", "subject_mapping": {"NORA7": "The only person in the crop."}, "evidence": "attached_target_image"}, "single_subject_only": false, "output": {"caption_language": "English", "delivery": "json_caption_field"}}
```

and for `{"NORA7": "The woman on the left.", "IVAN9": "The man on the right."}` the same with
both concepts (NORA7 then IVAN9) and `"subject_mapping": {"NORA7": "The woman on the left.", "IVAN9": "The man on the right."}`.

### Schemas (`Models/Schemas.swift`)

```swift
public struct Caption: Codable, Sendable, Equatable {
    public var caption: String
    public var usable: Bool = true
    public var note: String? = nil
    public init(caption: String, usable: Bool = true, note: String? = nil)
    /// Lenient decoding: `usable` defaults true, `note` nil when absent or null.
    public var jsonValue: JSONValue { get }      // {"caption":..., "usable":..., "note": null|...} in that order (model_dump)
    public static let jsonSchema: JSONValue      // see below
    public static let schemaName = "Caption"
}

public struct Critique: Codable, Sendable, Equatable {
    public var approved: Bool
    public var notes: [String] = []
    public init(approved: Bool, notes: [String] = [])
    public var jsonValue: JSONValue { get }      // {"approved":..., "notes": [...]}
    public static let jsonSchema: JSONValue
    public static let schemaName = "Critique"
}
```

One schema per type, written in the strict style every provider accepts (all properties
required, `additionalProperties: false`, nullability via `"type": ["string", "null"]`):

```json
{"type": "object", "title": "Caption",
 "properties": {
   "caption": {"type": "string", "description": "The training caption in the selected profile's format."},
   "usable": {"type": "boolean", "description": "False when a mapped subject is absent, too small, obscured, or cannot be bound to one visible person. Then leave the caption empty and explain in note."},
   "note": {"type": ["string", "null"], "description": "Why the sample is not usable."}},
 "required": ["caption", "usable", "note"], "additionalProperties": false}

{"type": "object", "title": "Critique",
 "properties": {
   "approved": {"type": "boolean"},
   "notes": {"type": "array", "items": {"type": "string"}, "description": "What the captioner must change, when not approved. Specific and short."}},
 "required": ["approved", "notes"], "additionalProperties": false}
```

### Records (`Models/Records.swift`)

```swift
public enum SampleStatus: String, Codable, Sendable, CaseIterable {
    case written, skipped, needsMapping = "needs_mapping", unusable, rejected, failed
}

public struct ModelNames: Sendable, Equatable {
    public var requested: String
    public var served: String?
}

/// The response record. Key order on output is fixed: sample_id, status, source, skill, profile,
/// captioner, critic, attempts, requests, caption, critique, then any `extra` keys in their
/// stored order. Decoding is lenient so a hand-edited record still loads: missing fields take
/// the defaults shown; unknown keys are kept in `extra` and written back unchanged.
public struct ResponseRecord: Sendable, Equatable {
    public var sampleID: String                        // sample_id
    public var status: SampleStatus = .written
    public var source: String = "model"                // "model" | "human"
    public var skill: String = ""
    public var profile: String = ""
    public var captioner: ModelNames = .init(requested: "", served: nil)
    public var critic: ModelNames? = nil               // null when no critic is configured
    public var attempts: Int = 0
    public var requests: Int = 0
    public var caption: Caption? = nil
    public var critique: Critique? = nil
    public var extra: JSONObject = [:]
    public var isHumanFinal: Bool { source == "human" }
    public init(sampleID: String, status: SampleStatus, source: String = "model", skill: String, profile: String,
                captioner: ModelNames, critic: ModelNames?, attempts: Int = 0, requests: Int = 0,
                caption: Caption? = nil, critique: Critique? = nil, extra: JSONObject = [:])
    public init(json: JSONValue) throws                // ConfigurationError when not an object or sample_id missing
    public var jsonValue: JSONValue { get }
}

public struct Outcome: Sendable, Equatable {
    public let sampleID: String
    public let status: SampleStatus
    public let caption: String?
    public let notes: [String]
    public let record: ResponseRecord?
    public init(sampleID: String, status: SampleStatus, caption: String? = nil, notes: [String] = [], record: ResponseRecord? = nil)
}

public struct RunSummary: Sendable {
    public let outcomes: [Outcome]
    public let elapsed: TimeInterval
    public let sink: JSONObject                        // whatever finalize() returned
    public func counts() -> [SampleStatus: Int]
    /// {"counts": {...}, "elapsed_s": <1 decimal>, "sink": {...}, "samples": [{"id","status","notes"}]} as cli.py writes to _summary.json
    public var report: JSONValue { get }
}
```

### Tests `ModelsTests.swift` must pass

1. `Job.load(contentsOf:)` on `examples/job.example.yaml` (path relative to the package:
   `../examples/job.example.yaml`): two concepts, three samples, `unmapped("unmapped.png")`
   held, `endpoints.critic?.baseURL == "http://localhost:8000/v1"`, `captionerThinking == .low`.
2. Round trip: `Job.load(yaml: job.dump())` equals `job`, including a `nil` sample.
3. Validation: duplicate triggers, empty mapping, unknown trigger, blank locator,
   `singleSubjectOnly` with two triggers, unknown top-level key, non-mapping document each throw
   `ConfigurationError` with the messages above.
4. `sampleView` for the two fixture mappings serializes to the exact strings above.
5. `JSONValue.pythonDumps`: `{"a": "héllo \"q\" \\ \n \t \u0001 😀"}` round-trips to the same
   text Python prints (`{"a": "héllo \"q\" \\ \n \t \u0001 😀"}` with the escapes as written);
   `indent: 1` of a nested record matches Python's layout; empty object/array render `{}`/`[]`.
6. `ResponseRecord` encodes keys in the fixed order; decoding `{"sample_id": "x", "source": "human"}`
   yields `isHumanFinal == true` with defaults; unknown keys survive a decode/encode round trip.
7. `Caption` decodes `{"caption": "x"}` with `usable == true`, `note == nil`; `Critique`
   decodes `{"approved": true}` with empty notes.

---

## Module `skills`

Python counterpart: `skills.py`. File: `Skills/Skill.swift`.

```swift
public struct Skill: Sendable, Equatable {
    public let name: String
    public let description: String
    public let body: String
    public let directory: URL
    public let references: [String]            // metadata.references, inlined after the body
    public let metadata: JSONObject
    public init(name: String, description: String, body: String, directory: URL, references: [String] = [], metadata: JSONObject = [:])

    public func reference(_ relative: String) throws -> String   // references/<relative>; ConfigurationError "skill '<name>' has no reference '<relative>'"
    public func instructions() throws -> String                  // body.trimmed + "\n\n" + each reference.trimmed, joined by "\n\n", plus a trailing "\n"
    public func profiles() -> [String]                           // sorted stems of references/profiles/*.md, [] when missing
    public func profile(_ nameOrPath: String) throws -> String   // ".md" path that exists -> its text; else references/profiles/<name>.md; else ConfigurationError
}

public enum Skills {
    public static let defaultSkillName = "diffusion-training-captioner"
    public static func defaultSkillURL() -> URL                  // Bundle.module, Resources/Skills/<defaultSkillName>
    public static func load(_ directory: URL? = nil) throws -> Skill
    public static func load(path: String?) throws -> Skill       // expands "~", nil -> default
    /// Split "---\n<yaml>\n---\n" frontmatter; (empty, text) when there is none. ConfigurationError:
    /// "SKILL.md frontmatter is not closed", "SKILL.md frontmatter is not valid YAML: ...",
    /// "SKILL.md frontmatter must be a mapping".
    static func frontmatter(_ text: String) throws -> (JSONObject, String)
}
```

`load` rules, in order (all `ConfigurationError`):

1. `<dir>/SKILL.md` must exist: `"not a skill directory (no SKILL.md): <dir>"`.
2. `dirName = NFKC(dir.standardizedFileURL.lastPathComponent)`; `name = NFKC(meta.name ?? dirName)`.
3. `name` must match `^[a-z0-9]+(?:-[a-z0-9]+)*$` and be at most 64 characters:
   `"skill name '<name>' must be lowercase letters/digits separated by single hyphens"`.
4. `name == dirName`: `"skill name '<name>' does not match directory '<dirName>'"`.
5. `description` non-blank after trimming: `"skill '<name>': frontmatter needs a non-blank description"`.
6. `metadata` is a mapping if present: `"skill '<name>': metadata must be a mapping"`.
7. `references = metadata.references` as strings (missing -> []); each must exist (checked at load).
8. Other frontmatter fields (`allowed-tools`, `license`, ...) are accepted and ignored.

The profile-by-path rule: a `nameOrPath` ending in `.md` that is an existing file is read
verbatim; otherwise look under `references/profiles/`; otherwise
`"unknown profile '<x>'; skill '<name>' has [<profiles>], or pass a path to a .md file"`.

Frontmatter regex equivalent: text starts with `---`, then `[ \t]*\r?\n`, capture up to the
first line that is `---[ \t]*` followed by `\r?\n` or end of text; body is everything after.

### Tests `SkillsTests.swift` must pass

1. `Skills.load()` (default): `name == "diffusion-training-captioner"`, `instructions()`
   contains `"# Core Caption Policy"`, `profiles() == ["flux-image", "h3-still", "ltx-image", "plain"]`,
   `profile("h3-still")` contains `"[Shot 1]"`, `profile("nope")` throws.
2. A temp skill `my-skill` with frontmatter `description: Mine.` and `metadata.references: [extra.md]`,
   `references/extra.md` = `EXTRA TEXT`, `references/unused.md` = `NEVER`: `name == "my-skill"`,
   `instructions()` contains BODY TEXT and EXTRA TEXT, not NEVER; `profile("<tmp>/shape.md") == "SHAPE TEXT"`.
3. Validation: directory `Bad_Name` (no name field) throws; missing description throws; a
   directory without SKILL.md throws; a `name` longer than 64 characters throws; NFKC: a
   directory named with a fullwidth letter normalizes and then fails the regex.
4. `frontmatter`: no frontmatter returns `([:], text)`; unclosed throws; CRLF line endings parse.

---

## Module `prompt`

Python counterpart: `prompt.py`. File: `Prompt/Prompt.swift`.

```swift
public enum Prompt {
    public static let userTurn = "Inspect this exact target image and return the configured JSON object."
    public static let captionerTask: String   // verbatim CAPTIONER_TASK, see below
    public static let criticTask: String      // verbatim CRITIC_TASK, see below

    /// Sections: skill.instructions(), profileText, one "# Job policy override: <key>\n\n<text.trimmed>\n"
    /// per policy override (job order), "ACTIVE JOB CONFIGURATION\n" + job.sampleView(mapping).pythonDumps(),
    /// then the task text. Each section is trimmed of whitespace and newlines; joined with "\n\n"; one trailing "\n".
    public static func captionerInstructions(skill: Skill, profileText: String, job: Job,
                                             mapping: OrderedDictionary<String, String>) throws -> String
    public static func criticInstructions(skill: Skill, profileText: String, job: Job,
                                          mapping: OrderedDictionary<String, String>) throws -> String
    public static func criticUserTurn(caption: String) -> String   // "Review this proposed caption against the attached image:\n\n" + caption
}
```

The task texts, copied verbatim (line breaks are literal newlines; no trailing newline):

```
RESPONSE
Return one JSON object. `caption` is the training text only, in the profile's format, with
line breaks as JSON escapes. Keep uncertainty out of it. Apply exactly the mapped triggers to
exactly the mapped subjects; describe any other people ordinarily. If a mapped subject is
absent, too small or obscured, or cannot be bound to one visible person, set `usable` false,
leave `caption` empty and explain in `note`. Do not guess. For single_subject_only jobs any
second identity makes the sample unusable. Do not quote readable text (labels, logos, signs)
verbatim; describe it generically.
```

```
REVIEW TASK (replaces the captioning task above)
You are reviewing a proposed caption against the supplied target image and the ACTIVE JOB
CONFIGURATION. Approve only if every statement in the caption is visible in the image, the
mapped triggers are bound to the right people, no trait the configuration reserves for a
trigger is described, nothing is inferred that a still cannot show (age, biography, sound,
motion), and no readable text is quoted verbatim. Otherwise reject with short, specific notes
the captioner can act on.
```

Python trims with `str.strip()` (all Unicode whitespace). Use
`trimmingCharacters(in: .whitespacesAndNewlines)`.

### Tests `PromptTests.swift` must pass

1. Ordering: index of `"# Core Caption Policy"` < index of `"[Shot 1]"` < index of
   `"ACTIVE JOB CONFIGURATION"`; the text ends with `"describe it generically.\n"`.
2. The job view after `ACTIVE JOB CONFIGURATION` contains `"NORA7"` and not `IVAN9` for the
   solo mapping.
3. Critic text contains `"REVIEW TASK"` and not `"RESPONSE\n"`.
4. **Byte parity with Python.** For the bundled skill, profile `h3-still`, the fixture job and
   mapping `{"NORA7": "The only person in the crop."}`, SHA-256 of the UTF-8 text:
   captioner `cdc285aba4c7b1ec2f33d07e4de67d502f5670e8804a36712514c564d1b6e926`,
   critic `26d8a1f3125c9f2ac334cde96f46f42ecd9319670364d130ecca8b7186323837`
   (computed from `src/concept_captioner` at this commit; recompute if the skill text changes).
   Captioner length is 23257 characters.
5. A policy override `{"tone": "Plain."}` yields a section `# Job policy override: tone\n\nPlain.`
   between the profile and the job configuration.

---

## Module `triggers`

Python counterpart: `stages.py` (`exact_trigger_spans`, `trigger_problems`, the `ModelRetry`
text). File: `Triggers/Triggers.swift`.

```swift
public struct CaptionDeps: Sendable, Equatable {
    public let mapping: OrderedDictionary<String, String>
    public let triggers: [String]           // every trigger the job knows
    public init(mapping: OrderedDictionary<String, String>, triggers: [String])
}

public enum Triggers {
    /// Whole-token occurrences of `trigger` in `text` as UTF-16 offset ranges (start, end), case-sensitive.
    /// A boundary character is anything that is not a letter (L*), mark (M*), number (N*) or "_".
    /// Overlapping scan: the search restarts one code unit after each hit (Python `start = index + 1`).
    /// Both inputs are NFC-normalized by the caller; this function does not normalize.
    public static func exactTriggerSpans(in text: String, trigger: String) -> [(Int, Int)]

    /// NFC-normalize the caption; for each mapped trigger (mapping order) with no span:
    ///   "the mapped trigger <t> must appear exactly in the caption"
    /// then for each job trigger not in the mapping that has a span:
    ///   "<t> is not mapped in this image; do not use that trigger"
    public static func triggerProblems(caption: String, deps: CaptionDeps) -> [String]

    /// The retry text sent back to the model (stages.py ModelRetry):
    /// "Fix the caption: " + problems.joined(separator: "; ") + ". If a mapped subject is not actually visible in this image, do not invent it: set usable to false, leave the caption empty and say why in note."
    public static func retryMessage(problems: [String]) -> String
}
```

Spans are reported in UTF-16 offsets to mirror Python's code-point indices closely enough for
tests (`("NORA7 and NORA7x and xNORA7", "NORA7") == [(0, 5)]`). Implement over an array of
`Character`s or unicode scalars; the test only checks that example and boundary behavior.

### Tests `TriggersTests.swift` must pass

1. `exactTriggerSpans("NORA7 and NORA7x and xNORA7", "NORA7") == [(0, 5)]`.
2. `triggerProblems("A photo of NORA7, a woman.", deps) == []` with
   `deps = CaptionDeps(mapping: ["NORA7": "x"], triggers: ["NORA7", "IVAN9"])`.
3. `triggerProblems("A photo of a woman.", deps) == ["the mapped trigger NORA7 must appear exactly in the caption"]`.
4. `triggerProblems("NORA7 with IVAN9.", deps) == ["IVAN9 is not mapped in this image; do not use that trigger"]`.
5. `"NORA7_x"` and `"NORA7é"` do not count; `"NORA7,"` and `"(NORA7)"` do; a caption written
   with a decomposed `é` adjacent still fails after NFC (document the chosen example).
6. `retryMessage(problems: ["a", "b"])` is exactly the string above with `"a; b"`.

---

## Module `images`

Python counterpart: `images.py`. File: `Images/ProviderImage.swift`.

```swift
public enum Images {
    public static let defaultMaxBytes = 8 * 1024 * 1024
    public static let defaultMaxSide = 3072

    /// Returns bytes ready for a provider: EXIF orientation applied, longer side <= maxSide,
    /// re-encoded as PNG (default) or JPEG (suffix .jpg/.jpeg, quality 0.95) with no metadata,
    /// shrunk by 0.8 per iteration until <= maxBytes. ConfigurationError for non-positive limits,
    /// undecodable data, or when a 1x1 image is still over the cap.
    public static func providerImage(_ data: Data, suffix: String,
                                     maxBytes: Int = defaultMaxBytes, maxSide: Int = defaultMaxSide)
        throws -> (data: Data, mediaType: String)
}
```

Implementation notes (ImageIO):

- `CGImageSourceCreateWithData(data, nil)`; decode with `CGImageSourceCreateThumbnailAtIndex(src, 0,
  [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
  kCGImageSourceThumbnailMaxPixelSize: maxSide, kCGImageSourceShouldCache: false])`. This applies
  the EXIF orientation and bounds the longer side in one step (LANCZOS vs. ImageIO's resampler
  is an accepted difference; the Python output is not byte-compared).
- Encode with `CGImageDestinationCreateWithData(mutableData, UTType.png / .jpeg identifier, 1, nil)`
  and `CGImageDestinationAddImage(dest, image, properties)` where `properties` is `nil` for PNG
  and `[kCGImageDestinationLossyCompressionQuality: 0.95]` for JPEG. No metadata dictionary is
  passed, so EXIF/IPTC/XMP are gone; the image's `colorSpace` travels with the `CGImage`, so the
  ICC profile is embedded (Python keeps `icc_profile` too).
- Alpha: a JPEG destination drops alpha itself; for PNG keep it (Python converts non-RGB/L modes
  to RGB; PNG with alpha is accepted by every provider, so keeping alpha is fine. Document it.)
- Shrink loop: while `encoded.count > maxBytes`, draw into a `CGContext` of
  `max(1, Int(w * 0.8)) x max(1, Int(h * 0.8))` with high interpolation and re-encode. If the
  image is already 1x1, throw `"image could not be encoded below the byte cap"`.
- Media types: `"image/png"`, `"image/jpeg"`. WebP input decodes through ImageIO on macOS 15;
  output is always PNG unless the suffix is JPEG (matches Python).

### Tests `ImagesTests.swift` must pass

1. A 256x256 synthetic PNG (fixture) comes back PNG, `mediaType == "image/png"`, same size,
   decodes with `CGImageSourceCreateWithData`, and has no EXIF/TIFF dictionary in
   `CGImageSourceCopyPropertiesAtIndex`.
2. A 4000x1000 synthetic image comes back 3072x768.
3. Suffix `.jpg` yields `image/jpeg`.
4. `maxBytes: 2000` on a noisy 512x512 image shrinks until under the cap (each iteration 0.8x);
   the result is smaller than 512 on both sides.
5. `maxBytes: 0` throws; random bytes throw.
6. An input with EXIF orientation 6 (fixture written through ImageIO with
   `kCGImagePropertyOrientation: 6`) comes back rotated (width and height swapped) and without
   the orientation tag.

---

## Module `modelclient`

Python counterparts: `models.py` (resolve), pydantic-ai's provider models and its output-retry
loop, `stages.py` (`build_captioner`, `build_critic`, `served_model`). Files:
`ModelClient/*.swift`.

### Transport (`ModelClient/HTTPTransport.swift`)

```swift
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]      // lowercase keys
    public let body: Data
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession-backed. Follows redirects; drops the Authorization header when a redirect leaves
/// the original host (Hub `resolve` URLs redirect to a CDN that rejects a second auth mechanism).
public struct URLSessionTransport: HTTPTransport {
    public init(session: URLSession = .shared, timeout: TimeInterval = 600)
    public func send(_ request: URLRequest) async throws -> HTTPResponse
}
```

### Protocol and value types (`ModelClient/ModelClient.swift`)

```swift
public enum UserContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mediaType: String)
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: [UserContent]
    public init(role: Role, content: [UserContent])
    public static func user(_ text: String) -> ChatMessage
    public static func user(_ content: [UserContent]) -> ChatMessage
    public static func assistant(_ text: String) -> ChatMessage
}

public struct OutputRequest: Sendable, Equatable {
    public var name: String            // "Caption" | "Critique" (tool / schema name)
    public var schema: JSONValue       // JSON Schema object
    public var mode: OutputMode
    public init(name: String, schema: JSONValue, mode: OutputMode)
}

public struct RequestSettings: Sendable, Equatable {
    public static let serviceTiers = ["auto", "default", "flex", "priority"]
    public static let acceptedButIgnored = ["timeout", "tool_choice", "cache"]
    public var thinking: ThinkingLevel = .none
    public var thinkingAtProviderDefault: Bool = false   // pydantic-ai `thinking: true`
    public var temperature: Double? = nil
    public var maxTokens: Int? = nil
    public var seed: Int? = nil
    public var topP: Double? = nil
    public var topK: Int? = nil
    public var stopSequences: [String]? = nil
    public var presencePenalty: Double? = nil
    public var frequencyPenalty: Double? = nil
    public var logitBias: [String: Int]? = nil
    public var parallelToolCalls: Bool? = nil
    public var serviceTier: String? = nil
    public var extraHeaders: [String: String] = [:]      // on top of the client's own headers
    public var extraBody: JSONObject = [:]   // merged into the provider request body last (vLLM extra_body etc.)
    public var ignoredKeys: [String] = []    // the acceptedButIgnored keys the settings carried
    public init(thinking: ThinkingLevel = .none, thinkingAtProviderDefault: Bool = false, temperature: Double? = nil,
                maxTokens: Int? = nil, seed: Int? = nil, topP: Double? = nil, topK: Int? = nil,
                stopSequences: [String]? = nil, presencePenalty: Double? = nil, frequencyPenalty: Double? = nil,
                logitBias: [String: Int]? = nil, parallelToolCalls: Bool? = nil, serviceTier: String? = nil,
                extraHeaders: [String: String] = [:], extraBody: JSONObject = [:], ignoredKeys: [String] = [])
    public var thinks: Bool                  // thinkingAtProviderDefault || thinking != .none
    public var thinkingEffort: ThinkingLevel? // nil when off or left to the provider; clients read this, not `thinking`
    /// From EndpointSpec.settings: the whole unified pydantic-ai ModelSettings key set is accepted and
    /// type-checked (temperature, max_tokens, seed, top_p, top_k, stop_sequences, presence_penalty,
    /// frequency_penalty, logit_bias, parallel_tool_calls, service_tier, extra_headers, extra_body),
    /// so a job file is portable between the two implementations. "thinking" overrides the job level:
    /// a ThinkingLevel string, `true` (on at the provider's default effort) or `false` (off).
    /// acceptedButIgnored keys are recorded in ignoredKeys (timeout: the transport's timeout governs;
    /// tool_choice: the stage forces the output tool; cache: no prompt caching here). Any other key,
    /// including provider-prefixed `openai_*` / `anthropic_*` / `google_*` ones, is an error
    /// ("unsupported setting '<k>'"), so typos surface at resolve time. Each client sends the keys
    /// its API expresses and drops the rest, as pydantic-ai does (see each client's `settings:` line).
    public init(settings: JSONObject, thinking: ThinkingLevel) throws
}

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public static let unknown = TokenUsage(inputTokens: nil, outputTokens: nil)
}

public struct ModelReply: Sendable, Equatable {
    public var text: String            // the structured JSON as text (tool arguments in tool mode), fences stripped
    public var servedModel: String?    // the model name the provider reports (OpenAI `model`, Anthropic `model`, Gemini `modelVersion`)
    public var usage: TokenUsage
    public var requestCount: Int       // HTTP requests this reply cost (1)
    public init(text: String, servedModel: String?, usage: TokenUsage = .unknown, requestCount: Int = 1)
}

public protocol ModelClient: Sendable {
    /// The model name as requested (for the response record).
    var requestedModel: String { get }
    /// One provider round trip. `messages` is the whole conversation (first message is a user turn).
    func request(instructions: String, messages: [ChatMessage], output: OutputRequest,
                 settings: RequestSettings) async throws -> ModelReply
}

extension ModelClient {
    /// Single-turn convenience: wraps `user` in one user message.
    public func request(instructions: String, user: [UserContent], output: OutputRequest,
                        settings: RequestSettings) async throws -> ModelReply
}
```

Common rules for the three clients:

- Non-2xx -> `ModelError.http(status:body:)` with the body text (truncated to 4 KB).
- Transport errors -> `ModelError.transport`.
- A reply without a text/arguments payload -> `ModelError.malformedReply`.
- `prompted` mode: append to `instructions`:
  `"\n\nAlways respond with a JSON object matching this schema:\n\n" + schema.pythonDumps() + "\n\nDon't include any text or Markdown fencing before or after."`
  and strip a leading ```` ```json ```` / trailing ```` ``` ```` fence from the reply text.
- History: assistant turns are sent as plain text content; user turns carry text and images.
- `extraBody` keys are merged into the top-level request object after everything else.

### OpenAICompatibleClient (`ModelClient/OpenAICompatibleClient.swift`)

Covers OpenAI (`https://api.openai.com/v1`), OpenRouter (`https://openrouter.ai/api/v1`) and
vLLM (`base_url` from the spec).

```swift
public struct OpenAICompatibleClient: ModelClient {
    public let baseURL: URL
    public let apiKey: String?
    public let requestedModel: String
    public let transport: any HTTPTransport
    public let extraHeaders: [String: String]   // OpenRouter: HTTP-Referer / X-Title may be set by the app
    public init(baseURL: URL, apiKey: String?, model: String, transport: any HTTPTransport = URLSessionTransport(),
                extraHeaders: [String: String] = [:])
}
```

Request: `POST {baseURL}/chat/completions`, headers `Authorization: Bearer <key>` (omitted when
nil), `Content-Type: application/json`. Body:

```
model, messages: [{role: "system", content: instructions}, {role: "user"|"assistant", content: [...]}, ...]
  user content parts: {type: "text", text} | {type: "image_url", image_url: {url: "data:<mediaType>;base64,<data>"}}
  assistant content: a plain string
native:   response_format: {type: "json_schema", json_schema: {name, schema, strict: true}}
prompted: response_format: {type: "json_object"}            (plus the instruction suffix)
tool:     tools: [{type: "function", function: {name, parameters: schema, strict: true}}],
          tool_choice: {type: "function", function: {name}}
thinking: reasoning_effort: "<level>" for minimal|low|medium|high|xhigh; "medium" for thinking: true (pydantic-ai's map); omitted for none
settings: temperature, max_completion_tokens (maxTokens), seed, top_p, stop (stopSequences), presence_penalty,
          frequency_penalty, logit_bias, service_tier as is, parallel_tool_calls (tool mode only); top_k dropped
          (not a Chat Completions parameter; vLLM takes it via extra_body); extraHeaders on the request; then extraBody merged
```

Reply: `choices[0].message.content` (native/prompted) or
`choices[0].message.tool_calls[0].function.arguments` (tool); `servedModel = model`;
usage from `usage.prompt_tokens` / `usage.completion_tokens`.

### AnthropicClient (`ModelClient/AnthropicClient.swift`)

```swift
public struct AnthropicClient: ModelClient {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let apiVersion = "2023-06-01"
    public static let defaultMaxTokens = 16000
    public let baseURL: URL
    public let apiKey: String
    public let requestedModel: String
    public let transport: any HTTPTransport
    public init(apiKey: String, model: String, baseURL: URL = defaultBaseURL, transport: any HTTPTransport = URLSessionTransport())
}
```

Request: `POST {baseURL}/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`,
`Content-Type: application/json`. Body:

```
model, max_tokens: settings.maxTokens ?? 16000, system: instructions,
messages: [{role, content: [{type: "text", text} | {type: "image", source: {type: "base64", media_type, data}}]}]
native:   output_config: {format: {type: "json_schema", schema}}
prompted: nothing extra (instruction suffix only)
tool:     tools: [{name, description: "Return the <name> object.", input_schema: schema, strict: true}],
          tool_choice: {type: "auto"}, and append to `system`: "\n\nCall the tool `<name>` exactly once with your answer."
          (forced tool_choice is a 400 on current models)
thinking: none -> omit `thinking` and `output_config.effort`;
          otherwise thinking: {type: "adaptive"} and output_config.effort = minimal->"low", low->"low", medium->"medium", high->"high", xhigh->"xhigh"
          thinking: true -> thinking: {type: "adaptive"} with no output_config.effort (the API's default)
settings: temperature, top_p, top_k (only when thinking is off; the API rejects sampling params with thinking on);
          stop_sequences; service_tier auto -> "auto", default -> "standard_only", flex/priority dropped;
          seed, penalties, logit_bias, parallel_tool_calls unsupported -> ignored; extraHeaders on the request
```

Reply: first `content` block of type `text` (native/prompted) or the `tool_use` block's
`input` re-serialized as JSON text (tool); `stop_reason == "refusal"` ->
`ModelError.malformedReply("refusal: <stop_details.explanation>")`; `servedModel = model`;
usage from `usage.input_tokens` / `usage.output_tokens`.

### GeminiClient (`ModelClient/GeminiClient.swift`)

```swift
public struct GeminiClient: ModelClient {
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    public let baseURL: URL
    public let apiKey: String
    public let requestedModel: String
    public let transport: any HTTPTransport
    public init(apiKey: String, model: String, baseURL: URL = defaultBaseURL, transport: any HTTPTransport = URLSessionTransport())
}
```

Request: `POST {baseURL}/models/{model}:generateContent`, headers `x-goog-api-key`,
`Content-Type: application/json`. Body:

```
systemInstruction: {parts: [{text: instructions}]}
contents: [{role: "user"|"model", parts: [{text} | {inlineData: {mimeType, data: base64}}]}]
generationConfig:
  native:   responseMimeType: "application/json", responseJsonSchema: schema
  prompted: responseMimeType: "application/json"
  tool:     (no generationConfig output fields) tools: [{functionDeclarations: [{name, description, parameters: schema}]}],
            toolConfig: {functionCallingConfig: {mode: "ANY", allowedFunctionNames: [name]}}
  thinkingConfig: none -> omitted; minimal|low -> {thinkingLevel: "low"}; medium -> "medium"; high|xhigh -> "high";
                  thinking: true -> {includeThoughts: true} with no level (as pydantic-ai sends it)
  temperature, maxOutputTokens, topP, topK, seed, stopSequences, presencePenalty, frequencyPenalty
  (logit_bias, parallel_tool_calls, service_tier unsupported -> ignored; extraHeaders on the request)
```

Reply: `candidates[0].content.parts[]` first part with `text` (native/prompted) or with
`functionCall.args` re-serialized (tool); `servedModel = modelVersion`; usage from
`usageMetadata.promptTokenCount` / `candidatesTokenCount`. A `promptFeedback.blockReason` with no
candidates is `ModelError.malformedReply`.

### Resolve (`ModelClient/Resolve.swift`)

```swift
public enum Provider: String, Sendable, CaseIterable {
    case google, anthropic, openai, openrouter, vllm
}

public protocol KeyStore: Sendable {
    /// nil when no key is stored. For `.vllm` the key is optional; everyone else requires one.
    func apiKey(for provider: Provider) throws -> String?
    /// User-configured endpoint from Settings, never the job file.
    var vllmBaseURL: String? { get }
}

public struct StaticKeyStore: KeyStore {
    public init(_ keys: [Provider: String], vllmBaseURL: String? = nil)
}

public struct ResolvedEndpoint: Sendable {
    public let client: any ModelClient
    public let settings: RequestSettings
    public let outputMode: OutputMode
    public let requested: String          // model name as requested (record)
    public let concurrency: Int
    public init(client: any ModelClient, settings: RequestSettings = .init(), outputMode: OutputMode = .native,
                requested: String? = nil, concurrency: Int = 4)   // requested defaults to client.requestedModel
}

extension Endpoints {
    /// "provider:model" -> EndpointSpec; ConfigurationError "endpoint spec must look like provider:model, got '<s>'"
    public static func parseSpec(_ spec: String) throws -> EndpointSpec

    public static func resolve(_ spec: String, thinking: ThinkingLevel = .none, keys: any KeyStore,
                               transport: any HTTPTransport = URLSessionTransport()) throws -> ResolvedEndpoint
    public static func resolve(_ spec: EndpointSpec, thinking: ThinkingLevel = .none, keys: any KeyStore,
                               transport: any HTTPTransport = URLSessionTransport()) throws -> ResolvedEndpoint
}
```

`resolve` rules (ConfigurationError unless noted):

- `kind == "gemini"`: `"unknown endpoint kind 'gemini' (Gemini is kind: google)"`.
- unknown kind: `"unknown endpoint kind '<k>'; expected one of google, anthropic, openai, openrouter, vllm"`.
- `base_url` on `openai`: `"kind: openai always talks to api.openai.com and takes no base_url; for another
  OpenAI-compatible server use kind: vllm with base_url (its key is VLLM_API_KEY)"`. A job file may have
  been downloaded, so its `base_url` must never pair with the stored OpenAI key (Python `_model`).
- `base_url` with a kind other than `vllm`: `"base_url is only meaningful for kind vllm, not '<k>'"`.
- `vllm` without `base_url`: `"kind vllm needs base_url"` (the CLI may fill it from `VLLM_BASE_URL`; the library does not read the environment).
- `vllm` `base_url` is checked like Python `check_base_url`: no host -> `"base_url '<u>' has no host"`;
  `https` is accepted anywhere; `http` only when the host is private per Python `_private_host`
  (a single-label name with no dot or colon, `localhost.localdomain`, a `.local`/`.internal` name, or an
  IP literal that is loopback, private or link-local); anything else ->
  `"base_url '<u>' must be https, or http to a loopback/private address; images and the endpoint key would
  otherwise travel in clear text to a public host"`.
- `openrouter` -> `OpenAICompatibleClient(baseURL: https://openrouter.ai/api/v1)`; `openai` ->
  `https://api.openai.com/v1` always; `anthropic` -> `AnthropicClient`; `google` -> `GeminiClient`.
- Key: `keys.apiKey(for:)`; nil for a provider other than vllm -> `ModelError.missingKey(provider)`.
  For vLLM, attach the key only when the parsed job host equals the parsed host of
  `keys.vllmBaseURL` (case-insensitive); absent or different configured host means no key.
  Python uses `VLLM_BASE_URL` for that user configuration, including when it supplies the
  endpoint omitted by the job. Neither implementation reads the configured host from the job.
- Reject URL userinfo, escaped hosts, whitespace, control characters, backslashes and invalid
  ports before requests. Check and send the same parsed URL in Swift.
- Job `extra_headers` cannot set authentication or routing: reject names containing
  `authorization` or `apikey`, ending in `token`, or equal to `cookie`, `setcookie`, `host`
  after lowercasing and removing hyphens/underscores. Other headers remain supported.
- `settings = try RequestSettings(settings: spec.settings, thinking: thinking)`; Python only sets
  thinking when the level is not `none`, which this matches since `.none` emits nothing.
- `requested = spec.model`, `concurrency = spec.concurrency`, `outputMode = spec.outputMode`.

### Structured output layer (`ModelClient/StructuredStage.swift`)

Mirrors pydantic-ai's `Agent(output_type=..., retries=1)` plus an output validator.

```swift
public struct StageRun<Output: Sendable>: Sendable {
    public let output: Output
    public let messages: [ChatMessage]      // the whole conversation including the final assistant turn
    public let servedModel: String?
    public let requests: Int                // provider requests made in this run (1 or 2)
    public let usage: TokenUsage
}

public enum StageFailure: Error, LocalizedError, Sendable {
    /// The validator rejected the reply `retries + 1` times. `problems` is the last validator output.
    case rejected(problems: [String], lastReply: ModelReply, requests: Int, servedModel: String?)
    /// The reply could not be decoded into Output `retries + 1` times.
    case undecodable(reason: String, lastReply: ModelReply, requests: Int, servedModel: String?)
}

public struct StructuredStage<Output: Decodable & Sendable>: Sendable {
    public let name: String                 // "captioner" | "critic"
    public let endpoint: ResolvedEndpoint
    public let output: OutputRequest
    public let retries: Int                 // 1 (pydantic-ai retries=1)
    public init(name: String, endpoint: ResolvedEndpoint, schemaName: String, schema: JSONValue, retries: Int = 1)

    /// Sends `messages` with `instructions`; decodes the reply as Output (fences stripped);
    /// runs `validate` (nil or empty = accepted). On a decode failure or validator problems,
    /// appends the assistant text and a user retry turn, and asks once more (retries times).
    /// The retry turn text is `RetryPrompt.validator(retryMessage(problems), mode:)` or, for
    /// decode failures, `RetryPrompt.undecodable(failure)`.
    public func run(instructions: String, messages: [ChatMessage],
                    validate: @Sendable (Output) -> [String] = { _ in [] },
                    retryMessage: @Sendable ([String]) -> String = { $0.joined(separator: "; ") })
        async throws -> StageRun<Output>
}
```

Decoding: `Output` via `JSONDecoder` from the reply text (after fence stripping). For `Caption`
the lenient defaults apply.

```swift
/// Why a reply did not decode, as pydantic would report it: one `ErrorDetails` record
/// (`type`, `loc` with field names and array indices, `msg`) plus a one-line `message`.
public struct DecodeFailure: Error, Sendable, Equatable

/// The retry user turn, byte for byte pydantic-ai 2.55 `RetryPromptPart.model_response()`.
public enum RetryPrompt {
    public static let suffix = "\n\nFix the errors and try again."
    /// Validator feedback (ModelRetry). Native and prompted output carry no tool name, so the
    /// text is "Validation feedback:\n" + feedback + suffix; tool output sends feedback + suffix.
    public static func validator(_ feedback: String, mode: OutputMode) -> String
    /// A decode failure: "1 validation error:\n```json\n" + [record] as json.dumps(indent=2)
    /// + "\n```" + suffix.
    public static func undecodable(_ failure: DecodeFailure) -> String
}
```

`StructuredStage.decode` maps `DecodingError` onto pydantic's vocabulary: `keyNotFound` ->
`missing` / "Field required" with the key appended to `loc`; `typeMismatch` and `valueNotFound`
-> `<string|bool|int|float|list|dict>_type` / "Input should be a valid <string|boolean|integer|
number|list|dictionary>"; `dataCorrupted` at the root -> `json_invalid` / "Invalid JSON: <detail>",
elsewhere `value_error` / "Value error, <detail>". Documented deviations from pydantic-ai: always
one record (`JSONDecoder` stops at the first problem where pydantic lists them all), the
`json_invalid` detail is Foundation's parser message rather than serde's, and `input` is omitted
in tool mode too (pydantic-ai keeps it only for tool-output retries).

### Tests `ModelClientTests.swift` must pass (StubTransport, no network)

1. `resolve` for the five documented specs returns the expected client type, `requested ==`
   the part after the colon, `settings.thinking == .low` when asked; `gemini:` throws a message
   containing `"kind: google"`; `parseSpec("no-colon")` throws; `google` with `base_url` throws;
   `vllm` without `base_url` throws; a missing key is `ModelError.missingKey`.
2. `EndpointSpec(kind: "vllm", model: "Qwen/x", baseURL: "http://pod:8000/v1", outputMode: .prompted)`
   resolves to an `OpenAICompatibleClient` whose `baseURL` is `http://pod:8000/v1` and
   `outputMode == .prompted`; `settings: {temperature: 0.2}` lifts `temperature == 0.2`, no thinking.
   `openai` with any `base_url` throws a message containing `"takes no base_url"`. For `vllm`,
   `https://pod-1234.proxy.runpod.net/v1`, `http://localhost:8000/v1` and `http://10.0.0.5:8000/v1`
   resolve; `http://evil.example.com/v1` and `http://8.8.8.8:8000/v1` throw a message containing
   `"must be https"`.
3. OpenAI client, native mode: the recorded request body has `response_format.type == "json_schema"`,
   `json_schema.strict == true`, the image part is a `data:image/png;base64,` URL, the system
   message is first, `reasoning_effort == "low"`; the reply parses `choices[0].message.content`
   and `servedModel` from `model`. Tool mode: `tools[0].function.name == "Caption"` and arguments
   are returned as text. Prompted mode: `response_format.type == "json_object"` and the
   instructions end with the schema suffix; a fenced reply is unfenced.
4. Anthropic client: headers `x-api-key` and `anthropic-version`; `output_config.format.type == "json_schema"`;
   image block `source.type == "base64"`; thinking `.high` -> `thinking.type == "adaptive"` and
   `output_config.effort == "high"`; `.none` -> no `thinking` key; tool mode has `tool_choice.type == "auto"`
   and `tools[0].strict == true`; a `tool_use` block's input is returned as JSON text;
   `stop_reason: "refusal"` throws `malformedReply`.
5. Gemini client: URL ends with `models/<m>:generateContent`, `x-goog-api-key` header,
   `generationConfig.responseMimeType == "application/json"`, `responseJsonSchema` present,
   `inlineData.mimeType == "image/png"`, `thinkingConfig.thinkingLevel == "high"` for `.xhigh`;
   `servedModel` from `modelVersion`.
6. HTTP 429 with a body -> `ModelError.http(status: 429, ...)`; a thrown transport error ->
   `ModelError.transport`.
7. (`StructuredStageTests.swift`) `StructuredStage<Caption>` with a `FakeModelClient`: first reply fails the validator, the
   second request's last message is a user turn whose text is exactly
   `"Validation feedback:\n" + <validator message> + "\n\nFix the errors and try again."` in
   native and prompted mode and `<validator message> + "\n\nFix the errors and try again."` in
   tool mode, the assistant's first reply precedes it, and `requests == 2`. Two failures ->
   `StageFailure.rejected` with `requests == 2`. An undecodable reply followed by a good one
   succeeds with `requests == 2`; its retry turn is the `json_invalid` record, and a reply
   missing `caption` retries with exactly pydantic-ai's `missing` / "Field required" text.

---

## Module `runner`

Python counterpart: `runner.py`. File: `Runner/Runner.swift`.

```swift
public struct Runner: Sendable {
    public let job: Job
    public let captioner: ResolvedEndpoint
    public let critic: ResolvedEndpoint?
    public let skill: Skill
    public let profileName: String
    public let profileText: String
    public let concurrency: Int
    public var overwrite: Bool

    /// skill nil -> Skills.load(path: job.skill); profile nil -> job.profile; concurrency nil -> captioner.concurrency.
    public init(job: Job, captioner: ResolvedEndpoint, critic: ResolvedEndpoint? = nil, skill: Skill? = nil,
                profile: String? = nil, concurrency: Int? = nil, overwrite: Bool = false) throws

    /// Yields each sample's outcome as it completes, at most `concurrency` samples in flight.
    /// `only` restricts to those sample ids. Source iteration errors finish the stream with that error.
    public func stream(source: some ImageSource, sink: some CaptionSink, only: Set<String>? = nil)
        -> AsyncThrowingStream<Outcome, any Error>

    /// Collects stream(), then sink.finalize(); elapsed is wall-clock.
    public func run(source: some ImageSource, sink: some CaptionSink, only: Set<String>? = nil)
        async throws -> RunSummary
}
```

Per-sample flow (`process`), exactly `runner.py::_process` with deviation 1:

```
mapping = job.mapping(for: id)            nil -> Outcome(needs_mapping, notes: ["no subject mapping"])
existing = try await sink.record(id)
existing?.isHumanFinal                    -> Outcome(skipped, notes: ["human-final"], record: existing)
!overwrite && sink.exists(id)             -> Outcome(skipped, record: existing)   (record may be nil)
record = base record (status rejected, source model, skill.name, profileName,
         captioner {requested, served: nil}, critic {requested, nil} or nil, attempts 0, requests 0)
image = Images.providerImage(sample.data, suffix: sample.suffix)
deps = CaptionDeps(mapping, job.triggers); instructions = Prompt.captionerInstructions(...)
run = captionerStage.run(instructions, [.user([.text(Prompt.userTurn), .image(...)])],
                         validate: { $0.usable ? Triggers.triggerProblems($0.caption, deps) : [] },
                         retryMessage: Triggers.retryMessage)
   StageFailure.rejected -> record.status = rejected, attempts 1, requests, served, caption = last decodable reply if any;
                            sink.write(id, nil, record); Outcome(rejected, notes: problems, record)
record.attempts = 1; requests += run.requests; captioner.served = run.servedModel; caption = run.output
!usable -> status unusable; sink.write(id, nil, record); Outcome(unusable, notes: [note] if note)
if critic:
    reviewInstructions = Prompt.criticInstructions(...)
    verdict = review(caption, image, reviewInstructions, &record)      // critic stage, single turn
    if !approved:
        feedback = "Reviewer notes:\n- " + (notes.isEmpty ? ["not approved"] : notes).joined("\n- ")
        run = captionerStage.run(instructions, run.messages + [.user(feedback)], same validate)
        attempts = 2; requests += ; served = ; caption =
        verdict = review(...)
        if !approved: sink.write(id, nil, record); Outcome(rejected, notes: verdict.notes, record)
    notes = verdict.notes
record.status = written; sink.write(id, caption, record); Outcome(written, caption, notes, record)
```

`review` sends `[.user([.text(Prompt.criticUserTurn(caption)), .image])]` with the critic
instructions, adds `requests`, sets `critic.served` and `record.critique`.

Any other thrown error (transport, HTTP, `StageFailure.undecodable`, image decoding, sink
errors) -> `Outcome(failed, notes: ["<TypeName>: <description>"])`, no record written (Python
parity). `TypeName` is the Swift type name (`ModelError`), description from `localizedDescription`.

Concurrency: a `withThrowingTaskGroup` that adds a child task per sample from the source stream
and awaits `group.next()` whenever `inFlight == concurrency`; each child returns its `Outcome`
which the stream continuation yields. Cancellation of the stream cancels the group.

### Tests `RunnerTests.swift` must pass (FakeModelClient; mirror `tests/test_runner.py`)

1. Happy path with critic: counts `{written: 2, needsMapping: 1}`; every captioner and critic
   request carried exactly one image; `solo.txt` contains `NORA7`; `pair.json` has
   `status written`, `source model`, `captioner == {requested: "cap-1", served: "cap-1"}`,
   `critic.served == "crit-1"`, `critique.approved == true`; `pair.txt` contains `IVAN9`.
   Rerun -> `{skipped: 2, needsMapping: 1}` with no new requests. Set `pair.json` `source` to
   `human`, `overwrite = true`, `only: ["pair.png", "solo.png"]` -> pair skipped, solo written.
2. Trigger retry + critic feedback: captioner replies (1) no trigger, (2) on a retry prompt a
   caption with the trigger, (3) after "Reviewer notes" a caption with "red coat"; critic
   approves only "red coat". Outcome written, caption contains "red coat", attempts
   `{caption: 3, critic: 2}`, `record.attempts == 2`, `record.requests == 5`.
3. Unusable: `Caption(caption: "", usable: false, note: "face too small")` -> status unusable,
   notes `["face too small"]`, `solo.json` written, no `solo.txt`. Never-approving critic ->
   rejected with notes `["still wrong"]`, no `.txt`.
4. Double trigger failure -> `rejected`, record written with `attempts == 1`, `requests == 2`,
   notes equal to the trigger problems (deviation 1).
5. A client that throws `ModelError.http(500, ...)` -> `failed`, notes
   `["ModelError: ..."]`, no record file.
6. `concurrency: 1` processes samples strictly sequentially (the fake records overlapping
   in-flight counts); `concurrency: 3` with three mapped samples reaches 3 in flight.

---

## Module `sources`

Python counterparts: `sources/base.py`, `sources/local.py`, `types.py::Sample`.
Files: `Sources/Sample.swift`, `Sources/LocalFolderSource.swift`, `Sources/SidecarSink.swift`.

```swift
public struct Sample: Sendable, Equatable {
    public let sampleID: String      // sample_id (file name for folders)
    public let data: Data
    public let suffix: String        // ".png", ".jpg", ...
}

public enum Sources {
    public static let imageSuffixes: Set<String> = [".png", ".jpg", ".jpeg", ".webp"]
}

public protocol ImageSource: Sendable {
    var name: String { get }
    func samples() -> AsyncThrowingStream<Sample, any Error>
    func count() async throws -> Int
    func sampleIDs() async throws -> [String]
}

public protocol CaptionSink: Sendable {
    var name: String { get }
    func exists(_ sampleID: String) async throws -> Bool
    func record(_ sampleID: String) async throws -> ResponseRecord?
    func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws
    func finalize() async throws -> JSONObject
}

public struct LocalFolderSource: ImageSource {
    public let name = "folder"
    public let directory: URL
    public let files: [URL]                          // sorted by file name, image suffixes only
    /// ConfigurationError "input directory does not exist: <dir>" / "image stems collide; sidecar captions would be ambiguous"
    public init(directory: URL) throws
    public func sampleIDs() async throws -> [String]  // file names
    public func count() async throws -> Int
    public func samples() -> AsyncThrowingStream<Sample, any Error>   // reads each file lazily
}

public enum AtomicFile {
    /// Write to a temp file in the same directory, then rename over the target (creates parents).
    public static func write(_ data: Data, to url: URL) throws
    public static func write(text: String, to url: URL) throws
}

public struct SidecarSink: CaptionSink {
    public let name = "sidecar"
    public let directory: URL
    public init(directory: URL) throws               // creates it
    public func captionURL(for sampleID: String) -> URL   // <stem>.txt
    public func recordURL(for sampleID: String) -> URL    // <stem>.json
    public func exists(_ sampleID: String) async throws -> Bool          // caption file exists
    public func record(_ sampleID: String) async throws -> ResponseRecord?  // nil when missing or unparsable
    public func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws
        // record first as record.jsonValue.pythonDumps(indent: 1) UTF-8, then caption when non-nil; both atomic
    public func finalize() async throws -> JSONObject    // {"directory": <path>}
}
```

Sorting: Python sorts `Path` objects, i.e. by full path string with byte order. Use
`files.sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }`.
Stem = file name without its last extension (`Path.stem`).

### Tests `SourcesTests.swift` must pass

1. A folder with `b.png`, `a.jpg`, `notes.txt`, `c.webp` lists `["a.jpg", "b.png", "c.webp"]`;
   `samples()` yields data equal to the files and suffixes `.jpg/.png/.webp`.
2. `a.png` + `a.jpg` throws the stem-collision message; a missing directory throws.
3. `SidecarSink.write("solo.png", caption: "x", record:)` creates `solo.txt` (`"x"`) and
   `solo.json` whose text equals `record.jsonValue.pythonDumps(indent: 1)`; `write` with
   `caption: nil` creates only the json; `exists` reflects the txt; `record()` round-trips and
   returns nil for garbage JSON; the written JSON parses back to an equal `ResponseRecord`.
4. No stray `.tmp` files remain after writes.

---

## Module `hub`

Python counterpart: `sources/hf.py` (semantics; the mechanism differs: Swift speaks the Hub
HTTP API directly, imagefolder convention only). Files: `Hub/HubClient.swift`,
`Hub/ImageFolderMetadata.swift`, `Hub/HubFolderSource.swift`, `Hub/HubFolderSink.swift`.

### HubClient

```swift
public struct RepoID: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let namespace: String?        // "you" in "you/faces"; nil for a bare name
    public let name: String
    public init(_ id: String) throws     // "ns/name" or "name"; HubError.malformed otherwise
    public var id: String { get }        // "ns/name"
    public var description: String { id }
}

public struct HubFile: Sendable, Equatable {
    public let path: String
    public let size: Int
    public let oid: String               // git blob sha or lfs sha256
    public let isLFS: Bool
}

public enum CommitOperation: Sendable {
    case add(path: String, data: Data)   // the client decides regular vs LFS via preupload
    case delete(path: String)
}

public struct CommitResult: Sendable, Equatable {
    public let commitOID: String
    public let commitURL: String
}

public struct HubClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://huggingface.co")!
    public let endpoint: URL
    public let token: String?
    public let transport: any HTTPTransport
    public init(token: String?, endpoint: URL = defaultEndpoint, transport: any HTTPTransport = URLSessionTransport())

    /// GET /api/datasets/{repo}/tree/{revision}?recursive=true  (follows the `Link: <...>; rel="next"` cursor)
    public func listFiles(repo: RepoID, revision: String = "main") async throws -> [HubFile]
    /// GET /datasets/{repo}/resolve/{revision}/{path}
    public func download(repo: RepoID, path: String, revision: String = "main") async throws -> Data
    /// POST /api/repos/create {type: "dataset", name, organization?, private}; 409 is success when existOK.
    public func createRepo(_ repo: RepoID, private isPrivate: Bool = false, existOK: Bool = true) async throws
    /// preupload -> lfs batch -> PUT each LFS object -> commit (NDJSON). One commit for all operations.
    public func commit(repo: RepoID, operations: [CommitOperation], message: String,
                       description: String = "", revision: String = "main") async throws -> CommitResult
    /// Convenience: push_job / fetch_job parity. Path "concept-captioner/job.yaml".
    public func uploadFile(repo: RepoID, path: String, data: Data, message: String) async throws -> CommitResult
}
```

Wire details (all requests carry `Authorization: Bearer <token>` when a token is set; every
path segment of `repo.id`, `revision` and file paths is percent-encoded with
`.urlPathAllowed` minus `/` kept as separator):

- tree: response is a JSON array of `{type: "file"|"directory", path, size, oid, lfs?: {oid, size}}`;
  with `recursive=true` directories may still appear; keep files only. Pagination: when the
  `link` header contains `rel="next"`, GET that URL until absent.
- preupload: `POST /api/datasets/{repo}/preupload/{revision}` body
  `{"files": [{"path", "sample": base64(first 512 bytes), "size"}]}` -> `{"files": [{"path", "uploadMode": "lfs"|"regular", "shouldIgnore"}]}`.
  Files with `shouldIgnore` are dropped from the commit.
- LFS batch: `POST /datasets/{repo}.git/info/lfs/objects/batch`, headers `Accept` and
  `Content-Type` `application/vnd.git-lfs+json`, body
  `{"operation": "upload", "transfers": ["basic", "multipart"], "objects": [{"oid": <sha256 hex>, "size"}], "hash_algo": "sha256"}`.
  For each object with `actions.upload`: `PUT actions.upload.href` with the raw bytes and any
  `actions.upload.header` entries (do not send the Hub token to that host). An object without
  `actions` is already stored. `actions.upload.header.chunk_size` present means multipart ->
  `HubError.unsupported("multipart LFS upload (> 5 GB) is not supported")`.
- commit: `POST /api/datasets/{repo}/commit/{revision}`, `Content-Type: application/x-ndjson`,
  one JSON object per line:
  `{"key": "header", "value": {"summary": message, "description": description}}`,
  `{"key": "file", "value": {"path", "content": base64, "encoding": "base64"}}` for regular files,
  `{"key": "lfsFile", "value": {"path", "algo": "sha256", "oid", "size"}}` for LFS files,
  `{"key": "deletedFile", "value": {"path"}}`. Response `{commitUrl, commitOid}`.
- sha256 via CryptoKit `SHA256`.

### Image folder metadata (`Hub/ImageFolderMetadata.swift`)

```swift
public struct MetadataRow: Sendable, Equatable {
    public var fileName: String            // file_name, relative to the metadata.jsonl directory
    public var caption: String?            // the caption column ("" or absent -> nil)
    public var record: ResponseRecord?     // "<captionColumn>_response", a JSON *string* column (parity with HFDatasetSink); an object is also accepted on read
    public var extra: JSONObject           // other columns, preserved
}

public enum ImageFolderMetadata {
    public static let fileName = "metadata.jsonl"
    public static func parse(_ data: Data, captionColumn: String = "caption") throws -> [MetadataRow]   // one object per non-empty line
    public static func serialize(_ rows: [MetadataRow], captionColumn: String = "caption") -> Data
        // per row: {"file_name", ...extra, "<caption>": caption ?? "", "<caption>_response": record json string or ""}; pythonDumps() per line + "\n"
}
```

### HubFolderSource

```swift
public struct HubFolderSource: ImageSource {
    public let name = "hub"
    public let client: HubClient
    public let repo: RepoID
    public let revision: String
    public let captionColumn: String
    public let files: [HubFile]                       // image files only, sorted by path
    public let rows: [MetadataRow]                    // existing metadata.jsonl rows ([] when absent)
    /// Lists the repo once. HubError.unsupported when the repo has parquet shards and no image files
    /// ("parquet-backed datasets are not supported by the Swift core; convert to imagefolder").
    public static func open(client: HubClient, repo: RepoID, revision: String = "main", captionColumn: String = "caption") async throws -> HubFolderSource
    public func sampleIDs() async throws -> [String]  // file paths relative to the repo root (file_name)
    public func count() async throws -> Int
    public func samples() -> AsyncThrowingStream<Sample, any Error>   // downloads each image lazily
}
```

### HubFolderSink

```swift
public actor HubFolderSink: CaptionSink {
    public nonisolated let name = "hub"
    public enum Origin: Sendable { case hub(HubFolderSource), folder(LocalFolderSource) }
    public init(client: HubClient, repo: RepoID, origin: Origin, captionColumn: String = "caption",
                revision: String = "main", private isPrivate: Bool? = nil,
                commitMessage: String = "Add captions (concept-captioner)", push: Bool = true) throws
        // Origin.hub: target defaults to its repo; existing rows seed the caption/record maps.
        // Origin.folder: images are uploaded in finalize if the repo does not already have them.
    public func exists(_ sampleID: String) async throws -> Bool          // buffered or existing caption
    public func record(_ sampleID: String) async throws -> ResponseRecord?
    public func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws
    /// Builds metadata.jsonl (one row per image in source order; buffered values win over existing),
    /// createRepo(existOK) when pushing to a new target, one commit with the new images (folder origin)
    /// and metadata.jsonl. Returns {"repo_id", "rows", "captions", "pushed"}.
    public func finalize() async throws -> JSONObject
    /// What finalize would upload, for tests and the app's preview.
    public func materialize() async -> (rows: [MetadataRow], newImages: [String])
}
```

### Tests `HubTests.swift` must pass (StubTransport)

1. `listFiles` follows a `Link` next cursor across two pages and keeps files only, marking LFS.
2. `download` builds `/datasets/ns/name/resolve/main/sub/a%20b.png` and sends the bearer token.
3. `commit` with one small file and one 2 MB file: the stub sees preupload (`sample` is 512
   bytes base64, `size` right), an LFS batch with the correct sha256 and size for the file the
   preupload marked `lfs`, a PUT to the batch `href` with the raw bytes and the batch headers and
   no `Authorization`, then an NDJSON commit whose lines are `header`, `file` (base64) and
   `lfsFile` (oid/size). An object without `actions` skips the PUT.
4. `createRepo` treats 409 as success with `existOK`.
5. `HubFolderSource.open` on a stub tree with `a.png`, `b.jpg`, `metadata.jsonl`,
   `README.md` yields two samples in order, existing rows parsed; a tree with only
   `data/train-00000.parquet` throws `HubError.unsupported`.
6. `HubFolderSink` with a hub origin: `exists` is true for a row with a caption, `record`
   returns the parsed `caption_response`; after `write` for a new sample `finalize` commits a
   single `metadata.jsonl` whose rows keep the existing captions, add the new one with its
   record as a JSON string, and the summary is `{repo_id, rows: 2, captions: 2, pushed: true}`.
   With a folder origin and an empty repo tree, the commit also carries the image files.
   `push: false` makes no commit and reports `pushed: false`.

---

## Module `testing` (test target support, `Tests/ConceptCoreTests/Support/`)

Python counterpart: `tests/conftest.py`.

```swift
/// Scripted ModelClient. `respond` is called per request with everything the runner sent; it
/// returns the JSON text of the reply (and optionally a served model name). All requests are recorded.
public actor FakeModelClient: ModelClient {
    public struct Request: Sendable { instructions, messages, output, settings }
    public struct Reply: Sendable { text: String; servedModel: String? }
    public nonisolated let requestedModel: String
    public init(model: String = "fake", respond: @escaping @Sendable (Request) async throws -> Reply)
    public var requests: [Request]                 // recorded, in order
    public var maxInFlight: Int                    // for the concurrency test
    public func request(instructions:messages:output:settings:) async throws -> ModelReply
    // helpers
    public static func caption(_ c: Caption, model: String = "fake") -> FakeModelClient       // always this caption
    public static func critique(_ c: Critique, model: String = "fake") -> FakeModelClient
}

public enum Fixtures {
    public static func syntheticPNG(seed: Int, size: CGSize = .init(width: 256, height: 256)) -> Data  // CoreGraphics: fill, ellipse, rectangle
    public static func imagesFolder() throws -> URL           // temp dir with solo.png (1), pair.png (2), unmapped.png (3)
    public static func tempDirectory() throws -> URL
    public static func job() throws -> Job                    // NORA7 woman / IVAN9 man; solo, pair, unmapped: nil
    public static func h3(_ body: String) -> String           // "integrated_multimodal_description: [Shot 1] <body>\n\noverall_soundscape: N/A\n\nnon_diegetic_music: N/A"
    public static func mappedTriggers(in instructions: String) throws -> Set<String>  // parse the ACTIVE JOB CONFIGURATION line -> inputs.subject_mapping keys
    public static func goodCaption(for instructions: String) throws -> String       // both triggers when pair is mapped, else NORA7
    public static func captionerOK(model: String = "fake") -> FakeModelClient
    public static func criticOK(model: String = "fake") -> FakeModelClient          // approved, notes ["looks right"]
    public static func endpoint(_ client: FakeModelClient, requested: String? = nil, concurrency: Int = 4) -> ResolvedEndpoint
}

/// Scripted HTTPTransport: a handler maps each URLRequest to an HTTPResponse (or throws); records requests.
public actor StubTransport: HTTPTransport {
    public init(_ handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponse)
    public var requests: [URLRequest]
    public static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse
    public static func body(of request: URLRequest) throws -> JSONValue     // parse httpBody
}
```

The skeleton ships these three files fully implemented so every module's tests can be written
from day one; they are owned by the architect until handed over.

---

## Dependencies between modules

```
models      <- (none; Yams)
skills      <- models (JSONValue, ConfigurationError)
prompt      <- models, skills
triggers    <- models (OrderedDictionary)
images      <- models (ConfigurationError)
modelclient <- models (schemas, OutputMode, ThinkingLevel, JSONValue, errors)
runner      <- models, skills, prompt, triggers, images, modelclient, sources
sources     <- models
hub         <- models, sources, modelclient (HTTPTransport)
testing     <- everything (test target)
```

Implementation order that keeps `swift build` green: models -> (skills, triggers, images,
sources, modelclient transport+types) -> prompt -> clients + resolve + stage -> runner -> hub.

## Notes for implementers

- The skeleton compiles with `fatalError("TODO: <module>")` bodies. Replace bodies; do not
  change public signatures without updating this document.
- `Bundle.module` requires the resources declaration in `Package.swift`; it is already there.
- Yams: `try Yams.compose(yaml:)` gives a `Node` whose mapping keeps order; `Yams.serialize(node:)`
  emits block style. Do not use `YAMLEncoder` for `Job` (it sorts keys and cannot express the
  ordered maps); build the `Node` from `jsonValue`.
- Swift 6: `AsyncThrowingStream` continuations are `Sendable`; closures handed to `Task` must
  capture only `Sendable` values. `URLRequest`, `Data`, `URL` are `Sendable`.
- Keep the `fatalError` placeholders out of tests: a disabled test is the skeleton's marker.
- Formatting: `swiftformat app/Sources app/Tests` and `swiftlint lint --quiet app/Sources app/Tests`.
