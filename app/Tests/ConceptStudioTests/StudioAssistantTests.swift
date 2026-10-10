import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("assistant output contracts")
struct StudioAssistantTests {
    @Test func draftSchemasAreFiniteStrictObjects() {
        checkStrictObjects(BoundaryDraft.schema)
        checkStrictObjects(MappingDraft.schema)
    }

    @Test func finiteDraftsDecodeAndMappingCannotInventTriggers() throws {
        let boundary = try JSONValue(parsing:
            #"""
            {"learn":["facial identity"],"describe":["clothing"],
             "decisions":[{"detail":"jacket","decision":"Describe it"}]}
            """#
        ).decode(BoundaryDraft.self)
        #expect(boundary.decisions.first?.detail == "jacket")
        #expect(boundary.decisions.first?.decision == "Describe it")
        let draft = try JSONValue(parsing:
            #"""
            {"locators":[{"trigger":"NORA7","locator":"left person"},
                         {"trigger":"UNMAPPED","locator":"right person"}]}
            """#
        ).decode(MappingDraft.self)
        #expect(draft.mapping(allowed: ["NORA7"]) == ["NORA7": "left person"])
    }

    private func checkStrictObjects(_ value: JSONValue) {
        if let object = value.objectValue {
            if object["type"]?.stringValue == "object" {
                #expect(object["additionalProperties"] == .bool(false))
                let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                #expect(required == Set(object["properties"]?.objectValue?.keys ?? []))
            }
            for (_, child) in object.pairs {
                checkStrictObjects(child)
            }
        } else if let array = value.arrayValue {
            for child in array {
                checkStrictObjects(child)
            }
        }
    }
}
