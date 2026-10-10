import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor GPUTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let body: Data

    init(_ json: String = "{}") {
        body = Data(json.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: 200, body: body)
    }
}

private actor UnreachableAgentTransport: HTTPTransport {
    private var stopped = false
    private var failedFirstStop: Bool
    private let agentAvailable: Bool
    private let inferenceReady: Bool
    private let gpuCount: Int
    private var services: [String: String] = [:]
    private var servedModel = "Qwen/Qwen3-VL-8B-Instruct"
    private(set) var stopCalls = 0
    private(set) var inferenceRequests: [URLRequest] = []
    private(set) var starts: [URLRequest] = []

    init(failFirstStop: Bool = false, agentAvailable: Bool = false, inferenceReady: Bool = false, gpuCount: Int = 1) {
        failedFirstStop = !failFirstStop
        self.agentAvailable = agentAvailable
        self.inferenceReady = inferenceReady
        self.gpuCount = gpuCount
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        if url.host()?.contains("-8000.") == true {
            inferenceRequests.append(request)
            return HTTPResponse(
                status: inferenceReady ? 200 : 503,
                body: JSONValue.object(["data": .array([.object(["id": .string(servedModel)])])]).pythonDumpsData()
            )
        }
        if url.host() != "api.runpod.io" {
            guard agentAvailable else { return HTTPResponse(status: 522) }
            if url.lastPathComponent == "start" {
                starts.append(request)
                let service = url.deletingLastPathComponent().lastPathComponent
                guard services[service] != "running" else { return HTTPResponse(status: 409) }
                services[service] = service == "pull-dataset" ? "exited" : "running"
                if service == "vllm" {
                    servedModel = try JSONValue(parsing: #require(request.httpBody))
                        .objectValue?["params"]?.objectValue?["model"]?.stringValue ?? servedModel
                }
            }
            let reply: JSONObject = if url.lastPathComponent == "plan" {
                [
                    "mode": .string(gpuCount == 1 ? "sequential" : "concurrent"),
                    "caption": .object(["gpus": .array([.int(0)])]),
                    "train": .object(["gpus": .array([.int(gpuCount == 1 ? 0 : 1)])]),
                ]
            } else {
                ["services": .array(services.map { .object(["name": .string($0.key), "state": .string($0.value)]) })]
            }
            return HTTPResponse(status: 200, body: JSONValue.object(reply).pythonDumpsData())
        }
        let json: String
        if url.path().contains("catalog/gpus") {
            json = #"{"gpus":[{"id":"test","name":"Test GPU","memory":80,"secure":true,"#
                + #""price":{"secure":1},"maxCount":{"secure":4},"#
                + #""dataCenters":[{"id":"EU-IS-1","availability":"HIGH"}]}]}"#
        } else if url.path().hasSuffix("network-volumes") {
            json = #"{"networkVolumes":[{"id":"test","name":"Test","size":100,"dataCenter":"EU-IS-1"}]}"#
        } else {
            if url.path().hasSuffix("action") {
                stopCalls += 1
                if !failedFirstStop {
                    failedFirstStop = true
                    return HTTPResponse(status: 503)
                }
                stopped = true
            }
            json = "{\"id\":\"test\",\"status\":\"\(stopped ? "EXITED" : "RUNNING")\",\"cost\":1,"
                + "\"gpu\":{\"count\":\(gpuCount)}}"
        }
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }
}

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
        let suite = "GPUWorkflowTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true, gpuCount: 2)
        let workspace = GPUWorkspace(
            demoMode: false, transport: transport, preferences: preferences, saveAgentToken: { _, _ in }
        )
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
        #expect(params["rank"]?.intValue == 16)
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
        let suite = "GPUWorkflowTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = SavedPod(
            pod: RentedPod(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 1)),
            started: Date().addingTimeInterval(-7200), hourlyRate: 1, budget: 1,
            trainer: "aitoolkit", runID: "previous-run", outputRepo: "test/model"
        )
        try preferences.set(JSONEncoder().encode(saved), forKey: "ConceptStudio.activePod")
        let transport = UnreachableAgentTransport()
        let workspace = GPUWorkspace(
            demoMode: false, transport: transport, preferences: preferences,
            readAgentToken: { _ in throw StudioError.message("Keychain unavailable") },
            saveAgentToken: { _, _ in }
        )
        #expect(throws: StudioError.self) {
            try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        }
        #expect(workspace.hasRunningPod)
        #expect(workspace.runID == "previous-run")
        for _ in 0 ..< 100 where workspace.hasRunningPod {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.pod?.status == "EXITED")
        #expect(await transport.stopCalls == 1)
    }

    @MainActor @Test(arguments: [true, false])
    func captionReadinessUsesItsOwnKeyAndCanBeCancelled(_ ready: Bool) async throws {
        let suite = "GPUWorkflowTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: ready)
        let workspace = GPUWorkspace(
            demoMode: false, transport: transport, preferences: preferences, saveAgentToken: { _, _ in }
        )
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
        let suite = "GPUWorkflowTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = GPUWorkspace(
            demoMode: false, transport: transport, preferences: preferences, saveAgentToken: { _, _ in }
        )
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
        let suite = "GPUWorkflowTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(failFirstStop: true)
        let workspace = GPUWorkspace(
            demoMode: false, transport: transport, preferences: preferences,
            saveAgentToken: { _, _ in throw StudioError.message("Keychain unavailable") }
        )
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        workspace.budget = 0.000000001
        await workspace.rent()
        for _ in 0 ..< 100 where workspace.hasRunningPod {
            try await Task.sleep(for: .milliseconds(10))
        }
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

    @Test
    func creationUsesV2GPUFieldsAndOnlyAuthenticatedPublishedPorts() async throws {
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
        _ = try await provider.create(PodCreation(
            offer: offer, count: 2, image: "own/image:verified",
            volume: GPUVolume(id: "volume", name: "Data", size: 100, dataCenter: "EU-IS-1"),
            agentToken: "agent-key", hubToken: "hub-key"
        ))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.runpod.io/v2/pods")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer runpod-key")
        let body = try JSONValue(parsing: #require(request.httpBody)).objectValue
        #expect(body?["gpu"]?.objectValue?["count"]?.intValue == 2)
        #expect(body?["gpu"]?.objectValue?["minCudaVersion"]?.stringValue == "13.0")
        #expect(body?["gpu"]?.objectValue?["minRamPerGpu"]?.intValue == 60)
        #expect(body?["ports"]?.arrayValue?.compactMap(\.stringValue) == ["8800/http", "8000/http"])
        #expect(body?["mounts"]?.objectValue?["network"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            == "/workspace")
        #expect(body?["env"]?.objectValue?["HF_TOKEN"]?.stringValue == "hub-key")
    }
}
