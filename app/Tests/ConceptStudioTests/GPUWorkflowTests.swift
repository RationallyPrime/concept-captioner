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
    private(set) var stopCalls = 0
    private(set) var inferenceRequests: [URLRequest] = []

    init(failFirstStop: Bool = false, agentAvailable: Bool = false, inferenceReady: Bool = false) {
        failedFirstStop = !failFirstStop
        self.agentAvailable = agentAvailable
        self.inferenceReady = inferenceReady
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        if url.host()?.contains("-8000.") == true {
            inferenceRequests.append(request)
            return HTTPResponse(
                status: inferenceReady ? 200 : 503,
                body: Data(#"{"data":[{"id":"Qwen/Qwen3-VL-8B-Instruct"}]}"#.utf8)
            )
        }
        if url.host() != "api.runpod.io" {
            guard agentAvailable else { return HTTPResponse(status: 522) }
            let reply = url.path().hasSuffix("plan")
                ? #"{"mode":"sequential","caption":{"gpus":[0]},"train":{"gpus":[0]}}"#
                : #"{"services":[]}"#
            return HTTPResponse(status: 200, body: Data(reply.utf8))
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
            json = "{\"id\":\"test\",\"status\":\"\(stopped ? "EXITED" : "RUNNING")\",\"cost\":1,\"gpu\":{\"count\":1}}"
        }
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }
}

@Suite("GPU workflow")
struct GPUWorkflowTests {
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
        #expect(body?["ports"]?.arrayValue?.compactMap(\.stringValue) == ["8800/http", "8000/http"])
        #expect(body?["mounts"]?.objectValue?["network"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            == "/workspace")
        #expect(body?["env"]?.objectValue?["HF_TOKEN"]?.stringValue == "hub-key")
    }
}
