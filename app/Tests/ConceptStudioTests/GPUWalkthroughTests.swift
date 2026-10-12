import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

actor RunPodFailureTransport: HTTPTransport {
    let status: Int
    let body: Data
    init(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) -> HTTPResponse {
        HTTPResponse(status: status, body: body)
    }
}

@Suite("Walkthrough GPU storage and recipes")
struct GPUWalkthroughTests {
    @MainActor @Test func stockMustMatchTheStorageLocationAndRequestedGPUCount() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.volumes = [.init(id: "ro", name: "Dataset", size: 300, dataCenter: "EU-RO-1")]
        workspace.selectedVolume = "ro"
        workspace.offers = [
            offer("large", locations: [.init(id: "CA-MTL-3", availability: "HIGH")]),
            offer("local", locations: [.init(id: "EU-RO-1", availability: "LOW")]),
            offer("empty", locations: [.init(id: "EU-RO-1", availability: "NONE")]),
            offer("unknown", locations: [.init(id: "EU-RO-1", availability: "UNKNOWN")]),
        ]
        #expect(workspace.availableOffers.map(\.id) == ["local"])
        workspace.gpuCount = 4
        workspace.offers.append(offer("too-small", locations: [.init(id: "EU-RO-1", availability: "HIGH")], count: 1))
        #expect(workspace.availableOffers.map(\.id) == ["local"])
        workspace.selectedVolume = ""
        #expect(workspace.availableOffers.map(\.id) == ["large", "local"])
        workspace.selectedVolume = "removed-volume"
        #expect(workspace.availableOffers.isEmpty)
    }

    @Test func noSavedStorageUsesAPodDiskAndKeepsTheContainerDiskTemporary() async throws {
        let transport = GPUTransport(#"{"id":"pod1","status":"STARTING","cost":1,"gpu":{"count":1}}"#)
        let provider = RunPodProvider(key: "fixture", transport: transport)
        _ = try await provider.create(.init(
            name: "ConceptStudio-fixture", offer: offer("large", locations: []), count: 1,
            image: "fixture/image", minCudaVersion: "13.0", volume: nil, env: [:]
        ))
        let request = try #require(await transport.requests.first)
        let data = try #require(request.httpBody)
        let body = try #require(JSONValue(parsing: data).objectValue)
        #expect(body["disk"] == .int(50))
        #expect(body["dataCenterIds"] == nil)
        #expect(body["mounts"] == .object(["persistent": .object([
            "size": .int(300), "path": .string("/workspace"),
        ])]))
    }

    @Test(arguments: [400, 422, 402, 403, 429])
    func providerErrorsRetainTheirActualRefusalAndValidationReasons(_ status: Int) async throws {
        let provider = RunPodProvider(key: "fixture", transport: RunPodFailureTransport(
            status: status,
            body: #"{"title":"Rejected","detail":"RTX PRO 6000 is unavailable in EU-RO-1","#
                + #""errors":["gpu.count: unavailable"]}"#
        ))
        do {
            _ = try await provider.offers(count: 1, minCudaVersion: "13.0")
            Issue.record("A refused catalog request succeeded")
        } catch {
            #expect(error.localizedDescription.contains("RTX PRO 6000 is unavailable in EU-RO-1"))
            #expect(error.localizedDescription.contains("gpu.count: unavailable"))
            #expect(error.localizedDescription.contains(String(status)))
        }
    }

    @MainActor @Test func blankImageChoiceUsesThePublishedDefaultAtRental() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "fixture", hubToken: "", imageName: "")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let body = try #require(await transport.createBodies.first)
        #expect(body["image"]?.stringValue == StudioSession.defaultPodImageName
            .replacingOccurrences(of: "{trainer}", with: "aitoolkit"))
        #expect(workspace.imageName.isEmpty)
        await workspace.stopEverything()
    }

    @MainActor @Test func podDiskCustodySurvivesBudgetStopAndBlocksRemovalUntilDelivery() async throws {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        workspace.selectedVolume = ""
        await workspace.refreshOffers()
        #expect(workspace.selectedVolume.isEmpty)
        await workspace.rent()
        workspace.monitorTask?.cancel()
        let podID = try #require(workspace.pod?.id)
        #expect(workspace.currentVolumeID == "pod:" + podID)
        workspace.result = .init(
            runID: "concept-pending", outputRepo: "", destination: .download,
            volumeID: workspace.currentVolumeID, state: .pending
        )
        workspace.saved?.started = Date().addingTimeInterval(-3600)
        workspace.saved?.budget = 0.01
        try await workspace.enforceLimits()
        #expect(!workspace.hasRunningPod)
        #expect(workspace.result?.state == .pending)
        #expect(workspace.message.contains("same computer"))
        #expect(workspace.hasUndeliveredPodOutputs)
        await workspace.terminate()
        #expect(workspace.pod?.id == podID)
        #expect(workspace.message.contains("retrieve"))
        workspace.budget = 10
        workspace.saved?.hourlyRate = 0.25
        await workspace.startStoppedComputer()
        workspace.monitorTask?.cancel()
        #expect(workspace.hasRunningPod)
        #expect(workspace.saved?.hourlyRate == 1.5)
        #expect(workspace.currentVolumeID == "pod:" + podID)
        #expect(workspace.estimatedPodCost < 2) // Stopped time is not GPU work.
        workspace.result?.state = .pushed(repo: "fixture/result")
        await workspace.terminate()
        #expect(workspace.pod == nil)
    }

    @MainActor @Test func h3DefaultsAndRepeatPreserveTheEffectiveRecipe() throws {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel(GPUWorkspace.h3BaseModel)
        let params = workspace.trainingParams(dataset: "concept-source", inputFacts: ("h3-still", "NORA7", false))
        #expect(params["resolution"] == .array([.int(768), .int(1024)]))
        #expect(params["save_every"] == .int(300))
        #expect(params["extra"]?.objectValue?["save"] == .object([
            "save_every": .int(300), "max_step_saves_to_keep": .int(40), "dtype": .string("float32"),
        ]))
        #expect(params["extra"]?.objectValue?["train"]?.objectValue?["do_guidance_loss"] == .bool(false))
        workspace.nativeRecipe = try NativeTrainingRecipe.load(Data(H3TrainingTests.recipe.utf8))
        workspace.checkpointEvery = 123
        workspace.checkpointRetention = 8
        workspace.checkpointPrecision = "bfloat16"
        workspace.guidanceLoss = true
        workspace.guidanceTargetText = "[2.5, 3.5]"
        workspace.trainingResolutions = [512, 1024]
        let changed = workspace.trainingParams(dataset: "concept-source", inputFacts: ("h3-still", "NORA7", false))
        let run = TrainingRun(
            runID: "concept-source", trainer: "aitoolkit", datasetRepo: "fixture/data",
            datasetContainsVideo: false, paramsJSON: JSONValue.object(changed).pythonDumpsData(),
            volumeID: "fixture-storage", startedAt: Date(), updatedAt: Date(), podSpendAtStart: 0
        )
        workspace.runHistory = [run]
        workspace.repeatSettings(from: run)
        let repeated = workspace.trainingParams(dataset: "concept-repeat", inputFacts: ("h3-still", "NORA7", false))
        #expect(repeated["extra"] == changed["extra"])
        #expect(repeated["resolution"] == changed["resolution"])
        #expect(repeated["save_every"] == .int(123))
        workspace.chooseTrainingModel("black-forest-labs/FLUX.1-dev")
        #expect(workspace.trainingResolutions == [512])
        #expect(workspace.checkpointPrecision == "float16")
    }

    @MainActor @Test(arguments: [false, true])
    func lostRemoteStartReplyRetainsPodDiskOutputCustody(_ generation: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        await agent.loseStartAcknowledgements()
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = folder
        workspace.hubToken = "fixture"
        workspace.pod = .init(id: "fixture", status: "RUNNING", cost: 1, gpu: .init(count: 2))
        workspace.saved = try .init(
            pod: #require(workspace.pod), started: Date(), hourlyRate: 1, budget: 10, trainer: "aitoolkit",
            runID: "", outputRepo: "", volumeID: "pod:fixture"
        )
        workspace.agent = agent
        if generation {
            let run = TrainingRun(
                runID: "source", trainer: "aitoolkit", datasetRepo: "fixture/data", datasetContainsVideo: false,
                paramsJSON: JSONValue.object(["base_model": .string("black-forest-labs/FLUX.1-dev")])
                    .pythonDumpsData(), volumeID: "pod:fixture", startedAt: Date(), updatedAt: Date(),
                podSpendAtStart: 0
            )
            workspace.runHistory = [run]
            await workspace.generateComparison(
                run: run, checkpoint: .init(
                    path: "chosen.safetensors",
                    size: 1,
                    sha256: String(repeating: "a", count: 64)
                ),
                prompts: ["NORA7 portrait"], seeds: [42]
            )
            #expect(workspace.generation?.state == .generating)
            #expect(!workspace.generations.isEmpty)
        } else {
            await workspace.train(datasetRepo: "fixture/data")
            #expect(workspace.result?.state == .training)
            #expect(!workspace.runHistory.isEmpty)
        }
        #expect(workspace.message.contains("lost start acknowledgement"))
        #expect(workspace.hasUndeliveredPodOutputs)
        await workspace.terminate()
        #expect(workspace.pod?.id == "fixture")
    }

    @MainActor @Test(arguments: [false, true])
    func refreshDuringAnActionDefersTrainingAndGenerationSettlement(_ actionAlreadyActive: Bool) async {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        await workspace.refresh() // Drain any already-started background refresh.
        let agent = HistoryAgent()
        await agent.pauseNextProgressRead()
        workspace.agent = agent
        workspace.runID = "concept-preparing"
        workspace.historyRunID = workspace.runID
        workspace.result = .init(
            runID: workspace.runID, outputRepo: "", destination: .download,
            volumeID: workspace.currentVolumeID, state: .training
        )
        workspace.isBusy = actionAlreadyActive
        let refresh = Task { await workspace.refresh() }
        await agent.waitForPausedProgressRead()
        let comparison = GeneratedComparison(
            runID: "comparison-preparing", sourceRunID: workspace.runID, checkpoint: "fixture.safetensors",
            trainer: "aitoolkit", volumeID: workspace.currentVolumeID, startedAt: Date(), state: .generating,
            paramsJSON: JSONValue.object([:]).pythonDumpsData()
        )
        if actionAlreadyActive {
            workspace.generation = comparison
            workspace.isBusy = false // A prior action finishes during the refresh.
        } else {
            // An entire action starts and finishes while an idle refresh awaits progress.
            await workspace.perform { workspace.generation = comparison }
        }
        await agent.releaseProgressRead()
        await refresh.value
        #expect(workspace.result?.state == .training)
        #expect(workspace.generation?.state == .generating)
        #expect(await agent.listedRunIDs.isEmpty)
        await workspace.refresh() // Fresh empty run-file inspections are real failed completions.
        #expect(workspace.result?.state == .failed)
        #expect(workspace.generation?.state == .failed)
        #expect(await agent.listedRunIDs == [workspace.runID, comparison.runID])
        await workspace.stopEverything()
    }

    private func offer(_ id: String, locations: [GPUOffer.Location], count: Int = 4) -> GPUOffer {
        GPUOffer(
            id: id,
            name: id,
            memory: 96,
            secure: true,
            price: .init(secure: 1),
            maxCount: .init(secure: count),
            availability: "HIGH",
            dataCenters: locations
        )
    }
}
