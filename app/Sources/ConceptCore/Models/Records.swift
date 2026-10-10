// The response record, per-sample outcomes and the run summary. Python counterpart: the record
// dict built by runner.py::_base_record, Outcome and RunSummary.

import Foundation

public enum SampleStatus: String, Codable, Sendable, CaseIterable {
    case written
    case skipped
    case needsMapping = "needs_mapping"
    case unusable
    case rejected
    case failed
}

public struct ModelNames: Sendable, Equatable {
    public var requested: String
    public var served: String?

    public init(requested: String, served: String? = nil) {
        self.requested = requested
        self.served = served
    }

    /// `{"requested": ..., "served": null | ...}`; a missing `requested` reads as "".
    public init(json: JSONValue) throws {
        guard let object = json.objectValue else { throw ConfigurationError("model names must be a JSON object") }
        requested = object["requested"]?.stringValue ?? ""
        served = object["served"]?.stringValue
    }

    public var jsonValue: JSONValue {
        .object(["requested": .string(requested), "served": served.map(JSONValue.string) ?? .null])
    }
}

/// One JSON object per captioned image. Key order on output is fixed; decoding is lenient so a
/// hand-edited record still loads, and unknown keys survive in `extra`.
public struct ResponseRecord: Sendable, Equatable {
    static let fixedKeys = [
        "sample_id", "status", "source", "skill", "profile", "captioner", "critic", "attempts", "requests",
        "caption", "critique",
    ]

    public var sampleID: String
    public var status: SampleStatus
    public var source: String
    public var skill: String
    public var profile: String
    public var captioner: ModelNames
    public var critic: ModelNames?
    public var attempts: Int
    public var requests: Int
    public var caption: Caption?
    public var critique: Critique?
    public var extra: JSONObject

    public var isHumanFinal: Bool {
        source == "human"
    }

    public init(
        sampleID: String,
        status: SampleStatus,
        source: String = "model",
        skill: String,
        profile: String,
        captioner: ModelNames,
        critic: ModelNames?,
        attempts: Int = 0,
        requests: Int = 0,
        caption: Caption? = nil,
        critique: Critique? = nil,
        extra: JSONObject = [:]
    ) {
        self.sampleID = sampleID
        self.status = status
        self.source = source
        self.skill = skill
        self.profile = profile
        self.captioner = captioner
        self.critic = critic
        self.attempts = attempts
        self.requests = requests
        self.caption = caption
        self.critique = critique
        self.extra = extra
    }

    /// Lenient, like Python's `json.loads` followed by `.get(...)` on the dict: only a non-object
    /// is a ConfigurationError. `sample_id` falls back to `sampleID` (the id the sink was asked
    /// for) and is an error only when neither is a string. Every other missing, null or
    /// wrong-typed field takes its default; an unknown `status` reads as `written`; a `caption`
    /// or `critique` that is not a well-formed object reads as nil. Keys outside the fixed set
    /// survive in `extra`. A hand-edited human-final record therefore always loads, so the runner
    /// never re-captions over it.
    public init(json: JSONValue, sampleID fallback: String? = nil) throws {
        guard let object = json.objectValue else { throw ConfigurationError("response record must be a JSON object") }
        guard let sampleID = object["sample_id"]?.stringValue ?? fallback else {
            throw ConfigurationError("response record has no sample_id")
        }
        self.sampleID = sampleID
        status = object["status"]?.stringValue.flatMap(SampleStatus.init(rawValue:)) ?? .written
        source = object["source"]?.stringValue ?? "model"
        skill = object["skill"]?.stringValue ?? ""
        profile = object["profile"]?.stringValue ?? ""
        captioner = object["captioner"].flatMap { try? ModelNames(json: $0) } ?? ModelNames(requested: "", served: nil)
        critic = object["critic"].flatMap { try? ModelNames(json: $0) }
        attempts = object["attempts"]?.intValue ?? 0
        requests = object["requests"]?.intValue ?? 0
        caption = object["caption"].flatMap { try? $0.decode(Caption.self) }
        critique = object["critique"].flatMap { try? $0.decode(Critique.self) }
        extra = JSONObject(object.pairs.filter { !ResponseRecord.fixedKeys.contains($0.key) }
            .map { ($0.key, $0.value) })
    }

    /// Fixed key order first, then `extra` in its stored order.
    public var jsonValue: JSONValue {
        var object: JSONObject = [
            "sample_id": .string(sampleID),
            "status": .string(status.rawValue),
            "source": .string(source),
            "skill": .string(skill),
            "profile": .string(profile),
            "captioner": captioner.jsonValue,
            "critic": critic?.jsonValue ?? .null,
            "attempts": .int(attempts),
            "requests": .int(requests),
            "caption": caption?.jsonValue ?? .null,
            "critique": critique?.jsonValue ?? .null,
        ]
        for pair in extra.pairs where !ResponseRecord.fixedKeys.contains(pair.key) {
            object[pair.key] = pair.value
        }
        return .object(object)
    }
}

public struct Outcome: Sendable, Equatable {
    public let sampleID: String
    public let status: SampleStatus
    public let caption: String?
    public let notes: [String]
    public let record: ResponseRecord?

    public init(
        sampleID: String,
        status: SampleStatus,
        caption: String? = nil,
        notes: [String] = [],
        record: ResponseRecord? = nil
    ) {
        self.sampleID = sampleID
        self.status = status
        self.caption = caption
        self.notes = notes
        self.record = record
    }
}

public struct RunSummary: Sendable {
    public let outcomes: [Outcome]
    public let elapsed: TimeInterval
    public let sink: JSONObject

    public init(outcomes: [Outcome], elapsed: TimeInterval, sink: JSONObject = [:]) {
        self.outcomes = outcomes
        self.elapsed = elapsed
        self.sink = sink
    }

    public func counts() -> [SampleStatus: Int] {
        var counts: [SampleStatus: Int] = [:]
        for outcome in outcomes {
            counts[outcome.status, default: 0] += 1
        }
        return counts
    }

    /// {"counts", "elapsed_s", "sink", "samples": [{"id", "status", "notes"}]} as cli.py writes it.
    /// Counts are keyed in first-seen order, like the Python dict; `elapsed_s` is rounded to one decimal.
    public var report: JSONValue {
        var counts = JSONObject()
        for outcome in outcomes {
            counts[outcome.status.rawValue] = .int((counts[outcome.status.rawValue]?.intValue ?? 0) + 1)
        }
        let samples = outcomes.map { outcome in
            JSONValue.object([
                "id": .string(outcome.sampleID),
                "status": .string(outcome.status.rawValue),
                "notes": .array(outcome.notes.map(JSONValue.string)),
            ])
        }
        return .object([
            "counts": .object(counts),
            "elapsed_s": .double((elapsed * 10).rounded(.toNearestOrEven) / 10),
            "sink": .object(sink),
            "samples": .array(samples),
        ])
    }
}
