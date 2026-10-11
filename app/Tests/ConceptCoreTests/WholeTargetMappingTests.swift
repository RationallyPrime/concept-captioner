import ConceptCore
import Testing

@Suite("whole-target mapping")
struct WholeTargetMappingTests {
    @Test(arguments: TargetConcept.allCases)
    func categoryDeterminesWhetherLocatorConfirmationIsNeeded(_ category: TargetConcept) throws {
        let job = try Job(concepts: [Concept(trigger: "TARGET8", targetConcept: category)])
        let wholeTarget = category == .style || category == .motion
        #expect(category.requiresLocator == !wholeTarget)
        #expect(job.requiresLocatorMapping == !wholeTarget)
        #expect((job.mappingIncludingWholeTargets(nil) != nil) == wholeTarget)
    }

    @Test func mixedAssignmentsRemainUnconfirmedUntilExplicitConfirmation() throws {
        let job = try Job(concepts: [
            Concept(trigger: "STYLE8", targetConcept: .style), Concept(trigger: "PERSON8"),
            Concept(trigger: "MOVE8", targetConcept: .motion),
        ])
        #expect(job.mappingIncludingWholeTargets(nil) == nil)
        let confirmed = try #require(job.mappingIncludingWholeTargets(["PERSON8": "the person on the left"]))
        #expect(confirmed["PERSON8"] == "the person on the left")
        #expect(confirmed["STYLE8"] == "the visual style of the entire image or clip")
        #expect(confirmed["MOVE8"] == "the defining movement throughout the entire image or clip")
        let absentPerson = job.mappingIncludingWholeTargets([:])
        #expect(absentPerson == job.wholeTargetMapping)
    }

    @Test func automaticAssignmentsRemainOrdinarySharedJobMappings() throws {
        var job = try Job(concepts: [
            Concept(trigger: "STYLE8", targetConcept: .style), Concept(trigger: "MOVE8", targetConcept: .motion),
        ])
        try job.setMapping(job.mappingIncludingWholeTargets(nil), for: "target.mp4")
        let reopened = try Job.load(yaml: job.dump())
        #expect(reopened == job)
        #expect(reopened.mapping(for: "target.mp4")?.keys == ["STYLE8", "MOVE8"])
        #expect(reopened.unmapped(["target.mp4"]).isEmpty)
    }
}
