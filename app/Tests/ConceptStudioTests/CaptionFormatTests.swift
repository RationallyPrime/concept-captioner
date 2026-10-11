import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("caption format selection")
@MainActor
struct CaptionFormatTests {
    @Test func demoFormatStaysPreparedAndRealProjectFormatPersists() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        session.demoMode = true
        let selection = CaptioningView(session: session).captionFormatSelection
        #expect(selection.wrappedValue == "flux-image")
        selection.wrappedValue = "ltx-video"
        #expect(selection.wrappedValue == "flux-image")
        #expect(try Job.load(contentsOf: project.jobURL).profile == "flux-image")

        session.demoMode = false
        selection.wrappedValue = "ltx-video"
        #expect(session.project?.job.profile == "ltx-video")
        #expect(try Job.load(contentsOf: project.jobURL).profile == "ltx-video")
        #expect(session.errorMessage == nil)
    }
}
