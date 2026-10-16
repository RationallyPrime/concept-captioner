import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("studio project")
struct StudioProjectTests {
    @Test func journeyHasNineScreens() {
        #expect(StudioStep.allCases.count == 9)
        #expect(StudioStep.allCases.first == .images)
        #expect(StudioStep.allCases.last == .monitor)
    }

    @Test func demoUsesSharedJobAndSidecars() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        #expect(project.images.count == DemoProject.preparedCaptions.count)
        #expect(try Job.load(contentsOf: project.jobURL) == project.job)
        let source = try LocalFolderSource(directory: project.imagesDirectory)
        let sink = try SidecarSink(directory: project.imagesDirectory)
        let endpoint = ResolvedEndpoint(client: DemoModelClient())
        let first = try await Runner(job: project.job, captioner: endpoint).run(source: source, sink: sink)
        #expect(first.outcomes.allSatisfy { $0.status == .written })
        try await project.saveCaption(id: project.images[0].id, text: "NORA7 finished by a person.", final: true)
        let finalBytes = try Data(contentsOf: sink.recordURL(for: project.images[0].id))
        let second = try await Runner(job: project.job, captioner: endpoint, overwrite: true).run(
            source: source,
            sink: sink
        )
        #expect(second.outcomes.first { $0.sampleID == project.images[0].id }?.status == .skipped)
        #expect(try Data(contentsOf: sink.recordURL(for: project.images[0].id)) == finalBytes)
        let reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.images.first?.isFinal == true)
        #expect(reopened.images.first?.caption == "NORA7 finished by a person.")
        let operations = try await ProjectPublisher.operations(for: reopened)
        let paths = operations.map(\.path)
        #expect(paths.contains("concept-captioner/job.yaml"))
        #expect(paths.contains("metadata.jsonl"))
        #expect(paths.contains("garden.jpg"))
        #expect(paths.contains("garden.txt"))
        #expect(paths.contains("garden.json"))
    }

    @Test func newProjectStartsWithNoDemoConcept() throws {
        let directory = temporaryTestDirectory("empty-project")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try StudioProject.create(at: directory)
        #expect(project.job.concepts.isEmpty)
        #expect(project.job.profile == "flux-image")
        #expect(project.images.isEmpty)
        #expect(try Job.load(contentsOf: project.jobURL) == project.job)
        let yaml = try String(contentsOf: project.jobURL, encoding: .utf8)
        #expect(yaml.contains("concepts: []"))
        #expect(!yaml.contains("NORA7"))
    }

    @Test func importsCaptionSidecarsCaseInsensitivelyAndPreservesFinalRecords() async throws {
        let source = temporaryTestDirectory("caption-sidecars")
        let directory = temporaryTestDirectory("caption-import-project")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let encoded = try MediaFixtures.encoded(MediaFixtures.image(), type: .heic)
        let heic = source.appendingPathComponent("Portrait.HEIC")
        try encoded.write(to: heic)
        let image = source.appendingPathComponent("Second.png")
        try MediaEditor.png(MediaFixtures.image()).write(to: image)
        let sourceSink = try SidecarSink(directory: source)
        try await sourceSink.write("portrait.jpeg", caption: "NORA7 checked by a person.", record: ResponseRecord(
            sampleID: "portrait.jpeg", status: .written, source: "human", skill: "custom", profile: "plain",
            captioner: ModelNames(requested: "human"), critic: nil,
            caption: Caption(caption: "NORA7 checked by a person.")
        ))
        try Data("NORA7 from an older caption file.".utf8)
            .write(to: source.appendingPathComponent("SECOND.TXT"))

        var project = try StudioProject.create(at: directory)
        try await project.importFiles([heic, image])
        let final = try #require(project.images.first { $0.id == "Portrait.png" })
        let imported = try #require(project.images.first { $0.id == "Second.png" })
        #expect(final.caption == "NORA7 checked by a person.")
        #expect(final.captionState == .final)
        #expect(!final.isImported)
        #expect(imported.caption == "NORA7 from an older caption file.")
        #expect(imported.captionState == .imported)
        let finalRecord = try #require(try await SidecarSink(directory: project.imagesDirectory).record(final.id))
        #expect(finalRecord.sampleID == "Portrait.png")
        #expect(finalRecord.isHumanFinal)
        #expect(try await SidecarSink(directory: project.imagesDirectory).record(imported.id)?.captioner.requested
            == ProjectImage.importedCaptioner)
    }

    @Test func openingTextOnlyCaptionFilesMarksThemImported() async throws {
        let directory = temporaryTestDirectory("text-only-project")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try StudioProject.create(at: directory)
        let imageURL = project.imagesDirectory.appendingPathComponent("older-photo.png")
        try MediaEditor.png(MediaFixtures.image()).write(to: imageURL)
        try Data("CONCEPT8 from an older caption file.".utf8)
            .write(to: project.imagesDirectory.appendingPathComponent("older-photo.txt"))

        let opened = try await StudioProject.open(at: directory)
        let image = try #require(opened.images.first)
        #expect(image.caption == "CONCEPT8 from an older caption file.")
        #expect(image.isImported)
        #expect(image.captionState == .imported)
    }

    @Test func importsJSONOnlyHumanFinalRecordWhenCaptionTextIsMissing() async throws {
        let source = temporaryTestDirectory("json-only-sidecar")
        let directory = temporaryTestDirectory("json-only-project")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("Subject.png")
        try MediaEditor.png(MediaFixtures.image()).write(to: image)
        let sourceSink = try SidecarSink(directory: source)
        try await sourceSink.write("subject.png", caption: nil, record: ResponseRecord(
            sampleID: "subject.png", status: .written, source: "human", skill: "custom", profile: "plain",
            captioner: ModelNames(requested: "human"), critic: nil
        ))

        var project = try StudioProject.create(at: directory)
        try await project.importFiles([image])
        let imported = try #require(project.images.first)
        #expect(imported.caption.isEmpty)
        #expect(imported.isFinal)
        #expect(imported.status == .written)
        let destination = try SidecarSink(directory: project.imagesDirectory)
        let record = try #require(try await destination.record(imported.id))
        #expect(record.sampleID == imported.id)
        #expect(record.isHumanFinal)
        #expect(record.caption == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.captionURL(for: imported.id).path))
        #expect(FileManager.default.fileExists(atPath: destination.recordURL(for: imported.id).path))
    }

    @Test func chosenFilesImportWithoutCompanionsWhenTheirFolderCannotBeListed() async throws {
        let source = temporaryTestDirectory("unlisted-parent")
        let directory = temporaryTestDirectory("unlisted-parent-project")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("Chosen.png")
        try MediaEditor.png(MediaFixtures.image()).write(to: image)
        try Data("NORA7 caption beside it.".utf8).write(to: source.appendingPathComponent("Chosen.txt"))
        // Like a sandboxed file pick: the file itself is reachable, its folder cannot be listed.
        try FileManager.default.setAttributes([.posixPermissions: 0o311], ofItemAtPath: source.path)
        var project = try StudioProject.create(at: directory)
        await #expect(throws: (any Error).self) { try await project.importFiles([image]) }
        try await project.importFiles([image], fromFolder: false)
        let imported = try #require(project.images.first)
        #expect(imported.id == "Chosen.png")
        #expect(imported.caption.isEmpty)
    }

    @Test func ambiguousCaseInsensitiveCompanionsAreRejectedBeforeImport() async throws {
        let source = temporaryTestDirectory("ambiguous-sidecars")
        let directory = temporaryTestDirectory("ambiguous-project")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("Photo.jpg")
        let second = source.appendingPathComponent("photo.png")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        try Data("ambiguous caption".utf8).write(to: source.appendingPathComponent("PHOTO.txt"))
        var project = try StudioProject.create(at: directory)
        await #expect(throws: StudioError.self) { try await project.importFiles([first]) }
        #expect(project.images.isEmpty)
    }

    @Test func captionStateNamesSavedCaptionsAndRetainsRecentFailures() {
        var image = ProjectImage(url: URL(fileURLWithPath: "/photos/sample.png"))
        #expect(image.captionState == .ready)
        image.caption = "NORA7 beside a window."
        #expect(image.captionState == .imported)
        image.status = .written
        image.isImported = false
        #expect(image.captionState == .captioned)
        image.isImported = true
        #expect(image.captionState == .imported)
        image.isFinal = true
        #expect(image.captionState == .final)
        image.isFinal = false
        image.isImported = false
        image.status = .failed
        #expect(image.captionState == .outcome(.failed))
        image.isImported = true
        #expect(image.captionState == .importedOutcome(.failed))
    }

    @Test(arguments: [DemoScenario.success, .unusable, .rejected, .failed])
    func demoOutcomesUseCorePipeline(_ scenario: DemoScenario) async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let endpoint = ResolvedEndpoint(client: DemoModelClient(scenario: scenario))
        let runner = try Runner(
            job: project.job,
            captioner: endpoint,
            critic: scenario == .rejected ? endpoint : nil
        )
        let result = try await runner.run(
            source: LocalFolderSource(directory: project.imagesDirectory),
            sink: SidecarSink(directory: project.imagesDirectory)
        )
        let expected: SampleStatus = switch scenario {
        case .success: .written
        case .unusable: .unusable
        case .rejected: .rejected
        case .failed: .failed
        }
        #expect(result.outcomes.count == project.images.count)
        #expect(result.outcomes.allSatisfy { $0.status == expected })
    }

    @Test func importsAvoidSidecarStemCollisions() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let data = try Data(contentsOf: project.images[0].url)
        let count = project.images.count
        let name = try project.importData(data, name: "garden.jpg")
        #expect(name != "garden.jpg")
        #expect(try LocalFolderSource(directory: project.imagesDirectory).files.count == count + 1)
    }
}

@Suite("concept categories")
@MainActor
struct ConceptCategoryTests {
    @Test func styleAssignmentNeedsNoFaceReferenceAndSurvivesReopening() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let session = StudioSession(preferences: preferences.defaults, secrets: MemorySecretStore())
        session.project = project
        let style = try Concept(trigger: "INKSTYLE", targetConcept: .style)
        #expect(style.classNoun == "style")
        try session.saveConcept(style, replacing: "NORA7")
        let reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.job.concepts == [style])
        #expect(reopened.job.unmapped(reopened.images.map(\.id)).isEmpty)
        for image in reopened.images {
            #expect(reopened.job.mapping(for: image.id) == styleMapping)
        }
        #expect(style.attributesToDescribe.contains("subject matter"))
        #expect(!style.traitsToLearn.contains("distinctive facial identity"))
        session.mappingProposals = ["garden.jpg": ["INKSTYLE": "stale style assignment"]]
        try session.saveConcept(Concept(trigger: "NORA7"), replacing: "INKSTYLE")
        #expect(session.unmappedCount == project.images.count)
        #expect(session.mappingProposals.isEmpty)
    }

    @Test func wholeTargetAssignmentIncludesStyleAndMotionWithoutReplacingLocatorConfirmation() throws {
        let style = try Concept(trigger: "INKSTYLE", targetConcept: .style)
        #expect(try Job(concepts: [style]).mappingIncludingWholeTargets(nil) == styleMapping)
        let mixed = try Job(concepts: [style, Concept(trigger: "PERSON")])
        #expect(mixed.mappingIncludingWholeTargets(nil) == nil)
        let confirmed = mixed.mappingIncludingWholeTargets(["PERSON": "the person on the left"])
        #expect(confirmed?["INKSTYLE"] == styleMapping["INKSTYLE"])
        #expect(confirmed?["PERSON"] == "the person on the left")
        #expect(try Job(concepts: [Concept(trigger: "MUG", targetConcept: .object)])
            .mappingIncludingWholeTargets(nil) == nil)
    }

    private var styleMapping: Job.Mapping {
        ["INKSTYLE": "the visual style of the entire image or clip"]
    }
}
