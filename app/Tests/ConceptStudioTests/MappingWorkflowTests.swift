import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("mapping workflow")
@MainActor
struct MappingWorkflowTests {
    @Test(arguments: [TargetConcept.style, .motion])
    func approvingWholeTargetConceptKeepsAutomaticAssignment(_ category: TargetConcept) async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "TARGET8", targetConcept: category)])
        let image = try #require(project.images.first)
        try project.approveTarget(
            id: image.id, data: Data(contentsOf: image.url), name: image.id,
            selection: MediaSelection(originalName: image.id)
        )
        let expected = project.job.wholeTargetMapping
        #expect(project.job.mapping(for: image.id) == expected)
        #expect(try Job.load(contentsOf: project.jobURL).mapping(for: image.id) == expected)
        #expect(project.job.unmapped([image.id]).isEmpty)
        try project.undoCuration()
        #expect(project.job.mapping(for: image.id) == expected)
    }

    @Test func approvedMixedTargetNeedsFreshLocatorConfirmation() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try mixedJob()
        let image = try #require(project.images.first)
        try project.job.setMapping(
            project.job.mappingIncludingWholeTargets(["PERSON8": "the person on the left"]), for: image.id
        )
        try project.approveTarget(
            id: image.id, data: Data(contentsOf: image.url), name: image.id,
            selection: MediaSelection(originalName: image.id)
        )
        #expect(project.job.mapping(for: image.id) == nil)
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        session.confirmMapping(id: image.id, mapping: ["PERSON8": "the person in the new crop"])
        let stored = try Job.load(contentsOf: project.jobURL)
        #expect(stored.mapping(for: image.id)?["PERSON8"] == "the person in the new crop")
        #expect(stored.mapping(for: image.id)?["STYLE8"] == project.job.wholeTargetMapping["STYLE8"])
        #expect(stored.mapping(for: image.id)?["MOVE8"] == project.job.wholeTargetMapping["MOVE8"])
    }

    @Test func importAndReincludeAssignAllWholeTargetConcepts() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [
            Concept(trigger: "STYLE8", targetConcept: .style), Concept(trigger: "MOVE8", targetConcept: .motion),
        ])
        let image = try #require(project.images.first)
        let name = try project.importData(Data(contentsOf: image.url), name: "added.png")
        #expect(project.job.mapping(for: name) == project.job.wholeTargetMapping)
        try project.setIncluded(image.id, false)
        try project.job.setMapping(nil, for: image.id)
        try project.setIncluded(image.id, true)
        #expect(project.job.mapping(for: image.id) == project.job.wholeTargetMapping)
        #expect(try Job.load(contentsOf: project.jobURL).mapping(for: image.id) == project.job.wholeTargetMapping)
    }

    @Test(arguments: TargetConcept.allCases)
    func navigationUsesTheConceptLocatorPolicy(_ category: TargetConcept) async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "TARGET8", targetConcept: category)])
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        #expect(session.journeySteps.contains(.mapping) == category.requiresLocator)
        session.step = .concepts
        session.next()
        #expect(session.step == (category.requiresLocator ? .mapping : .captioning))
        session.goBack()
        #expect(session.step == .concepts)
        session.step = .captioning
        session.goBack()
        #expect(session.step == (category.requiresLocator ? .mapping : .concepts))
    }

    @Test func addingOrChangingALocatorConceptInvalidatesAutomaticOnlyAssignments() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        try session.saveConcept(Concept(trigger: "STYLE8", targetConcept: .style), replacing: "NORA7")
        session.step = .mapping
        try session.saveConcept(Concept(trigger: "MOVE8", targetConcept: .motion), replacing: nil)
        #expect(session.step == .captioning)
        #expect(session.unmappedCount == 0)
        try session.saveConcept(Concept(trigger: "OBJECT8", targetConcept: .object), replacing: "STYLE8")
        #expect(session.unmappedCount == project.images.count)
        #expect(session.journeySteps.contains(.mapping))
        let id = try #require(session.project?.images.first?.id)
        session.confirmMapping(id: id, mapping: ["OBJECT8": "the mug in the foreground"])
        #expect(session.project?.job.mapping(for: id)?["MOVE8"] != nil)
        try session.saveConcept(Concept(trigger: "PERSON8"), replacing: nil)
        #expect(session.unmappedCount == project.images.count)
        project = try #require(session.project)
        #expect(try Job.load(contentsOf: project.jobURL) == project.job)
    }

    @Test func confirmingConceptsSavesAndMovesToTheApplicableNextStep() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        try session.saveConcept(Concept(trigger: "STYLE8", targetConcept: .style), replacing: "NORA7")
        session.step = .concepts
        session.confirmConcepts()
        #expect(session.errorMessage == nil)
        #expect(session.step == .captioning)
        #expect(try Job.load(contentsOf: project.jobURL) == session.project?.job)
        try FileManager.default.removeItem(at: project.jobURL)
        try FileManager.default.createDirectory(at: project.jobURL, withIntermediateDirectories: false)
        session.step = .concepts
        session.confirmConcepts()
        #expect(session.errorMessage != nil)
        #expect(session.step == .concepts)
    }

    @Test func fileBackedApprovalUsesTheSameMappingAndUndoPath() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "STYLE8", targetConcept: .style)])
        let image = try #require(project.images.first)
        let source = project.directory.appendingPathComponent("source.png")
        try FileManager.default.copyItem(at: image.url, to: source)
        let bytes = try Data(contentsOf: source)
        try project.approveTarget(
            id: image.id, sourceFile: source, name: image.id, selection: MediaSelection(originalName: image.id)
        )
        #expect(try Data(contentsOf: image.url) == bytes)
        #expect(project.job.mapping(for: image.id) == project.job.wholeTargetMapping)
        try project.undoCuration()
        #expect(try Data(contentsOf: image.url) == bytes)
    }

    private func mixedJob() throws -> Job {
        try Job(concepts: [
            Concept(trigger: "STYLE8", targetConcept: .style), Concept(trigger: "PERSON8"),
            Concept(trigger: "MOVE8", targetConcept: .motion),
        ])
    }
}
