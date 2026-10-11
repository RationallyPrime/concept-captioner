import ConceptCore
@testable import ConceptStudio
import CryptoKit
import Foundation
import Testing

@Suite("GPU workflow")
struct GPUWorkflowTests {
    private func expectCaptionStart(_ request: URLRequest, model: String) throws {
        #expect(request.url?.path() == "/services/vllm/start")
        let body = try JSONValue(parsing: #require(request.httpBody)).objectValue
        #expect(body?["gpus"] == .array([.int(0)]))
        let params = try #require(body?["params"]?.objectValue)
        #expect(params["model"]?.stringValue == model)
        #expect(params["max_model_len"]?.intValue == 16384)
        #expect(params["max_num_seqs"]?.intValue == 2)
        #expect(params["gpu_memory_utilization"]?.doubleValue == 0.85)
        #expect(params["extra_args"] == .array([.string("--enforce-eager"), .string("--max-num-batched-tokens=4096")]))
    }

    @MainActor @Test(arguments: [false, true], ["aitoolkit", "ltx"])
    func concurrentTrainingStartsOrReusesCaptionServer(_ captionEarlier: Bool, trainerName: String) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true, gpuCount: 2)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-only", imageName: "test")
        workspace.gpuCount = 2
        workspace.trainer = trainerName
        if !captionEarlier { workspace.captionModel = "Qwen/alternate-caption-model" }
        workspace.keepCaptionServer = true
        await workspace.refreshOffers()
        await workspace.rent()
        if captionEarlier { #expect(await workspace.startCaptioning()) }
        await workspace.train(datasetRepo: "test/images")
        let starts = await transport.starts
        let captionStarts = starts.filter { $0.url?.path() == "/services/vllm/start" }
        #expect(captionStarts.count == 1)
        try expectCaptionStart(#require(captionStarts.first), model: workspace.captionModel)
        let trainer = try #require(starts.first { $0.url?.path() == "/services/trainer-\(trainerName)/start" })
        let body = try JSONValue(parsing: #require(trainer.httpBody)).objectValue
        #expect(body?["gpus"] == .array([.int(1)]))
        let params = try #require(body?["params"]?.objectValue)
        #expect(params["resolution"]?.intValue == 512)
        #expect(params["sample_every"]?.intValue == 0)
        #expect(params["rank"]?.intValue == 16)
        // No output repo: the result is downloaded, not pushed.
        #expect(params["hub"] == nil)
        if trainerName == "ltx" {
            #expect(params["base_model"]?.stringValue == "Lightricks/LTX-2")
            let extra = try #require(params["extra"]?.objectValue)
            #expect(extra["optimization"] == .object(["optimizer_type": .string("adamw8bit")]))
            #expect(extra["acceleration"] == .object([
                "quantization": .string("int8-quanto"), "load_text_encoder_in_8bit": .bool(true),
                "offload_optimizer_during_validation": .bool(true),
            ]))
            #expect(extra["preprocess"] == .object(["args": .array([
                .string("--load-text-encoder-in-8bit"), .string("--vae-tiling"), .string("--skip-audio"),
            ])]))
        } else {
            #expect(params["extra"] == nil)
        }
        #expect(workspace.trainingState == "running")
        #expect(workspace.result?.state == .training)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func stoppedComputerMustBeExplicitlyRemovedBeforeAnotherRental() async {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        await workspace.rent()
        await workspace.stopEverything()
        let retained = workspace.pod?.id
        await workspace.rent()
        #expect(workspace.pod?.id == retained)
        #expect(workspace.pod?.status == "EXITED")
        #expect(workspace.message.contains("remove"))
        await workspace.terminate()
        #expect(workspace.pod == nil)
        workspace.gpuCount = 2
        await workspace.rent()
        await workspace.refresh()
        #expect(workspace.pod?.status == "RUNNING")
        #expect(workspace.plan?.mode == "concurrent")
        #expect(workspace.volumes.count == 1)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func offersMustHaveStockBesideTheSelectedStorage() async {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        #expect(workspace.availableOffers.count == 1)
        workspace.volumes.append(GPUVolume(id: "elsewhere", name: "Elsewhere", size: 100, dataCenter: "other"))
        workspace.selectedVolume = "elsewhere"
        workspace.selectAvailableOffer()
        #expect(workspace.availableOffers.isEmpty)
        #expect(workspace.selectedGPU.isEmpty)
        #expect(workspace.quotedHourlyRate == 0)
        await workspace.rent()
        #expect(workspace.pod == nil)
        workspace.selectedVolume = "demo-volume"
        workspace.offers[0].dataCenters = [.init(id: "demo", availability: "NONE")]
        workspace.selectAvailableOffer()
        #expect(workspace.availableOffers.isEmpty)
    }

    @MainActor @Test
    func undersizedGPUsCannotBeRentedForTheIncludedModels() async {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        workspace.offers = [24, 32].map { memory in
            GPUOffer(
                id: "gpu-\(memory)", name: "GPU", memory: memory, secure: true,
                price: .init(secure: 1), maxCount: .init(secure: 4), availability: "HIGH",
                dataCenters: [.init(id: "demo", availability: "HIGH")]
            )
        }
        #expect(workspace.availableOffers.map(\.id) == ["gpu-32"])
        workspace.selectedGPU = "gpu-24"
        await workspace.rent()
        #expect(workspace.pod == nil)
        workspace.selectAvailableOffer()
        #expect(workspace.selectedGPU == "gpu-32")
        await workspace.rent()
        #expect(workspace.hasRunningPod)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func trainerDefaultsApplyBeforeAnyTrainingViewExists() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.trainer = "ltx"
        #expect(workspace.baseModel == "Lightricks/LTX-2")
        workspace.baseModel = "custom/model"
        workspace.trainer = "ltx"
        #expect(workspace.baseModel == "custom/model")
        workspace.trainer = "aitoolkit"
        #expect(workspace.baseModel == "black-forest-labs/FLUX.1-dev")
    }

    @MainActor @Test
    func restoredBudgetStillStopsWhenAgentKeyCannotBeRead() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = SavedPod(
            pod: RentedPod(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 1)),
            started: Date().addingTimeInterval(-7200), hourlyRate: 1, budget: 1,
            trainer: "aitoolkit", runID: "previous-run", outputRepo: "test/model"
        )
        try preferences.set(JSONEncoder().encode(saved), forKey: GPUWorkspace.activePodKey)
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(
            transport, preferences, readAgentToken: { _ in throw StudioError.message("Keychain unavailable") }
        )
        #expect(throws: StudioError.self) {
            try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        }
        #expect(workspace.hasRunningPod)
        #expect(workspace.runID == "previous-run")
        try await waitUntil { !workspace.hasRunningPod }
        #expect(workspace.pod?.status == "EXITED")
        #expect(await transport.stopCalls == 1)
    }

    @MainActor @Test(arguments: [true, false])
    func captionReadinessUsesItsOwnKeyAndCanBeCancelled(_ ready: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: ready)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-only", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        let starting = Task { await workspace.startCaptioning() }
        for _ in 0 ..< 100 {
            if await !transport.inferenceRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        if !ready { starting.cancel() }
        #expect(await starting.value == ready)
        #expect(!workspace.isBusy)
        let request = try #require(await transport.inferenceRequests.first)
        #expect(request.url?.absoluteString == "https://test-8000.proxy.runpod.net/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + workspace.agentToken)
        try expectCaptionStart(#require(await transport.starts.first), model: workspace.captionModel)
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
    }

    @MainActor @Test
    func idleStopStillRunsWhenAgentReturns522() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.idleMinutes = 0
        await workspace.refresh()
        for _ in 0 ..< 100 where workspace.hasRunningPod {
            try await Task.sleep(for: .milliseconds(10))
            await workspace.refresh()
        }
        #expect(workspace.pod?.status == "EXITED")
        #expect(await transport.stopCalls == 1)
    }

    @MainActor @Test
    func budgetWatchSurvivesFailedKeychainAndEmergencyStop() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(failFirstStop: true)
        let workspace = makeWorkspace(
            transport, preferences, saveAgentToken: { _, _ in throw StudioError.message("Keychain unavailable") }
        )
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        workspace.budget = 0.000000001
        await workspace.rent()
        try await waitUntil { !workspace.hasRunningPod }
        #expect(workspace.pod?.status == "EXITED")
        #expect(await transport.stopCalls >= 2)
    }

    @Test(arguments: ["EXITED", "ERROR", "TERMINATED"])
    func stoppedProviderStatesDoNotRequireAnInvalidStopAction(_ status: String) {
        let pod = RentedPod(id: "pod1", status: status, cost: 0, gpu: .init(count: 1))
        #expect(!pod.isRunning)
    }

    @MainActor @Test
    func demoTrainsPublishesAndStopsWithoutNetwork() async throws {
        let transport = GPUTransport()
        let workspace = GPUWorkspace(demoMode: true, transport: transport)
        try workspace.configure(runpodKey: "must-not-use", hubToken: "must-not-use", imageName: "live-image")
        await workspace.refreshOffers()
        workspace.gpuCount = 2
        await workspace.rent()
        #expect(workspace.hasRunningPod)
        await workspace.refresh()
        #expect(workspace.plan?.mode == "concurrent")
        #expect(workspace.plan?.train?.gpus == [1])
        workspace.outputRepo = "demo/result"
        await workspace.train(datasetRepo: "demo/images")
        #expect(!workspace.runID.isEmpty)
        for _ in 0 ..< 10 {
            await workspace.refresh()
        }
        #expect(!workspace.points.isEmpty)
        #expect(workspace.trainingState == "exited")
        #expect(workspace.result?.state == .pushed(repo: "demo/result"))
        await workspace.publishResult()
        #expect(workspace.message.contains("uploaded"))
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
        #expect(await transport.requests.isEmpty)
    }

    @MainActor @Test
    func spendingCapStopsTheActualProviderState() async throws {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        workspace.budget = 1
        await workspace.rent()
        try await workspace.enforceLimits(now: Date().addingTimeInterval(7200))
        #expect(workspace.pod?.status == "EXITED")
        #expect(workspace.message.contains("spending limit"))
    }

    @MainActor @Test
    func theBudgetCanOnlyBeRaisedWhileRunning() async throws {
        let workspace = GPUWorkspace(demoMode: true)
        await workspace.refreshOffers()
        workspace.budget = 5
        #expect(!workspace.raiseBudget(to: 10))
        await workspace.rent()
        #expect(!workspace.raiseBudget(to: 4))
        #expect(!workspace.raiseBudget(to: .infinity))
        #expect(workspace.activeBudget == 5)
        #expect(workspace.raiseBudget(to: 10))
        #expect(workspace.activeBudget == 10)
        // $1.50/hour: six hours is $9, under the raised limit; seven is $10.50, over it.
        try await workspace.enforceLimits(now: Date().addingTimeInterval(6 * 3600))
        #expect(workspace.hasRunningPod)
        try await workspace.enforceLimits(now: Date().addingTimeInterval(7 * 3600))
        #expect(!workspace.hasRunningPod)
    }

    @Test
    func captionServerSettingsComeFromTheMeasuredTable() {
        let measured = GPUWorkspace.captionServerSettings(for: "Qwen/Qwen3-VL-8B-Instruct")
        #expect(measured.maxNumSeqs == 2)
        #expect(GPUWorkspace.captionServerSettings(for: "someone/unmeasured") == measured)
        #expect(measured.params(model: "someone/unmeasured")["model"]?.stringValue == "someone/unmeasured")
    }

    @Test
    func podNamesCarryTheProject() {
        #expect(PodNaming.name(project: "My Project!") == "ConceptStudio-My-Project")
        #expect(PodNaming.name(project: "") == "ConceptStudio")
        #expect(RentedPod(id: "a", status: "RUNNING", cost: 0, gpu: .init(count: 1), name: "ConceptStudio")
            .isFromThisApp)
        #expect(!RentedPod(id: "a", status: "RUNNING", cost: 0, gpu: .init(count: 1), name: "ConceptStudioX")
            .isFromThisApp)
    }

    @Test(arguments: ["aitoolkit", "ltx"])
    func creationUsesV2GPUFieldsAndOnlyAuthenticatedPublishedPorts(_ trainer: String) async throws {
        let transport = GPUTransport(#"{"id":"pod1","status":"STARTING","cost":1,"gpu":{"count":2}}"#)
        let provider = RunPodProvider(key: "runpod-key", transport: transport)
        let offer = GPUOffer(
            id: "gpu-id",
            name: "GPU",
            memory: 80,
            secure: true,
            price: .init(secure: 1),
            maxCount: .init(secure: 4),
            availability: "HIGH"
        )
        let pod = try await provider.create(PodCreation(
            name: PodNaming.name(project: "nora"), offer: offer, count: 2, image: "own/image:verified",
            minCudaVersion: GPUWorkspace.minimumCUDA(trainer),
            volume: GPUVolume(id: "volume", name: "Data", size: 100, dataCenter: "EU-IS-1"),
            agentToken: "agent-key", hubToken: "hub-key"
        ))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.runpod.io/v2/pods")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer runpod-key")
        let body = try JSONValue(parsing: #require(request.httpBody)).objectValue
        #expect(body?["name"]?.stringValue == "ConceptStudio-nora")
        #expect(body?["gpu"]?.objectValue?["count"]?.intValue == 2)
        // Both trainer images carry CUDA 13 wheels and need an R580+ (CUDA 13.0) host driver.
        #expect(body?["gpu"]?.objectValue?["minCudaVersion"]?.stringValue == "13.0")
        #expect(body?["gpu"]?.objectValue?["minRamPerGpu"]?.intValue == 60)
        #expect(body?["ports"]?.arrayValue?.compactMap(\.stringValue) == ["8800/http", "8000/http"])
        #expect(body?["mounts"]?.objectValue?["network"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            == "/workspace")
        #expect(body?["env"]?.objectValue?["HF_TOKEN"]?.stringValue == "hub-key")
        #expect(provider.url(for: pod, port: PodPort.agent).absoluteString == "https://pod1-8800.proxy.runpod.net")
        _ = try? await provider.offers(count: 1, minCudaVersion: GPUWorkspace.minimumCUDA(trainer))
        let query = try #require(await transport.requests.last?.url?.query())
        #expect(query.contains("minCudaVersion=13.0"))
    }
}

@Suite("GPU results and recovery")
struct GPUResultTests {
    @MainActor @Test(arguments: [true, false])
    func hubTokenPushesTheResultOnFinish(_ privateResult: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let downloader = FakeDownloader([:])
        let workspace = makeWorkspace(transport, preferences, downloader: downloader)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-write", imageName: "test")
        workspace.outputRepo = "me/lora"
        workspace.privateResult = privateResult
        workspace.resolution = 1024
        workspace.samplesEnabled = true
        await workspace.refreshOffers()
        await workspace.rent()
        await workspace.train(datasetRepo: "test/images")
        let params = try await trainerParams(transport, "aitoolkit")
        #expect(params["hub"] == .object([
            "repo_id": .string("me/lora"), "private": .bool(privateResult), "push_on_finish": .bool(true),
        ]))
        #expect(params["resolution"]?.intValue == 1024)
        #expect(params["sample_every"]?.intValue == 200)
        #expect(params["sample_prompts"] == .array([.string("NORA7")]))
        await transport.finish("trainer-aitoolkit", state: "exited")
        await workspace.refresh()
        #expect(workspace.result?.state == .pushed(repo: "me/lora"))
        #expect(await downloader.requests.isEmpty)
        #expect(preferences.data(forKey: GPUWorkspace.pendingResultKey) == nil)
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
    }

    @MainActor @Test
    func withoutHubTokenTheResultIsDownloadedAndVerifiedIntoTheProject() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("gpu-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        let weights = Data("final weights".utf8)
        let config = Data("job: extension".utf8)
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        await transport.files([
            RunFile(path: "output/lora_000000100.safetensors", size: 3, sha256: sha256(Data("old".utf8))),
            RunFile(path: "output/lora.safetensors", size: weights.count, sha256: sha256(weights)),
            RunFile(path: "config.yaml", size: config.count, sha256: sha256(config)),
            RunFile(path: "tensorboard/events.out.tfevents.1", size: 1, sha256: sha256(Data("e".utf8))),
        ])
        let downloader = FakeDownloader(["lora.safetensors": weights, "config.yaml": config])
        let workspace = makeWorkspace(transport, preferences, downloader: downloader)
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        workspace.projectFolder = project
        workspace.outputRepo = "me/lora"
        await workspace.refreshOffers()
        await workspace.rent()
        await workspace.train(datasetRepo: "test/images")
        #expect(try await trainerParams(transport, "aitoolkit")["hub"] == nil)
        let runID = workspace.runID
        #expect(workspace.result?.destination == .download)
        await transport.finish("trainer-aitoolkit", state: "exited")
        await workspace.refresh()
        try await waitUntil { if case .saved = workspace.result?.state { true } else { false } }
        let folder = project.appendingPathComponent("results/\(runID)")
        #expect(workspace.result?.state == .saved(folder: folder.path))
        #expect(try Data(contentsOf: folder.appendingPathComponent("output/lora.safetensors")) == weights)
        #expect(try Data(contentsOf: folder.appendingPathComponent("config.yaml")) == config)
        let requests = await downloader.requests
        #expect(requests.map { $0.url?.path() ?? "" }.sorted() == [
            "/runs/\(runID)/files/config.yaml", "/runs/\(runID)/files/output/lora.safetensors",
        ])
        #expect(requests
            .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + workspace.agentToken })
        let record = ProjectTrainingRecord.load(from: project)
        #expect(record.outputRepo == "me/lora")
        #expect(record.results.last?.state == .saved(folder: folder.path))
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
    }

    @MainActor @Test
    func anUnsavedResultBlocksIdleStopAndAsksBeforeStop() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        await transport.files([RunFile(path: "output/lora.safetensors", size: 5, sha256: sha256(Data("right".utf8)))])
        let workspace = makeWorkspace(
            transport, preferences, downloader: FakeDownloader(["lora.safetensors": Data("wrong".utf8)])
        )
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        await workspace.train(datasetRepo: "test/images")
        await transport.finish("trainer-aitoolkit", state: "exited")
        await workspace.refresh()
        try await waitUntil { workspace.message.contains("checksum") }
        try await waitUntil { !workspace.isBusy }
        #expect(workspace.result?.state == .pending)
        #expect(preferences.data(forKey: GPUWorkspace.pendingResultKey) != nil)
        workspace.idleMinutes = 0
        await workspace.refresh()
        #expect(workspace.hasRunningPod)
        await workspace.stopEverything()
        #expect(workspace.hasRunningPod)
        #expect(workspace.message.contains("not saved yet"))
        #expect(await transport.stopCalls == 0)
        await workspace.stopEverything(discardingPendingResult: true)
        #expect(!workspace.hasRunningPod)
        await workspace.terminate()
        #expect(workspace.pod == nil)
        let next = makeWorkspace(UnreachableAgentTransport(), preferences)
        next.idleMinutes = 5 // a settings change before configure must not drop the pending result
        try next.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        #expect(next.result?.state == .pending)
        #expect(next.result?.runID == workspace.result?.runID)
    }

    @MainActor @Test
    func olderPodRecordsRestoreAndIdleMinutesPersist() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        // The shape an earlier build saved: no idle minutes, volume, points or result.
        let older = #"{"pod":{"id":"test","status":"RUNNING","cost":1,"gpu":{"count":1}},"started":0,"#
            + #""hourlyRate":1,"budget":100000,"trainer":"aitoolkit","runID":"","outputRepo":""}"#
        preferences.set(Data(older.utf8), forKey: GPUWorkspace.activePodKey)
        let restored = try JSONDecoder().decode(SavedPod.self, from: Data(older.utf8))
        #expect(restored.idleMinutes == 15)
        let workspace = makeWorkspace(UnreachableAgentTransport(), preferences)
        try workspace.configure(runpodKey: "test", hubToken: "", imageName: "test")
        #expect(workspace.hasRunningPod)
        workspace.idleMinutes = 42
        let data = try #require(preferences.data(forKey: GPUWorkspace.activePodKey))
        #expect(try JSONDecoder().decode(SavedPod.self, from: data).idleMinutes == 42)
        let next = makeWorkspace(UnreachableAgentTransport(), preferences)
        try next.configure(runpodKey: "test", hubToken: "", imageName: "test")
        #expect(next.idleMinutes == 42)
        await workspace.stopEverything()
        await next.stopEverything()
    }

    @MainActor @Test
    func launchFindsRunningPodsWhoseRecordWasLost() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let pod = #"{"id":"%@","name":"%@","status":"%@","cost":1.5,"gpu":{"count":1}}"#
        await transport.list([
            String(format: pod, "test", "ConceptStudio-alpha", "RUNNING"),
            String(format: pod, "other", "ConceptStudio-beta", "RUNNING"),
            String(format: pod, "old", "ConceptStudio-gamma", "EXITED"),
            String(format: pod, "theirs", "jupyter", "RUNNING"),
        ])
        let sleep = SleepCounter()
        var tokenAccounts: [String] = []
        let workspace = makeWorkspace(transport, preferences, sleep: sleep, readAgentToken: {
            tokenAccounts.append($0)
            return "restored-token"
        })
        try workspace.configure(runpodKey: "test", hubToken: "", imageName: "test")
        try await waitUntil { workspace.pod != nil }
        #expect(workspace.pod?.id == "test")
        #expect(workspace.hasRunningPod)
        #expect(workspace.agentToken == "restored-token")
        #expect(tokenAccounts == ["pod.test"])
        #expect(workspace.strayPods.map(\.id) == ["other"])
        #expect(workspace.keepsMacAwake)
        #expect(preferences.data(forKey: GPUWorkspace.activePodKey) != nil)
        await workspace.stopStrayPod(id: "other")
        #expect(await transport.stoppedPods == ["other"])
        #expect(workspace.strayPods.isEmpty)
        await workspace.stopEverything()
        #expect(sleep.ended == 1)
    }

    @MainActor @Test
    func theMacStaysAwakeOnlyWhileAPodRuns() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let sleep = SleepCounter()
        var saved: [String: String] = [:]
        var deleted: [String] = []
        let workspace = makeWorkspace(
            UnreachableAgentTransport(), preferences, sleep: sleep,
            saveAgentToken: { saved[$1] = $0 }, deleteAgentToken: { deleted.append($0) }
        )
        try workspace.configure(runpodKey: "test", hubToken: "", imageName: "test")
        #expect(!workspace.keepsMacAwake)
        await workspace.refreshOffers()
        await workspace.rent()
        #expect(workspace.keepsMacAwake)
        #expect(sleep.begun == 1)
        // 256 bits from SecRandomCopyBytes, hex encoded, saved to the Keychain under the pod id.
        #expect(workspace.agentToken.count == 64)
        let isHex = workspace.agentToken.allSatisfy(\.isHexDigit)
        #expect(isHex)
        #expect(saved["pod.test"] == workspace.agentToken)
        await workspace.stopEverything()
        #expect(!workspace.keepsMacAwake)
        #expect(sleep.ended == 1)
        await workspace.terminate()
        #expect(deleted == ["pod.test"])
    }

    @MainActor @Test
    func logsAndTheFullCurveComeFromTheRunAndPersist() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = SavedPod(
            pod: RentedPod(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 1)),
            started: Date(), hourlyRate: 1, budget: 100, trainer: "aitoolkit", runID: "previous-run", outputRepo: ""
        )
        try preferences.set(JSONEncoder().encode(saved), forKey: GPUWorkspace.activePodKey)
        let inner = UnreachableAgentTransport(agentAvailable: true)
        let transport = CurveTransport(inner, rows: "[[1.0, 10, 0.9], [2.0, 20, 0.7], [3.0, 30, 0.5]]")
        let workspace = makeWorkspace(transport, preferences, readAgentToken: { _ in "token" })
        try workspace.configure(runpodKey: "test", hubToken: "", imageName: "test")
        await workspace.refresh()
        #expect(workspace.points.map(\.step) == [10, 20, 30])
        #expect(workspace.logs == "step 1 loss 0.5")
        let paths = await inner.agentRequests.compactMap { $0.url?.path() }
        #expect(paths.contains("/runs/previous-run/log"))
        #expect(!paths.contains { $0.hasPrefix("/services/trainer-") && $0.hasSuffix("/logs") })
        let data = try #require(preferences.data(forKey: GPUWorkspace.activePodKey))
        #expect(try JSONDecoder().decode(SavedPod.self, from: data).points.map(\.step) == [10, 20, 30])
        await workspace.stopEverything()
    }

    @Test
    func runArtifactsKeepTheFinalLoRAConfigAndSamples() {
        let files = [
            "output/x_000000250.safetensors", "output/x_000000500.safetensors", "output/x.safetensors",
            "tensorboard/events.out.tfevents.1", "samples/1.png", "run.json", "preprocessed/latents/a.json",
            "trainer.log", "../escape.json",
        ].map { RunFile(path: $0, size: 1, sha256: "") }
        #expect(RunArtifacts.selection(files).map(\.path) == [
            "output/x.safetensors", "samples/1.png", "run.json", "trainer.log",
        ])
        let numbered = ["ckpt/lora_00250.safetensors", "ckpt/lora_01000.safetensors"]
            .map { RunFile(path: $0, size: 1, sha256: "") }
        #expect(RunArtifacts.newest(numbered)?.path == "ckpt/lora_01000.safetensors")
        let timed = [
            RunFile(path: "b.safetensors", size: 1, sha256: "", mtime: 2),
            RunFile(path: "a.safetensors", size: 1, sha256: "", mtime: 3),
        ]
        #expect(RunArtifacts.newest(timed)?.path == "a.safetensors")
        #expect(RunArtifacts.selection([RunFile(path: "run.json", size: 1, sha256: "")]).isEmpty)
    }
}
