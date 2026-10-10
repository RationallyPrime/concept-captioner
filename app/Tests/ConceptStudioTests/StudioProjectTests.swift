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
        var project = try await DemoProject.create()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        #expect(project.images.count == 3)
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
        #expect(paths.contains("garden.png"))
        #expect(paths.contains("garden.txt"))
        #expect(paths.contains("garden.json"))
    }

    @Test(arguments: [DemoScenario.success, .unusable, .rejected, .failed])
    func demoOutcomesUseCorePipeline(_ scenario: DemoScenario) async throws {
        let project = try await DemoProject.create()
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
        #expect(result.outcomes.count == 3)
        #expect(result.outcomes.allSatisfy { $0.status == expected })
    }

    @Test func importsAvoidSidecarStemCollisions() async throws {
        var project = try await DemoProject.create()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let data = try Data(contentsOf: project.images[0].url)
        let name = try project.importData(data, name: "garden.jpg")
        #expect(name != "garden.jpg")
        #expect(try LocalFolderSource(directory: project.imagesDirectory).files.count == 4)
    }
}
