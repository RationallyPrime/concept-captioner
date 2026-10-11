import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Persistent per-training-run budgets")
struct TrainingBudgetTests {
    @MainActor @Test(arguments: [0.0, -1.0, Double.infinity])
    func invalidCapRefusesBeforePreparation(cap: Double) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        let workspace = H3TrainingTests.connected(preferences, folder: project.directory, agent: agent)
        workspace.hubToken = ""
        workspace.runBudget = cap
        await workspace.train(datasetRepo: "")
        #expect(workspace.runHistory.isEmpty)
        #expect(await agent.uploads.isEmpty)
        #expect(await agent.starts.isEmpty)
    }

    @MainActor @Test(arguments: [false, true])
    func failedOrCancelledUploadSettlesPreparationAndPreservesCost(cancel: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        let workspace = H3TrainingTests.connected(preferences, folder: project.directory, agent: agent)
        workspace.hubToken = ""
        if cancel { await agent.holdUpload() } else { await agent.failUpload() }
        let task = Task { await workspace.train(datasetRepo: "") }
        if cancel {
            for _ in 0 ..< 100 where await !(agent.paused) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await agent.paused)
            task.cancel()
            await agent.release()
        }
        await task.value
        #expect(!workspace.isBusy && !workspace.isTraining)
        #expect(workspace.result?.state == .failed)
        let run = try #require(workspace.runHistory.last)
        #expect(run.gpuBudgetUSD == 10)
        #expect(run.estimatedGPUCostUSD != nil)
        #expect(run.result?.state == .failed)
        #expect(await agent.starts.allSatisfy { !$0.service.hasPrefix("trainer-") })
        #expect(ProjectTrainingRecord.load(from: project.directory).runs.last?.result?.state == .failed)
    }

    @MainActor @Test func setupSpendIsCountedAndCapStopsBeforeTrainerPOST() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        let transport = UnreachableAgentTransport()
        let workspace = H3TrainingTests.connected(preferences, folder: project.directory, agent: agent)
        workspace.provider = RunPodProvider(key: "synthetic", transport: transport)
        workspace.hubToken = ""
        workspace.runBudget = 0.25
        workspace.saved?.budget = 20
        await agent.holdUpload()
        let work = Task { await workspace.train(datasetRepo: "") }
        for _ in 0 ..< 100 where await !(agent.paused) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let admitted = try #require(workspace.runHistory.last)
        #expect(admitted.gpuBudgetUSD == 0.25 && admitted.result?.state == .training)
        let prior = try #require(workspace.saved)
        // Move the billing clock forward while transfer is suspended; no real elapsed hour.
        workspace.saved = SavedPod(
            pod: prior.pod,
            started: Date().addingTimeInterval(-3600),
            hourlyRate: 1,
            budget: 20,
            trainer: prior.trainer,
            runID: prior.runID,
            outputRepo: prior.outputRepo,
            volumeID: prior.volumeID
        )
        await agent.release()
        await work.value
        try await waitUntil { !workspace.hasRunningPod }
        #expect(await agent.starts.allSatisfy { !$0.service.hasPrefix("trainer-") })
        #expect(workspace.result?.state == .failed)
        #expect((workspace.runHistory.last?.estimatedGPUCostUSD ?? 0) >= 0.25)
        #expect(await transport.stopCalls == 1)
    }

    @MainActor @Test func resumeKeepsBudgetAndAddsContinuationCostWithoutReuploadingInitializer() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        let workspace = H3TrainingTests.connected(preferences, folder: project.directory, agent: agent)
        workspace.baseModel = GPUWorkspace.h3BaseModel
        workspace.runBudget = 1
        await workspace.train(datasetRepo: "synthetic/data")
        workspace.updateResult(.pushed(repo: "synthetic/model"))
        var run = try #require(workspace.runHistory.last)
        run.params["initialization"] = .object(["name": .string("init-old"), "lora_sha256": .string("old")])
        run.estimatedGPUCostUSD = 0.4
        run.points = [.init(step: 200, loss: 0.1)]
        workspace.runHistory = [run]
        workspace.runBudget = 99
        await workspace.resumeRun(run, totalSteps: 400)
        let resumed = try #require(workspace.runHistory.last)
        #expect(resumed.gpuBudgetUSD == 1)
        #expect(resumed.previousGPUCostUSD == 0.4)
        #expect(abs(workspace.currentRunCost(resumed, podCost: resumed.podSpendAtStart + 0.2) - 0.6) < 0.0001)
        let starts = await agent.starts
        let request = try #require(starts.last { $0.service == "trainer-aitoolkit" })
        #expect(request.params["resume"] == .bool(true))
        #expect(request.params["initialization"] == run.params["initialization"])
        #expect(await agent.uploads.isEmpty)
    }

    @MainActor @Test func restoredGlobalRunCapStopsEvenWithoutProjectOrAgent() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(transport, preferences)
        let pod = RentedPod(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        let result = TrainingResult(
            runID: "global-run",
            outputRepo: "",
            destination: .download,
            volumeID: "storage",
            state: .training
        )
        let run = TrainingRun(
            runID: result.runID,
            trainer: "aitoolkit",
            datasetRepo: "synthetic/data",
            datasetContainsVideo: false,
            paramsJSON: Data("{}".utf8),
            volumeID: "storage",
            startedAt: Date(),
            updatedAt: Date(),
            result: result,
            gpuBudgetUSD: 0.25,
            podSpendAtStart: 0
        )
        let saved = SavedPod(
            pod: pod,
            started: Date().addingTimeInterval(-1800),
            hourlyRate: 1,
            budget: 20,
            trainer: "aitoolkit",
            runID: result.runID,
            outputRepo: "",
            volumeID: "storage",
            result: result,
            run: run
        )
        workspace.saved = try JSONDecoder().decode(SavedPod.self, from: JSONEncoder().encode(saved))
        workspace.pod = pod
        workspace.result = result
        workspace.runID = result.runID
        workspace.provider = RunPodProvider(key: "synthetic", transport: transport)
        workspace.persist()
        #expect(workspace.saved?.run?.gpuBudgetUSD == 0.25)
        try await workspace.enforceLimits()
        #expect(!workspace.hasRunningPod)
        #expect(await transport.stopCalls == 1)
        #expect(workspace.runHistory.isEmpty)
        #expect((workspace.saved?.run?.estimatedGPUCostUSD ?? 0) >= 0.25)
    }
}
