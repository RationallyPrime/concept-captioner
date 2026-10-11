// Structured responses from the captioner and the optional critic. Python counterpart: schemas.py.

import Foundation

/// What the captioner returns. `caption` is the training text and nothing else.
public struct Caption: Codable, Sendable, Equatable {
    public static let schemaName = "Caption"

    public var caption: String
    public var usable: Bool
    public var note: String?

    public init(caption: String, usable: Bool = true, note: String? = nil) {
        self.caption = caption
        self.usable = usable
        self.note = note
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case caption, usable, note
    }

    /// Lenient on absence: `usable` defaults true, `note` nil when absent or null. Strict on
    /// shape: an unknown key is a decode failure, as pydantic `extra="forbid"` makes it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caption = try container.decode(String.self, forKey: .caption)
        usable = try container.decodeIfPresent(Bool.self, forKey: .usable) ?? true
        note = try container.decodeIfPresent(String.self, forKey: .note)
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
    }

    /// {"caption", "usable", "note"} in that order (model_dump).
    public var jsonValue: JSONValue {
        .object([
            "caption": .string(caption),
            "usable": .bool(usable),
            "note": note.map(JSONValue.string) ?? .null,
        ])
    }

    /// Strict-style JSON Schema accepted by every provider (see docs/CORE-SPEC.md).
    public static let jsonSchema: JSONValue = .object([
        "type": .string("object"),
        "title": .string(schemaName),
        "properties": .object([
            "caption": .object([
                "type": .string("string"),
                "description": .string("The training caption in the selected profile's format."),
            ]),
            "usable": .object([
                "type": .string("boolean"),
                "description": .string(
                    "False when the declared training target cannot be found in the sample. "
                        + "Then leave the caption empty and explain in note."
                ),
            ]),
            "note": .object([
                "type": .array([.string("string"), .string("null")]),
                "description": .string("Why the sample is not usable."),
            ]),
        ]),
        "required": .array([.string("caption"), .string("usable"), .string("note")]),
        "additionalProperties": .bool(false),
    ])
}

/// What the critic returns.
public struct Critique: Codable, Sendable, Equatable {
    public static let schemaName = "Critique"

    public var approved: Bool
    public var notes: [String]

    public init(approved: Bool, notes: [String] = []) {
        self.approved = approved
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case approved, notes
    }

    /// Lenient on absence: `notes` defaults to [] when absent or null. Strict on shape: an
    /// unknown key is a decode failure, as pydantic `extra="forbid"` makes it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approved = try container.decode(Bool.self, forKey: .approved)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
    }

    public var jsonValue: JSONValue {
        .object([
            "approved": .bool(approved),
            "notes": .array(notes.map(JSONValue.string)),
        ])
    }

    public static let jsonSchema: JSONValue = .object([
        "type": .string("object"),
        "title": .string(schemaName),
        "properties": .object([
            "approved": .object(["type": .string("boolean")]),
            "notes": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "What the captioner must change, when not approved. Specific and short."
                ),
            ]),
        ]),
        "required": .array([.string("approved"), .string("notes")]),
        "additionalProperties": .bool(false),
    ])
}

// MARK: - extra="forbid"

/// Any JSON object key, for listing what a reply actually contained.
private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? {
        nil
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

/// Throws when the object being decoded holds a key outside `allowed`, as pydantic
/// `extra="forbid"` does ("Extra inputs are not permitted", located at that key). The
/// Python models reject such a reply, so the Swift side must not accept it either; otherwise
/// the same model answer would end `written` here and `failed` there. `JSONDecoder` surfaces
/// one failure at a time, so the unknown keys are reported smallest first for determinism.
private func rejectUnknownKeys(in decoder: any Decoder, allowed: some Sequence<some CodingKey>) throws {
    let known = Set(allowed.map(\.stringValue))
    let present = try decoder.container(keyedBy: AnyKey.self).allKeys
    guard let extra = present.map(\.stringValue).filter({ !known.contains($0) }).min() else { return }
    throw DecodingError.dataCorrupted(DecodingError.Context(
        codingPath: decoder.codingPath + [AnyKey(stringValue: extra)],
        debugDescription: "Extra inputs are not permitted"
    ))
}
