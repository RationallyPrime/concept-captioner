import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Generation manifest outcome")
struct GPUComparisonFailureTests {
    @MainActor @Test(arguments: ["failed", "generating", "complete", "missing"], [false, true])
    func partialComparisonsRemainFailedAndKeepDownloadedFiles(state: String, bothFiles: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = folder
        let pod = RentedPod(id: "offline", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.pod = pod
        workspace.saved = SavedPod(
            pod: pod, started: Date(), hourlyRate: 1, budget: 10, trainer: "aitoolkit",
            runID: "source", outputRepo: "", volumeID: "pod:offline"
        )
        workspace.agent = agent
        workspace.runHistory = [TrainingRun(
            runID: "source", trainer: "aitoolkit", datasetRepo: "me/synthetic", datasetContainsVideo: false,
            paramsJSON: Data("{}".utf8), volumeID: "pod:offline", startedAt: Date(), updatedAt: Date(),
            podSpendAtStart: 0
        )]
        workspace.generation = GeneratedComparison(
            runID: "comparison", sourceRunID: "source", checkpoint: "chosen.safetensors", trainer: "aitoolkit",
            volumeID: "pod:offline", startedAt: Date(), state: .pending, paramsJSON: Data("{}".utf8)
        )
        var bodies = ["base.png": Data("synthetic partial output".utf8)]
        if bothFiles { bodies["lora.png"] = Data("synthetic trained output".utf8) }
        if state != "missing" {
            bodies["comparison.json"] = JSONValue.object([
                "state": .string(state), "pairs": .array([.object([
                    "prompt": .string("NORA7"), "seed": .int(42),
                    "base_path": .string("base.png"), "lora_path": .string("lora.png"),
                ])]),
            ]).pythonDumpsData()
        }
        await agent.serve(bodies)
        await workspace.retrieveResult()
        let comparison = try #require(workspace.generation)
        let complete = state == "complete" && bothFiles
        #expect(comparison.state == (complete ? .saved : .failed))
        #expect(comparison.folder != nil)
        #expect(workspace.comparisonFile("base.png", in: comparison) != nil)
        #expect(!workspace.resultNeedsSaving)
        #expect(!workspace.hasUndeliveredPodOutputs)
        #expect(ProjectTrainingRecord.load(from: folder).comparisons.last?.state == comparison.state)
        if !complete { #expect(comparison.failure?.contains("did not complete") == true) }
    }

    @MainActor @Test(arguments: ["jpg", "webp"])
    func undownloadedPartialImagesKeepPodDiskCustody(_ suffix: String) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = folder
        workspace.pod = .init(id: "offline", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.runHistory = [TrainingRun(
            runID: "source", trainer: "aitoolkit", datasetRepo: "fixture/data", datasetContainsVideo: false,
            paramsJSON: Data("{}".utf8), volumeID: "pod:offline", startedAt: Date(), updatedAt: Date(),
            podSpendAtStart: 0
        )]
        workspace.generation = GeneratedComparison(
            runID: "comparison", sourceRunID: "source", checkpoint: "chosen.safetensors", trainer: "aitoolkit",
            volumeID: "pod:offline", startedAt: Date(), state: .generating, paramsJSON: Data("{}".utf8)
        )
        workspace.agent = agent
        await agent.serve(["partial." + suffix: Data("synthetic partial output".utf8)], damaged: true)
        workspace.isBusy = true // Inspect settlement before automatic retrieval is permitted.
        try await workspace.settleGeneration(agent, services: [])
        workspace.isBusy = false
        #expect(workspace.generation?.state == .pending)
        #expect(workspace.hasUndeliveredPodOutputs)
        await workspace.retrieveResult()
        #expect(workspace.generation?.state == .pending)
        #expect(workspace.hasUndeliveredPodOutputs)
        await agent.serve(["partial." + suffix: Data("synthetic partial output".utf8)])
        await workspace.retrieveResult()
        #expect(workspace.generation?.state == .failed) // Pair incomplete, but every available file is saved.
        #expect(workspace.generation?.folder != nil)
        #expect(!workspace.hasUndeliveredPodOutputs)
    }
}
