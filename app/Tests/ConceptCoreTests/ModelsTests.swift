// Job load/dump/validation, sampleView parity, JSONValue serialization, records. See docs/CORE-SPEC.md, module
// `models`. Reference strings were produced with Python's json.dumps / repr on the same inputs.

import ConceptCore
import Foundation
import Testing
import Yams

private let attributesJSON = #"["clothing and removable accessories", "hair presentation", "#
    + #""expression and gaze", "pose", "setting", "lighting", "framing and visible image treatment"]"#

private let noraJSON = #"{"trigger": "NORA7", "class_noun": "woman", "target_concept": "facial_identity", "#
    + #""traits_to_learn": ["distinctive facial identity"], "attributes_to_describe": "# + attributesJSON
    + #", "explicit_boundary_decisions": {}}"#

private let ivanJSON = #"{"trigger": "IVAN9", "class_noun": "man", "target_concept": "facial_identity", "#
    + #""traits_to_learn": ["distinctive facial identity"], "attributes_to_describe": "# + attributesJSON
    + #", "explicit_boundary_decisions": {}}"#

/// The reference `sample_view` text from docs/CORE-SPEC.md for the solo mapping, verbatim.
private let soloView = #"{"training": {"profile": "h3-still", "trigger_handling": "literal"}, "#
    + #""concepts": [{"trigger": "NORA7", "class_noun": "woman", "target_concept": "facial_identity", "#
    + #""traits_to_learn": ["distinctive facial identity"], "#
    + #""attributes_to_describe": ["clothing and removable accessories", "hair presentation", "#
    + #""expression and gaze", "pose", "setting", "lighting", "framing and visible image treatment"], "#
    + #""explicit_boundary_decisions": {}}], "#
    + #""inputs": {"actual_trainer_conditioning": [], "audio_status": "not_applicable", "#
    + #""subject_mapping": {"NORA7": "The only person in the crop."}, "evidence": "attached_target_image"}, "#
    + #""single_subject_only": false, "output": {"caption_language": "English", "delivery": "json_caption_field"}}"#

/// The same for the pair mapping: both concepts in job order, the mapping in mapping order.
private let pairView = #"{"training": {"profile": "h3-still", "trigger_handling": "literal"}, "#
    + #""concepts": ["# + noraJSON + ", " + ivanJSON + #"], "#
    + #""inputs": {"actual_trainer_conditioning": [], "audio_status": "not_applicable", "#
    + #""subject_mapping": {"NORA7": "The woman on the left.", "IVAN9": "The man on the right."}, "#
    + #""evidence": "attached_target_image"}, "#
    + #""single_subject_only": false, "output": {"caption_language": "English", "delivery": "json_caption_field"}}"#

private func configurationMessage(_ body: () throws -> some Any) -> String? {
    do {
        _ = try body()
        return nil
    } catch let error as ConfigurationError {
        return error.message
    } catch {
        return "unexpected error type: \(error)"
    }
}

private func composeYAML(_ text: String) throws -> Node {
    guard let node = try Yams.compose(yaml: text) else { throw ConfigurationError("empty YAML document") }
    return node
}

private func sampleRecord() -> ResponseRecord {
    ResponseRecord(
        sampleID: "solo.png",
        status: .written,
        skill: "diffusion-training-captioner",
        profile: "h3-still",
        captioner: ModelNames(requested: "cap-1", served: "cap-1"),
        critic: ModelNames(requested: "crit-1", served: "crit-1"),
        attempts: 1,
        requests: 2,
        caption: Caption(caption: "A photo of NORA7."),
        critique: Critique(approved: true, notes: ["looks right"])
    )
}

@Suite("models: job")
struct JobTests {
    @Test("loads examples/job.example.yaml")
    func loadsExampleJob() throws {
        let job = try Job.load(contentsOf: Fixtures.exampleJobURL)
        #expect(job.skill == nil)
        #expect(job.profile == "h3-still")
        #expect(job.triggers == ["NORA7", "IVAN9"])
        #expect(job.samples.count == 3)
        #expect(job.samples.keys == ["solo.png", "pair.png", "unmapped.png"])
        #expect(job.unmapped(["solo.png", "pair.png", "unmapped.png"]) == ["unmapped.png"])
        #expect(job.mapping(for: "pair.png")?.keys == ["NORA7", "IVAN9"])
        #expect(job.mapping(for: "missing.png") == nil)
        #expect(job.endpoints?.captioner.kind == "google")
        #expect(job.endpoints?.captioner.model == "gemini-3.8-flash")
        #expect(job.endpoints?.critic?.baseURL == "http://localhost:8000/v1")
        #expect(job.endpoints?.critic?.spec == "vllm:Qwen/Qwen3-VL-32B-Instruct")
        #expect(job.captionerThinking == .low)
        #expect(job.criticThinking == .high)
        #expect(job.singleSubjectOnly == false)
        let nora = try #require(job.concept(for: "NORA7"))
        #expect(nora.classNoun == "woman")
        #expect(nora.attributesToDescribe.count == 8)
        #expect(nora.explicitBoundaryDecisions.keys == [
            "facial_geometry", "eye_color", "hair_color_and_styling", "physique", "age",
        ])
        #expect(job.concept(for: "IVAN9")?.traitsToLearn == Concept.defaultTraitsToLearn)
    }

    @Test("dump/load round trip keeps a null sample and declaration order")
    func roundTrip() throws {
        let job = try Fixtures.job()
        let text = try job.dump()
        #expect(text.contains("unmapped.png: null"))
        let lines = text.split(separator: "\n").map(String.init)
        let order = [
            "profile:",
            "concepts:",
            "samples:",
            "single_subject_only:",
            "captioner_thinking:",
            "critic_thinking:",
            "policy_overrides:",
        ]
        let positions = order.map { key in lines.firstIndex { $0.hasPrefix(key) } ?? -1 }
        #expect(positions == positions.sorted())
        #expect(!positions.contains(-1))
        #expect(!text.contains("skill:"))
        #expect(!text.contains("endpoints:"))
        let back = try Job.load(yaml: text)
        #expect(back == job)
        #expect(back.samples.keys == ["solo.png", "pair.png", "unmapped.png"])
        #expect(back.mapping(for: "unmapped.png") == nil)

        let example = try Job.load(contentsOf: Fixtures.exampleJobURL)
        let again = try Job.load(yaml: example.dump())
        #expect(again == example)
        #expect(again.concept(for: "NORA7")?.explicitBoundaryDecisions.keys
            == example.concept(for: "NORA7")?.explicitBoundaryDecisions.keys)
    }

    @Test("strings that look like other YAML types are quoted on dump")
    func quotesAmbiguousScalars() throws {
        var job = try Fixtures.job()
        job.policyOverrides = ["tone": "yes", "count": "123", "empty": "null"]
        job.skill = "~/skills/mine"
        let text = try job.dump()
        #expect(text.contains("tone: 'yes'"))
        #expect(text.contains("count: '123'"))
        let back = try Job.load(yaml: text)
        #expect(back == job)
        #expect(back.policyOverrides.values == ["yes", "123", "null"])
    }

    @Test("endpoints and settings survive the round trip")
    func endpointsRoundTrip() throws {
        var job = try Fixtures.job()
        job.endpoints = try Endpoints(
            captioner: EndpointSpec(kind: "anthropic", model: "claude-opus-5-5"),
            critic: EndpointSpec(
                kind: "vllm",
                model: "Qwen/x",
                baseURL: "http://pod:8000/v1",
                outputMode: .prompted,
                settings: ["temperature": .double(0.2), "seed": .int(7), "extra_body": .object(["top_k": .int(5)])],
                concurrency: 2
            )
        )
        let text = try job.dump()
        #expect(text.contains("temperature: 0.2"))
        let back = try Job.load(yaml: text)
        #expect(back == job)
        #expect(back.endpoints?.critic?.settings["temperature"] == .double(0.2))
        #expect(back.endpoints?.critic?.settings["seed"] == .int(7))
        #expect(back.endpoints?.critic?.concurrency == 2)
        #expect(back.endpoints?.captioner.baseURL == nil)
        #expect(back.endpoints?.captioner.jsonValue.objectValue?.keys
            == ["kind", "model", "output_mode", "settings", "concurrency"])
    }

    @Test("validation messages match job.py")
    func validation() throws {
        let nora = try Concept(trigger: "NORA7", classNoun: "woman")
        let ivan = try Concept(trigger: "IVAN9", classNoun: "man")
        let draft = try Job(profile: "flux-image", concepts: [])
        #expect(try Job.load(yaml: draft.dump()) == draft)
        #expect(configurationMessage { try Job(concepts: [nora, nora]) } == "concept triggers must be unique")
        #expect(configurationMessage { try Job(concepts: [nora], samples: ["x.png": [:]]) }
            == "sample 'x.png': mapping must name at least one trigger")
        #expect(configurationMessage { try Job(concepts: [nora], samples: ["x.png": ["ZED1": "a", "ABC2": "b"]]) }
            == "sample 'x.png': unknown triggers ['ABC2', 'ZED1']")
        #expect(configurationMessage { try Job(concepts: [nora], samples: ["x.png": ["NORA7": "  "]]) }
            == "sample 'x.png': each trigger needs a locator sentence")
        #expect(configurationMessage {
            try Job(concepts: [nora, ivan], samples: ["pair.png": Fixtures.pairMapping], singleSubjectOnly: true)
        } == "single_subject_only jobs map exactly one trigger per sample")
        #expect(configurationMessage { try Job.load(yaml: "- a\n- b\n") } == "job file must be a YAML mapping")
        #expect(configurationMessage { try Job.load(yaml: "") } == "job file must be a YAML mapping")
        #expect(configurationMessage { try Job.load(yaml: "just text\n") } == "job file must be a YAML mapping")
        let unknownTop = configurationMessage { try Job.load(yaml: "concepts:\n  - trigger: NORA7\nbogus: 1\n") }
        #expect(unknownTop?.contains("extra fields not permitted") == true)
        #expect(unknownTop?.contains("bogus") == true)
        let unknownConcept = configurationMessage {
            try Job.load(yaml: "concepts:\n  - trigger: NORA7\n    nickname: x\n")
        }
        #expect(unknownConcept?.contains("extra fields not permitted") == true)
        let unknownEndpoint = configurationMessage {
            try Job
                .load(
                    yaml: "concepts:\n  - trigger: NORA7\nendpoints:\n  captioner: {kind: openai, model: m, key: s}\n"
                )
        }
        #expect(unknownEndpoint?.contains("extra fields not permitted") == true)
        #expect(configurationMessage { try Job.load(yaml: "profile: h3-still\n") }?.contains("concepts") == true)
        #expect(configurationMessage { try Job.load(yaml: "concepts: [{trigger: NORA7}]\ncaptioner_thinking: turbo\n")
        }?
            .contains("captioner_thinking") == true)
        #expect(configurationMessage { try Job.load(yaml: "concepts: [{trigger: NORA7}]\nsamples: {a.png: [x]}\n") }?
            .contains("a.png") == true)
        #expect(configurationMessage {
            try Job.load(yaml: "concepts: [{trigger: NORA7}]\nsamples: {a.png: {NORA7: 1}}\n")
        }
            == "sample 'a.png': each trigger needs a locator sentence")
        #expect(configurationMessage { try Job.load(yaml: "concepts: [{trigger: NORA7}]\nsamples: {123: null}\n") }?
            .contains("mapping keys must be strings") == true)
        #expect(configurationMessage { try Job.load(yaml: "concepts: [{trigger: NORA7}\n") }?
            .contains("not valid YAML") == true)
    }

    @Test("concept and endpoint field validation")
    func fieldValidation() throws {
        let literal = "trigger/class_noun must be nonblank text without surrounding whitespace"
        #expect(configurationMessage { try Concept(trigger: " NORA7") } == literal)
        #expect(configurationMessage { try Concept(trigger: "") } == literal)
        #expect(configurationMessage { try Concept(trigger: "NORA7", classNoun: "woman\n") } == literal)
        #expect(configurationMessage { try Concept(trigger: "NO\u{1}RA7") }
            == "trigger/class_noun must not contain control characters")
        #expect(configurationMessage { try Concept(trigger: "NORA7", traitsToLearn: ["a", " "]) }
            == "list items must be nonblank strings")
        #expect(configurationMessage { try Concept(trigger: "NORA7", attributesToDescribe: [""]) }
            == "list items must be nonblank strings")
        let endpoint = "endpoint kind/model must be nonblank text without surrounding whitespace"
        #expect(configurationMessage { try EndpointSpec(kind: "", model: "m") } == endpoint)
        #expect(configurationMessage { try EndpointSpec(kind: "openai", model: "m ") } == endpoint)
        #expect(configurationMessage { try EndpointSpec(kind: "openai", model: "m", concurrency: 0) }?
            .contains("concurrency") == true)
        #expect(configurationMessage { try EndpointSpec(kind: "openai", model: "m", concurrency: 65) }?
            .contains("concurrency") == true)
        #expect(try EndpointSpec(kind: "openai", model: "m", concurrency: 64).concurrency == 64)
        let concept = try Concept(trigger: "NORA7")
        #expect(concept.classNoun == "person")
        #expect(concept.targetConcept == .facialIdentity)
        #expect(concept.traitsToLearn == ["distinctive facial identity"])
        #expect(concept.attributesToDescribe == Concept.defaultAttributesToDescribe)
        #expect(concept.explicitBoundaryDecisions.isEmpty)
        #expect(concept.jsonValue.objectValue?.keys == [
            "trigger", "class_noun", "target_concept", "traits_to_learn", "attributes_to_describe",
            "explicit_boundary_decisions",
        ])
    }

    @Test("setMapping validates and keeps explicit nil entries")
    func setMapping() throws {
        var job = try Fixtures.job()
        #expect(configurationMessage { try job.setMapping(["ZED1": "x"], for: "new.png") }
            == "sample 'new.png': unknown triggers ['ZED1']")
        #expect(job.samples.count == 3)
        try job.setMapping(["IVAN9": "The man."], for: "new.png")
        #expect(job.samples.keys == ["solo.png", "pair.png", "unmapped.png", "new.png"])
        #expect(job.mapping(for: "new.png") == ["IVAN9": "The man."])
        try job.setMapping(nil, for: "new.png")
        #expect(job.samples.keys.contains("new.png"))
        #expect(job.unmapped(["new.png", "solo.png"]) == ["new.png"])
        try job.setMapping(["NORA7": "She."], for: "unmapped.png")
        #expect(job.samples.keys == ["solo.png", "pair.png", "unmapped.png", "new.png"])
        #expect(job.unmapped(["unmapped.png"]).isEmpty)
    }

    @Test("sampleView serializes exactly like Python for both fixture mappings")
    func sampleViewParity() throws {
        let job = try Fixtures.job()
        #expect(job.sampleView(mapping: Fixtures.soloMapping).pythonDumps() == soloView)
        #expect(job.sampleView(mapping: Fixtures.pairMapping).pythonDumps() == pairView)
        let reversed: Job.Mapping = ["IVAN9": "The man on the right.", "NORA7": "The woman on the left."]
        let view = job.sampleView(mapping: reversed).pythonDumps()
        #expect(view
            .contains(#""subject_mapping": {"IVAN9": "The man on the right.", "NORA7": "The woman on the left."}"#))
        #expect(view.contains(#""concepts": [{"trigger": "NORA7""#))
    }
}

@Suite("models: json")
struct JSONValueTests {
    @Test("pythonDumps escapes like json.dumps(ensure_ascii=False)")
    func escapes() throws {
        let value: JSONValue = .object(["a": .string("héllo \"q\" \\ \n \t \u{1} 😀")])
        let expected = #"{"a": "héllo \"q\" \\ \n \t \u0001 😀"}"#
        #expect(value.pythonDumps() == expected)
        #expect(try JSONValue(parsing: expected) == value)
        let controls: JSONValue = .object(["c": .string("\u{7f}\u{2028}é"), "b": .string("\u{1f}\u{0}")])
        #expect(controls.pythonDumps() == "{\"c\": \"\u{7f}\u{2028}é\", \"b\": \"\\u001f\\u0000\"}")
        #expect(JSONValue.string("\u{8}\u{c}\r/").pythonDumps() == #""\b\f\r/""#)
    }

    @Test("pythonDumps indent reproduces json.dumps(indent=n)")
    func indentLayout() throws {
        let record: JSONValue = .object([
            "sample_id": .string("x"),
            "captioner": .object(["requested": .string("cap-1"), "served": .null]),
            "critic": .null,
            "notes": .array([.string("a"), .string("b")]),
            "empty": .object([:]),
            "list": .array([]),
            "n": .int(2),
        ])
        let one = "{\n \"sample_id\": \"x\",\n \"captioner\": {\n  \"requested\": \"cap-1\",\n  \"served\": null\n },\n"
            + " \"critic\": null,\n \"notes\": [\n  \"a\",\n  \"b\"\n ],\n \"empty\": {},\n \"list\": [],\n \"n\": 2\n}"
        #expect(record.pythonDumps(indent: 1) == one)
        let two = "{\n  \"sample_id\": \"x\",\n  \"captioner\": {\n    \"requested\": \"cap-1\",\n"
            + "    \"served\": null\n  },\n  \"critic\": null,\n  \"notes\": [\n    \"a\",\n    \"b\"\n  ],\n"
            + "  \"empty\": {},\n  \"list\": [],\n  \"n\": 2\n}"
        #expect(record.pythonDumps(indent: 2) == two)
        let flat = #"{"sample_id": "x", "captioner": {"requested": "cap-1", "served": null}, "critic": null, "#
            + #""notes": ["a", "b"], "empty": {}, "list": [], "n": 2}"#
        #expect(record.pythonDumps() == flat)
        #expect(JSONValue.object([:]).pythonDumps(indent: 1) == "{}")
        #expect(JSONValue.array([]).pythonDumps(indent: 1) == "[]")
        #expect(try JSONValue(parsing: one) == record)
    }

    @Test("floats print like Python repr; ints without exponent")
    func numbers() {
        let doubles: [Double] = [
            1.0, 1e16, 1e-5, 0.0001, 1.2345678901234568e+17, 5e-324, 1.7976931348623157e308, -0.0, 0.1,
            100_000.0, 1e15, 2.5, 1e22, 0.000123,
        ]
        let expected = "[1.0, 1e+16, 1e-05, 0.0001, 1.2345678901234568e+17, 5e-324, 1.7976931348623157e+308, "
            + "-0.0, 0.1, 100000.0, 1000000000000000.0, 2.5, 1e+22, 0.000123]"
        #expect(JSONValue.array(doubles.map(JSONValue.double)).pythonDumps() == expected)
        #expect(JSONValue.array([.int(0), .int(-7), .int(Int.max), .bool(true), .bool(false), .null]).pythonDumps()
            == "[0, -7, 9223372036854775807, true, false, null]")
        #expect(JSONValue.array([.double(.infinity), .double(-.infinity), .double(.nan)]).pythonDumps()
            == "[Infinity, -Infinity, NaN]")
    }

    @Test("parsing keeps key order, replaces duplicates in place, rejects garbage")
    func parsing() throws {
        let parsed = try JSONValue(parsing: #" {"b": 1, "a": [1.0, 1e3, -0, true], "b": {"z": null}, "c": "😀é"} "#)
        let object = try #require(parsed.objectValue)
        #expect(object.keys == ["b", "a", "c"])
        #expect(object["b"] == .object(["z": .null]))
        #expect(object["a"] == .array([.double(1.0), .double(1000), .int(0), .bool(true)]))
        #expect(object["c"] == .string("😀é"))
        #expect(try JSONValue(parsing: "99999999999999999999") == .double(1e20))
        #expect(try JSONValue(parsing: "[]") == .array([]))
        #expect(try JSONValue(parsing: "{}") == .object([:]))
        for bad in [
            "",
            "{",
            "[1,]",
            "{\"a\" 1}",
            "tru",
            "\"unterminated",
            "{\"a\": 1} x",
            "\"ctrl\u{1}\"",
            "01",
            "-",
            "1.",
        ] {
            #expect(throws: ConfigurationError.self, "input \(bad.debugDescription)") { try JSONValue(parsing: bad) }
        }
        let text = "{\"k\": \"v\"}"
        #expect(try JSONValue(parsing: Data(text.utf8)).pythonDumps() == text)
    }

    @Test("Codable bridge and JSONObject semantics")
    func bridgeAndObject() throws {
        let caption = Caption(caption: "x", usable: false, note: "n")
        #expect(try JSONValue(encoding: caption).decode(Caption.self) == caption)
        var object: JSONObject = ["a": .int(1), "b": .int(2)]
        object["a"] = .int(3)
        object["c"] = .int(4)
        #expect(object.keys == ["a", "b", "c"])
        object.removeValue(forKey: "b")
        #expect(object.keys == ["a", "c"])
        #expect(object == ["c": .int(4), "a": .int(3)])
        #expect(JSONValue.object(["a": .int(1), "b": .int(2)]) == JSONValue.object(["b": .int(2), "a": .int(1)]))
        var ordered: OrderedDictionary<String, Int> = ["x": 1, "y": 2, "z": 3]
        ordered.removeValue(forKey: "x")
        ordered["w"] = 0
        ordered["z"] = 9
        #expect(ordered.keys == ["y", "z", "w"])
        #expect(ordered.values == [2, 9, 0])
        #expect(ordered == ["w": 0, "z": 9, "y": 2])
    }

    @Test("Yams bridge resolves scalars and preserves order")
    func yamsBridge() throws {
        let node = try composeYAML("a: yes\nb: 1\nc: 1.5\nd: ~\ne: 'true'\nf: hello\ng: [1, x]\nh: {}\ni: 0x1F\n")
        let value = try JSONValue(yamlNode: node)
        #expect(value == .object([
            "a": .bool(true), "b": .int(1), "c": .double(1.5), "d": .null, "e": .string("true"),
            "f": .string("hello"), "g": .array([.int(1), .string("x")]), "h": .object([:]), "i": .int(31),
        ]))
        #expect(value.objectValue?.keys == ["a", "b", "c", "d", "e", "f", "g", "h", "i"])
        let numericKey = try composeYAML("1: x\n")
        #expect(throws: ConfigurationError.self) { try JSONValue(yamlNode: numericKey) }

        let original: JSONValue = .object([
            "s": .string("true"), "n": .string("123"), "e": .string(""), "t": .string("plain text"),
            "i": .int(-4), "f": .double(1e16), "g": .double(0.25), "b": .bool(false), "z": .null,
            "l": .array([.string("null"), .int(1)]), "m": .object(["k": .string("v")]),
        ])
        let text = try Yams.serialize(node: original.yamlNode())
        #expect(text.contains("f: 1.0e+16"))
        #expect(text.contains("s: 'true'"))
        let back = try JSONValue(yamlNode: composeYAML(text))
        #expect(back == original)
        #expect(back.objectValue?.keys == original.objectValue?.keys)
    }
}

@Suite("models: schemas and records")
struct RecordTests {
    @Test("Caption and Critique default absent fields and dump in model_dump order")
    func schemas() throws {
        let caption = try JSONValue(parsing: #"{"caption": "x"}"#).decode(Caption.self)
        #expect(caption == Caption(caption: "x"))
        #expect(caption.usable == true)
        #expect(caption.note == nil)
        let unusable = try JSONValue(parsing: #"{"caption": "", "usable": false, "note": "face too small"}"#)
            .decode(Caption.self)
        #expect(unusable == Caption(caption: "", usable: false, note: "face too small"))
        #expect(try JSONValue(parsing: #"{"caption": "y", "note": null}"#).decode(Caption.self).note == nil)
        #expect(throws: (any Error).self) { try JSONValue(parsing: #"{"usable": true}"#).decode(Caption.self) }
        #expect(Caption(caption: "c").jsonValue.pythonDumps() == #"{"caption": "c", "usable": true, "note": null}"#)
        #expect(Caption(caption: "", usable: false, note: "n").jsonValue.pythonDumps()
            == #"{"caption": "", "usable": false, "note": "n"}"#)

        let critique = try JSONValue(parsing: #"{"approved": true}"#).decode(Critique.self)
        #expect(critique == Critique(approved: true))
        #expect(critique.notes.isEmpty)
        #expect(try JSONValue(parsing: #"{"approved": false, "notes": null}"#).decode(Critique.self).notes.isEmpty)
        #expect(throws: (any Error).self) { try JSONValue(parsing: #"{"notes": []}"#).decode(Critique.self) }
        #expect(Critique(approved: false, notes: ["a"]).jsonValue
            .pythonDumps() == #"{"approved": false, "notes": ["a"]}"#)

        let encoded = try JSONEncoder().encode(Caption(caption: "x"))
        #expect(try JSONDecoder().decode(Caption.self, from: encoded) == Caption(caption: "x"))
    }

    @Test("JSON Schemas are strict-style")
    func schemaShapes() throws {
        let caption = try #require(Caption.jsonSchema.objectValue)
        #expect(caption["title"] == .string("Caption"))
        #expect(caption["type"] == .string("object"))
        #expect(caption["additionalProperties"] == .bool(false))
        #expect(caption["required"] == .array([.string("caption"), .string("usable"), .string("note")]))
        let properties = try #require(caption["properties"]?.objectValue)
        #expect(properties.keys == ["caption", "usable", "note"])
        #expect(properties["note"]?.objectValue?["type"] == .array([.string("string"), .string("null")]))
        #expect(properties["caption"]?.objectValue?["type"] == .string("string"))
        #expect(properties["usable"]?.objectValue?["description"]?.stringValue?.hasPrefix("False when") == true)
        let critique = try #require(Critique.jsonSchema.objectValue)
        #expect(critique["title"] == .string("Critique"))
        #expect(critique["required"] == .array([.string("approved"), .string("notes")]))
        #expect(critique["additionalProperties"] == .bool(false))
        #expect(critique["properties"]?.objectValue?["notes"]?
            .objectValue?["items"] == .object(["type": .string("string")]))
        #expect(Caption.schemaName == "Caption")
        #expect(Critique.schemaName == "Critique")
    }

    @Test("ResponseRecord encodes keys in the fixed order and matches Python's sidecar text")
    func recordEncoding() throws {
        let record = sampleRecord()
        let object = try #require(record.jsonValue.objectValue)
        #expect(object.keys == [
            "sample_id", "status", "source", "skill", "profile", "captioner", "critic", "attempts", "requests",
            "caption", "critique",
        ])
        let expected = "{\n \"sample_id\": \"solo.png\",\n \"status\": \"written\",\n \"source\": \"model\",\n"
            + " \"skill\": \"diffusion-training-captioner\",\n \"profile\": \"h3-still\",\n \"captioner\": {\n"
            + "  \"requested\": \"cap-1\",\n  \"served\": \"cap-1\"\n },\n \"critic\": {\n"
            + "  \"requested\": \"crit-1\",\n"
            + "  \"served\": \"crit-1\"\n },\n \"attempts\": 1,\n \"requests\": 2,\n \"caption\": {\n"
            + "  \"caption\": \"A photo of NORA7.\",\n  \"usable\": true,\n  \"note\": null\n },\n \"critique\": {\n"
            + "  \"approved\": true,\n  \"notes\": [\n   \"looks right\"\n  ]\n }\n}"
        #expect(record.jsonValue.pythonDumps(indent: 1) == expected)
        #expect(try ResponseRecord(json: JSONValue(parsing: expected)) == record)

        let base = ResponseRecord(
            sampleID: "x", status: .rejected, skill: "s", profile: "p",
            captioner: ModelNames(requested: "cap-1"), critic: nil
        )
        #expect(
            base.jsonValue.pythonDumps() == #"{"sample_id": "x", "status": "rejected", "source": "model", "#
                + #""skill": "s", "profile": "p", "captioner": {"requested": "cap-1", "served": null}, "#
                + #""critic": null, "attempts": 0, "#
                + #""requests": 0, "caption": null, "critique": null}"#
        )
    }

    @Test("ResponseRecord decodes leniently and keeps unknown keys")
    func recordDecoding() throws {
        let human = try ResponseRecord(json: JSONValue(parsing: #"{"sample_id": "x", "source": "human"}"#))
        #expect(human.isHumanFinal)
        #expect(human.sampleID == "x")
        #expect(human.status == .written)
        #expect(human.skill == "")
        #expect(human.profile == "")
        #expect(human.captioner == ModelNames(requested: "", served: nil))
        #expect(human.critic == nil)
        #expect(human.attempts == 0)
        #expect(human.requests == 0)
        #expect(human.caption == nil)
        #expect(human.critique == nil)
        #expect(human.extra.isEmpty)
        #expect(!sampleRecord().isHumanFinal)

        let text = #"{"sample_id": "y", "reviewer": "me", "status": "unusable", "#
            + #""caption": {"caption": "", "usable": false, "#
            + #""note": "n"}, "critic": null, "tags": ["a", {"k": 1}]}"#
        let edited = try ResponseRecord(json: JSONValue(parsing: text))
        #expect(edited.status == .unusable)
        #expect(edited.caption == Caption(caption: "", usable: false, note: "n"))
        #expect(edited.extra.keys == ["reviewer", "tags"])
        let round = try ResponseRecord(json: edited.jsonValue)
        #expect(round == edited)
        #expect(edited.jsonValue.objectValue?.keys.suffix(2) == ["reviewer", "tags"])
        #expect(edited.jsonValue.pythonDumps()
            .hasSuffix(#""critique": null, "reviewer": "me", "tags": ["a", {"k": 1}]}"#))

        #expect(configurationMessage { try ResponseRecord(json: .array([])) } ==
            "response record must be a JSON object")
        #expect(configurationMessage { try ResponseRecord(json: .object(["status": .string("written")])) }
            == "response record has no sample_id")
        let fallback = try ResponseRecord(json: .object(["status": .string("written")]), sampleID: "from-sink.png")
        #expect(fallback.sampleID == "from-sink.png")
        #expect(try ResponseRecord(json: .object(["sample_id": .string("own")]), sampleID: "ignored").sampleID == "own")
        #expect(try ResponseRecord(json: .object(["sample_id": .int(7)]), sampleID: "typed").sampleID == "typed")
    }

    @Test("ResponseRecord takes defaults for unknown or wrong-typed fields instead of throwing")
    func recordDecodingIsLenient() throws {
        // What a user hand-edits: an invented status, a quoted number, a bare caption object.
        let text = #"{"sample_id": "pair.png", "source": "human", "status": "approved", "attempts": "1", "#
            + #""requests": 2.5, "skill": 3, "profile": null, "captioner": "cap-1", "critic": [], "#
            + #""caption": {"caption": "A photo of IVAN9."}, "critique": {"approved": "yes"}}"#
        let edited = try ResponseRecord(json: JSONValue(parsing: text))
        #expect(edited.isHumanFinal)
        #expect(edited.status == .written, "an unknown status reads as the default")
        #expect(edited.attempts == 0 && edited.requests == 0)
        #expect(edited.skill == "" && edited.profile == "")
        #expect(edited.captioner == ModelNames(requested: "", served: nil))
        #expect(edited.critic == nil)
        #expect(edited.caption == Caption(caption: "A photo of IVAN9."), "a bare caption object decodes with defaults")
        #expect(edited.critique == nil)
        #expect(edited.extra.isEmpty, "fixed keys never leak into extra, whatever their type")

        let typed = try ResponseRecord(json: JSONValue(parsing: #"{"sample_id": "x", "source": 1, "caption": "text"}"#))
        #expect(typed.source == "model" && !typed.isHumanFinal)
        #expect(typed.caption == nil)
        #expect(try ResponseRecord(json: JSONValue(parsing: #"{"sample_id": "x", "status": 4}"#)).status == .written)
    }

    @Test("RunSummary.report matches cli.py's _summary.json")
    func summaryReport() throws {
        let summary = RunSummary(
            outcomes: [
                Outcome(
                    sampleID: "pair.png",
                    status: .written,
                    caption: "c",
                    notes: ["looks right"],
                    record: sampleRecord()
                ),
                Outcome(sampleID: "unmapped.png", status: .needsMapping, notes: ["no subject mapping"]),
                Outcome(sampleID: "solo.png", status: .written),
            ],
            elapsed: 12.3456,
            sink: ["directory": .string("/tmp/out")]
        )
        #expect(summary.counts() == [.written: 2, .needsMapping: 1])
        let report = try #require(summary.report.objectValue)
        #expect(report.keys == ["counts", "elapsed_s", "sink", "samples"])
        #expect(report["counts"] == .object(["written": .int(2), "needs_mapping": .int(1)]))
        #expect(report["counts"]?.objectValue?.keys == ["written", "needs_mapping"])
        #expect(report["elapsed_s"] == .double(12.3))
        #expect(report["sink"] == .object(["directory": .string("/tmp/out")]))
        #expect(report["samples"]?.arrayValue?.count == 3)
        #expect(report["samples"]?.arrayValue?[1] == .object([
            "id": .string("unmapped.png"), "status": .string("needs_mapping"),
            "notes": .array([.string("no subject mapping")]),
        ]))
        #expect(summary.report.pythonDumps(indent: 1).contains("\"needs_mapping\": [\n") == false)
        #expect(RunSummary(outcomes: [], elapsed: 0).report.pythonDumps()
            == #"{"counts": {}, "elapsed_s": 0.0, "sink": {}, "samples": []}"#)
    }

    @Test("ConceptCore exposes its version")
    func moduleFacts() {
        #expect(ConceptCore.version == "0.2.0")
    }
}
