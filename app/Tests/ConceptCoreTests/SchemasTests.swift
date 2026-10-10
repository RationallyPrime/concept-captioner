// Caption / Critique decoding follows pydantic `extra="forbid"` (schemas.py).
// See docs/CORE-SPEC.md, module `models`.

import ConceptCore
import Foundation
import Testing

@Suite("models: schema strictness")
struct SchemaStrictnessTests {
    /// pydantic's `extra="forbid"`: a key the schema does not name is a validation error in
    /// Python, so it must be a decode failure here too (same reply, same sample status).
    @Test("Caption and Critique reject unknown keys like pydantic extra=forbid")
    func schemasForbidExtraKeys() throws {
        for text in [
            #"{"caption": "NORA7 here", "usable": true, "note": null, "confidence": 0.9}"#,
            #"{"caption": "x", "why": 1}"#,
            #"{"usable": true, "zzz": 1}"#, // missing `caption` is reported first, still a failure
        ] {
            #expect(throws: DecodingError.self, "\(text)") { try JSONValue(parsing: text).decode(Caption.self) }
        }
        for text in [#"{"approved": true, "notes": [], "score": 3}"#, #"{"approved": false, "reasons": ["a"]}"#] {
            #expect(throws: DecodingError.self, "\(text)") { try JSONValue(parsing: text).decode(Critique.self) }
        }
        // The failure sits at the offending key (smallest first), worded as pydantic words it.
        do {
            _ = try JSONDecoder().decode(Critique.self, from: Data(#"{"approved": true, "b": 1, "a": 2}"#.utf8))
            Issue.record("expected a DecodingError for unknown keys")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["a"])
            #expect(context.debugDescription == "Extra inputs are not permitted")
        }
    }
}
