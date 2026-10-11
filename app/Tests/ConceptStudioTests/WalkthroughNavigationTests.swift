import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("walkthrough navigation")
@MainActor
struct WalkthroughNavigationTests {
    @Test func finishedMessagesStayOnTheirProducingStep() {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.message = "Dataset advice ready."
        session.goForward()
        #expect(session.step == .concepts)
        #expect(session.message.isEmpty)
        session.message = "Concept saved."
        session.step = .publish
        #expect(session.message.isEmpty)
        session.message = "Dataset prepared."
        session.goBack()
        #expect(session.message.isEmpty)
        session.gpu.message = "Your computer is running."
        session.step = .monitor
        #expect(session.gpu.message == "Your computer is running.")
    }

    @Test func activeProgressSurvivesNavigationButItsLateCompletionDoesNot() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        var release: CheckedContinuation<Void, Never>?
        session.perform("Requesting dataset advice…") {
            await withCheckedContinuation { release = $0 }
            session.message = "Dataset advice ready."
        }
        #expect(await eventually { release != nil })
        let task = try #require(session.task)
        session.step = .concepts
        #expect(session.busy)
        #expect(session.message == "Requesting dataset advice…")
        release?.resume()
        await task.value
        #expect(!session.busy)
        #expect(session.message.isEmpty)
        session.goBack()
        #expect(session.message.isEmpty)
    }

    @Test func duplicateRecentNamesHaveDistinctMenuLabels() {
        let paths = ["/projects/first/Family", "/projects/second/Family", "/projects/Portrait"]
        #expect(RecentProjects.parentLabel(paths[0]) == "/projects/first")
        #expect(RecentProjects.menuLabel(paths[0], among: paths) == "Family — /projects/first")
        #expect(RecentProjects.menuLabel(paths[1], among: paths) == "Family — /projects/second")
        #expect(RecentProjects.menuLabel(paths[2], among: paths) == "Portrait")
    }

    @Test func settlingOneGateKeepsTheOtherOperationVisible() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        var releaseRun: CheckedContinuation<Void, Never>?
        var releaseEdit: CheckedContinuation<Void, Never>?
        session.perform("Writing captions…") {
            await withCheckedContinuation { releaseRun = $0 }
        }
        session.perform("Saving caption…", gate: .edit) {
            await withCheckedContinuation { releaseEdit = $0 }
            session.message = "Caption saved."
        }
        #expect(await eventually { releaseRun != nil && releaseEdit != nil })
        let run = try #require(session.task)
        let edit = try #require(session.editTask)
        session.step = .monitor
        releaseEdit?.resume()
        await edit.value
        #expect(session.busy)
        #expect(!session.editing)
        #expect(session.message == "Writing captions…")
        releaseRun?.resume()
        await run.value
        #expect(session.message.isEmpty)
    }
}
