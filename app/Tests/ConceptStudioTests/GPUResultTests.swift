// The trained result's path off the pod (push or verified download), launch reconciliation and
// keep-awake. Split from GPUWorkflowTests.swift for SwiftLint's file length cap.

import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

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
        workspace.resolution = 1024
        workspace.samplesEnabled = true
        await workspace.refreshOffers()
        await workspace.rent()
        await workspace.train(
            datasetRepo: "test/images", output: HubDestination(repo: "me/lora", isPrivate: privateResult)
        )
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
        let downloader = FakeDownloader([:])
        let workspace = makeWorkspace(transport, preferences, downloader: downloader)
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        workspace.projectFolder = project
        await workspace.refreshOffers()
        await workspace.rent()
        let inputProject = try await captionedUploadProject(at: workspace.projectFolder)
        workspace.projectFolder = inputProject.directory
        defer { try? FileManager.default.removeItem(at: inputProject.directory) }
        await workspace.train(datasetRepo: "test/images", output: HubDestination(repo: "me/lora"))
        #expect(try await trainerParams(transport, "aitoolkit")["hub"] == nil)
        let runID = workspace.runID
        // What ai-toolkit leaves in output/<run-id>/ (config.name = run id), as the agent lists it.
        let final = "\(runID)/\(runID).safetensors"
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        await transport.files([
            RunFile(
                path: "\(runID)/\(runID)_000000100.safetensors",
                size: 3,
                sha256: sha256(Data("old".utf8)),
                modifiedAt: started
            ),
            RunFile(path: final, size: weights.count, sha256: sha256(weights), modifiedAt: started + 60),
            RunFile(path: "\(runID)/config.yaml", size: config.count, sha256: sha256(config), modifiedAt: started),
        ])
        await downloader.serve(["\(runID).safetensors": weights, "config.yaml": config])
        await transport.finish("trainer-aitoolkit", state: "exited")
        await workspace.refresh()
        try await waitUntil { if case .saved = workspace.result?.state { true } else { false } }
        let folder = project.appendingPathComponent("results/\(runID)")
        #expect(workspace.result?.state == .saved(folder: folder.path))
        #expect(try Data(contentsOf: folder.appendingPathComponent(final)) == weights)
        #expect(try Data(contentsOf: folder.appendingPathComponent("\(runID)/config.yaml")) == config)
        let requests = await downloader.requests
        #expect(requests.map { $0.url?.path() ?? "" }.sorted() == [
            "/runs/\(runID)/files/\(runID)/\(runID).safetensors", "/runs/\(runID)/files/\(runID)/config.yaml",
        ].sorted())
        #expect(requests
            .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + workspace.agentToken })
        let record = ProjectTrainingRecord.load(from: project)
        #expect(record.results.last?.state == .saved(folder: folder.path))
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
    }

    @MainActor @Test
    func signedInWithoutARepoPushesPrivatelyToTheAccount() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        await transport.signIn("tester")
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-write", imageName: "test")
        workspace.projectFolder = FileManager.default.temporaryDirectory.appendingPathComponent("My Nora!")
        await workspace.refreshOffers()
        await workspace.rent()
        let suggested = await workspace.suggestedOutputRepo()
        #expect(suggested == "tester/my-nora-lora")
        await workspace.train(datasetRepo: "test/images", output: HubDestination(repo: suggested ?? ""))
        #expect(workspace.result?.destination == .hub)
        #expect(try await trainerParams(transport, "aitoolkit")["hub"] == .object([
            "repo_id": .string("tester/my-nora-lora"), "private": .bool(true), "push_on_finish": .bool(true),
        ]))
        #expect(GPUWorkspace.repoName(project: "") == "concept-lora")
        #expect(GPUWorkspace.repoName(project: "--a..b  c__") == "a.b-c-lora")
        await workspace.stopEverything()
    }

    @MainActor @Test
    func anUnsettledRunHoldsIdleStopWhileTheAgentAnswers() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        await transport.failFiles(true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        let inputProject = try await captionedUploadProject(at: workspace.projectFolder)
        workspace.projectFolder = inputProject.directory
        defer { try? FileManager.default.removeItem(at: inputProject.directory) }
        await workspace.train(datasetRepo: "test/images")
        await transport.finish("trainer-aitoolkit", state: "exited")
        workspace.idleMinutes = 0
        await workspace.refresh()
        #expect(workspace.result?.state == .training)
        #expect(workspace.hasRunningPod)
        await workspace.stopEverything()
        #expect(!workspace.hasRunningPod)
    }

    @MainActor @Test
    func theAppsOwnWorkForTheComputerIsNotIdleTime() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.idleMinutes = 0
        workspace.beginAppWork() // publishing the dataset this computer is waiting for
        for _ in 0 ..< 5 {
            await workspace.refresh()
        }
        #expect(workspace.hasRunningPod)
        workspace.endAppWork()
        for _ in 0 ..< 100 where workspace.hasRunningPod {
            try await Task.sleep(for: .milliseconds(10))
            await workspace.refresh()
        }
        #expect(workspace.pod?.status == "EXITED")
    }

    @MainActor @Test
    func aRunWithoutEventsYetIsNotAnErrorAndAResolvedErrorClears() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        let inputProject = try await captionedUploadProject(at: workspace.projectFolder)
        workspace.projectFolder = inputProject.directory
        defer { try? FileManager.default.removeItem(at: inputProject.directory) }
        await workspace.train(datasetRepo: "test/images")
        await transport.runEventsMissing(true)
        await workspace.refresh()
        #expect(!workspace.message.contains("could not complete"))
        await transport.agentReachable(false)
        await workspace.refresh()
        #expect(workspace.message.contains("unreachable"))
        await transport.agentReachable(true)
        await workspace.refresh()
        #expect(workspace.message.isEmpty)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func aPendingResultOnOtherStorageDoesNotBlockTraining() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let elsewhere = TrainingResult(
            runID: "concept-elsewhere", outputRepo: "", destination: .download, volumeID: "other", state: .pending
        )
        try preferences.set(JSONEncoder().encode(elsewhere), forKey: GPUWorkspace.pendingResultKey)
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        #expect(workspace.result?.runID == "concept-elsewhere")
        await workspace.refreshOffers()
        await workspace.rent()
        #expect(!workspace.resultNeedsSaving)
        let inputProject = try await captionedUploadProject(at: workspace.projectFolder)
        workspace.projectFolder = inputProject.directory
        defer { try? FileManager.default.removeItem(at: inputProject.directory) }
        await workspace.train(datasetRepo: "test/images")
        #expect(workspace.result?.state == .training)
        #expect(workspace.result?.runID == workspace.runID)
        await workspace.stopEverything()
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
        let inputProject = try await captionedUploadProject(at: workspace.projectFolder)
        workspace.projectFolder = inputProject.directory
        defer { try? FileManager.default.removeItem(at: inputProject.directory) }
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
            started: Date(), hourlyRate: 1, budget: 100, trainer: "aitoolkit", runID: "previous-run"
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
        // TensorBoard was down (agent restarted), so the full curve's source is started again.
        #expect(paths.contains("/services/tensorboard/start"))
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
            RunFile(path: "b.safetensors", size: 1, sha256: "", modifiedAt: Date(timeIntervalSince1970: 2)),
            RunFile(path: "a.safetensors", size: 1, sha256: "", modifiedAt: Date(timeIntervalSince1970: 3)),
        ]
        #expect(RunArtifacts.newest(timed)?.path == "a.safetensors")
        #expect(RunArtifacts.selection([RunFile(path: "run.json", size: 1, sha256: "")]).isEmpty)
    }

    /// Run ids are `concept-` plus a UUID prefix, so about a quarter end in three decimal digits.
    @Test
    func theFinalLoRAWinsWhenTheRunIDEndsInDigits() throws {
        let run = "concept-1a2b3c4d-567"
        let listing = Data("""
        {"run_id": "\(run)", "root": "/workspace/runs/\(run)/output", "files": [
          {"path": "\(run)/\(run).safetensors", "size": 1, "sha256": "a", "modified_at": "2026-10-11T12:30:00Z"},
          {"path": "\(run)/\(run)_000001750.safetensors", "size": 1, "sha256": "b",
           "modified_at": "2026-10-11T12:29:00Z"},
          {"path": "\(run)/\(run)_000001500.safetensors", "size": 1, "sha256": "c",
           "modified_at": "2026-10-11T12:30:00Z"}
        ]}
        """.utf8)
        struct Listing: Decodable { let files: [RunFile] }
        let files = try JSONDecoder().decode(Listing.self, from: listing).files
        #expect(files.allSatisfy { $0.modifiedAt != nil })
        // Newest by time; the tie at 12:30:00 goes to the un-numbered final file.
        #expect(RunArtifacts.newest(files)?.path == "\(run)/\(run).safetensors")
        // Without times, `-567` is part of the name, not a step number.
        let untimed = files.map { RunFile(path: $0.path, size: $0.size, sha256: $0.sha256) }
        #expect(RunArtifacts.newest(untimed)?.path == "\(run)/\(run).safetensors")
        let checkpoints = untimed.filter { $0.path.contains("_0000") }
        #expect(RunArtifacts.newest(checkpoints)?.path == "\(run)/\(run)_000001750.safetensors")
    }

    @MainActor @Test
    func launchListingSkipsOtherPodsAndReportsFailures() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        await transport.list([
            #"{"id":"cpu","name":"notebook","status":"RUNNING","cost":0.1}"#,
            #"{"id":"test","name":"ConceptStudio-alpha","status":"RUNNING","cost":1.5,"gpu":{"count":1}}"#,
        ])
        let found = try await RunPodProvider(key: "test", transport: transport).list()
        #expect(found.map(\.id) == ["test"])
        await transport.failList(true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "test", hubToken: "", imageName: "test")
        try await waitUntil { workspace.failure != nil }
        #expect(workspace.failure?.contains("RunPod console") == true)
        #expect(workspace.message == workspace.failure)
        #expect(workspace.pod == nil)
    }
}
