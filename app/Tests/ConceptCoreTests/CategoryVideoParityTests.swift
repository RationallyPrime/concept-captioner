@testable import ConceptCore
import Foundation
import Testing

@Suite("Seven category and video cross-language prompt parity")
struct CategoryVideoParityTests {
    @Test func sharedPythonSwiftReferenceCoversAllCategoriesAndBothMediaKinds() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/category-video-parity.json")
        let reference = try JSONValue(parsing: Data(contentsOf: path))
        #expect(reference.field("user_turn") == .string(Prompt.userTurn))
        #expect(reference.field("critic_user_turn") == .string(Prompt.criticUserTurn(caption: "sample caption")))
        let cases = try #require(reference.field("cases")?.arrayValue)
        let skill = try Skills.load()
        var covered: Set<String> = []
        for item in cases {
            let category = try #require(item.field("category")?.stringValue)
            let target = try #require(TargetConcept(rawValue: category))
            let isVideo = try #require(item.field("video")?.boolValue as Bool?)
            covered.insert("\(category)-\(isVideo)")
            let concept = try Concept(trigger: "NORA7", targetConcept: target)
            #expect(concept.jsonValue == item.field("concept"))
            let job = try Job(profile: "plain", concepts: [concept])
            let mapping: Job.Mapping = ["NORA7": "The mapped target."]
            let caption = try Prompt.captionerInstructions(
                skill: skill, profileText: skill.profile("plain"), job: job, mapping: mapping, isVideo: isVideo
            )
            let critique = try Prompt.criticInstructions(
                skill: skill, profileText: skill.profile("plain"), job: job, mapping: mapping, isVideo: isVideo
            )
            for (role, text) in [("captioner", caption), ("critic", critique)] {
                #expect(item.field(role)?.field("sha256") == .string(PromptTests.sha256Hex(text)))
                #expect(item.field(role)?.field("scalars") == .int(text.unicodeScalars.count))
            }
        }
        #expect(covered == Set(TargetConcept.allCases.flatMap { category in
            ["\(category.rawValue)-false", "\(category.rawValue)-true"]
        }))
    }
}
