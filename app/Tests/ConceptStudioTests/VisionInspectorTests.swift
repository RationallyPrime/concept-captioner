import AppKit
@testable import ConceptStudio
import Foundation
import Testing

@Suite("on-device image suggestions")
struct VisionInspectorTests {
    @Test func pixelEquivalentReencodingIsSimilarButDistinctIllustrationsAreNot() async throws {
        let project = try await DemoProject.create()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let original = try #require(project.images.first?.url)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: original)))
        let reencoded = try #require(bitmap.representation(using: .png, properties: [:]))
        let copy = project.imagesDirectory.appendingPathComponent("same-pixels.png")
        let originalBytes = try Data(contentsOf: original)
        #expect(reencoded != originalBytes)
        try reencoded.write(to: copy)
        let inspector = VisionInspector()
        let analyses = try await inspector.analyze(project.images.map(\.url) + [copy])
        for image in project.images {
            #expect(analyses[image.id]?.warnings.contains { $0.contains("Visually similar") } == false)
        }
        #expect(analyses["same-pixels.png"]?.warnings.contains {
            $0.contains("Visually similar")
        } == true)
    }

    @Test func faceProposalRequiresCloseUnambiguousReference() {
        #expect(VisionInspector.faceCandidate([("A", 0.24), ("B", 0.31)]) == nil)
        #expect(VisionInspector.faceCandidate([("A", 0.04), ("B", 0.06)]) == nil)
        #expect(VisionInspector.faceCandidate([("A", 0.02), ("B", 0.15)]) == "A")
        #expect(VisionInspector.faceCandidate([("A", .nan)]) == nil)
    }
}
