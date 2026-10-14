import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

struct AdvancedModelSelectionTests {
    @Test func recipeVisibilityUsesRowStatus() throws {
        var table = try #require(JSONSerialization.jsonObject(with: ModelTable.bundledData()) as? [String: Any])
        var rows = try #require(table["models"] as? [[String: Any]])
        let index = try #require(rows.firstIndex { $0["recipe_status"] as? String == "verified" })
        let changedID = try #require(rows[index]["id"] as? String)
        rows[index]["recipe_status"] = "unverified"
        table["models"] = rows
        let changed = try ModelTable(parsing: JSONSerialization.data(withJSONObject: table))
        #expect(!changed.selectableRows(advancedUser: false).contains { $0.id == changedID })
        #expect(changed.selectableRows(advancedUser: true).contains { $0.id == changedID })
        #expect(changed.row(id: changedID) != nil)
    }
}
