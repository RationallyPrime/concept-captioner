import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Saved GPU runs and generated results")
struct GPURunHistoryTests {
    @MainActor
    private func connected(_ folder: URL, preferences: UserDefaults, agent: HistoryAgent) -> GPUWorkspace {
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = folder
        workspace.pod = RentedPod(id: "offline-test", status: "RUNNING", cost: 1, gpu: .init(count: 2))
        workspace.saved = SavedPod(
            pod: workspace.pod!,
            started: Date(),
            hourlyRate: 1,
            budget: 10,
            trainer: "aitoolkit",
            runID: "",
            volumeID: "storage"
        )
        workspace.agent = agent
        workspace.hubToken = "fixture-hub"
        return workspace
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gpu-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fixtureRun(trainer: String = "aitoolkit", datasetRepo: String = "me/old-data") -> TrainingRun {
        var params: JSONObject = [
            "run_id": .string("saved-run"), "dataset": .object(["path": .string("/workspace/datasets/saved-run")]),
            "base_model": .string("black-forest-labs/FLUX.1-dev"), "steps": .int(200), "rank": .int(16),
            "learning_rate": .double(0.0001), "resolution": .int(512), "seed": .int(42),
            "triggers": .array([.string("NORA7")]), "profile": .string("flux-image"),
        ]
        if trainer == "ltx" {
            params["base_model"] = .string("Lightricks/LTX-2")
            params["profile"] = .string("ltx-video")
            params["extra"] = .object([
                "preprocess": .object(["resolution_buckets": .string("512x512x33;512x512x1")]),
            ])
        }
        return TrainingRun(
            runID: "saved-run", trainer: trainer, datasetRepo: datasetRepo, datasetRevision: "old-sha",
            datasetContainsVideo: trainer == "ltx", paramsJSON: JSONValue.object(params).pythonDumpsData(),
            volumeID: "storage",
            startedAt: Date(), updatedAt: Date(), result: TrainingResult(
                runID: "saved-run", outputRepo: "me/saved-model", destination: .hub, volumeID: "storage",
                state: .pushed(repo: "me/saved-model")
            ), points: [TrainingPoint(step: 200, loss: 0.1)],
            checkpoints: [RunFile(path: "saved-run/chosen.safetensors", size: 10, sha256: "synthetic")],
            hourlyRateUSD: 1, estimatedGPUCostUSD: 0.4, podSpendAtStart: 0
        )
    }

    @MainActor @Test
    func repeatedRunSurvivesFirstKeyLoadAndWarmNavigation() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let secrets = MemorySecretStore()
        let session = StudioSession(preferences: preferences, secrets: secrets)
        session.project = project
        session.projectState.datasetRevision = "different-current-sha"
        let run = fixtureRun(trainer: "ltx")
        session.gpu.runHistory = [run]
        session.gpu.repeatSettings(from: run)
        session.gpu.steps = 600
        session.gpu.rank = 8
        for _ in 0 ..< 2 {
            session.prepareGPUStep()
            #expect(session.gpu.repeatSourceRunID == run.runID)
            #expect(session.gpu.selectedHistoryRunID == run.runID)
            #expect(session.gpu.trainer == "ltx")
            #expect(session.gpu.profile == "ltx-video")
            #expect(session.gpu.baseModel == "Lightricks/LTX-2")
            #expect(session.gpu.triggerWords == "NORA7")
            #expect(session.gpu.seed == 42)
            #expect(session.gpu.steps == 600)
            #expect(session.gpu.rank == 8)
            #expect(session.gpu.learningRate == 0.0001)
            #expect(session.gpu.resolution == 512)
            #expect(session.gpu.datasetContainsVideo)
            #expect(session.gpu.datasetRevision == "old-sha")
        }
        #expect(secrets.readAccounts.count(where: { $0 == "runpod" }) == 1)
    }

    @MainActor @Test(arguments: [false, true])
    func currentDatasetSwitchRefreshesIncludedMediaAndPreservesEditedSettings(containsVideo: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(
            profile: containsVideo ? "ltx-video" : "flux-image",
            concepts: [Concept(trigger: "IVAN9", classNoun: "figure", targetConcept: .object)]
        )
        let clip = ProjectImage(url: project.imagesDirectory.appendingPathComponent("clip.mp4"))
        if containsVideo { project.images.append(clip) } else { project.excludedImages.append(clip) }
        let session = StudioSession(preferences: preferences, secrets: MemorySecretStore())
        session.project = project
        session.projectState.datasetRevision = "current-sha"
        let agent = HistoryAgent()
        session.gpu = makeWorkspace(GPUTransport(), preferences)
        session.gpu.projectFolder = project.directory
        session.gpu.hubToken = "fixture-hub"
        let previous = fixtureRun(trainer: containsVideo ? "aitoolkit" : "ltx")
        session.gpu.runHistory = [previous]
        session.gpu.repeatSettings(from: previous)
        session.gpu.trainer = "aitoolkit"
        session.gpu.baseModel = "custom/edited-model"
        session.gpu.steps = 400
        session.gpu.rank = 8
        session.gpu.learningRate = 0.0002
        session.gpu.resolution = 768
        session.gpu.seed = 314

        session.useCurrentTrainingDataset()

        #expect(session.gpu.repeatSourceRunID.isEmpty)
        #expect(session.gpu.datasetRevision == "current-sha")
        #expect(session.gpu.datasetContainsVideo == containsVideo)
        #expect(session.gpu.profile == project.job.profile)
        #expect(session.gpu.triggerWords == "IVAN9")
        #expect(session.gpu.trainer == "aitoolkit")
        #expect(session.gpu.baseModel == "custom/edited-model")
        #expect(session.gpu.steps == 400)
        #expect(session.gpu.rank == 8)
        #expect(session.gpu.learningRate == 0.0002)
        #expect(session.gpu.resolution == 768)
        #expect(session.gpu.seed == 314)
        session.gpu.pod = RentedPod(id: "offline-test", status: "RUNNING", cost: 1, gpu: .init(count: 2))
        session.gpu.selectedVolume = previous.volumeID
        session.gpu.agent = agent
        await session.gpu.train(datasetRepo: "me/current-data")
        if containsVideo {
            #expect(await agent.starts.isEmpty)
            #expect(session.gpu.message.contains("FLUX image training does not accept video clips"))
        } else {
            let starts = await agent.starts
            let pull = try #require(starts.first { $0.service == "pull-dataset" })
            #expect(pull.params["repo_id"] == .string("me/current-data"))
            #expect(pull.params["revision"] == .string("current-sha"))
            let train = try #require(starts.first { $0.service == "trainer-aitoolkit" })
            #expect(train.params["profile"] == .string("flux-image"))
            #expect(train.params["triggers"] == .array([.string("IVAN9")]))
            #expect(train.params["base_model"] == .string("custom/edited-model"))
            #expect(train.params["steps"] == .int(400))
            #expect(train.params["rank"] == .int(8))
            #expect(train.params["learning_rate"] == .double(0.0002))
            #expect(train.params["resolution"] == .int(768))
            #expect(train.params["seed"] == .int(314))
            #expect(train.params["extra"]?.objectValue?["training_seed"] == .int(314))
        }
    }

    @MainActor @Test
    func stoppedPodDoesNotAccumulateRunCost() throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = connected(folder, preferences: preferences, agent: HistoryAgent())
        var run = fixtureRun()
        run.result?.state = .training
        workspace.runHistory = [run]
        workspace.runID = run.runID
        workspace.result = run.result
        workspace.pod = RentedPod(id: "offline-test", status: "EXITED", cost: 1, gpu: .init(count: 2))
        workspace.captureRunProgress()
        #expect(workspace.runHistory[0].estimatedGPUCostUSD == 0.4)
    }

    @MainActor @Test
    func stoppedGlobalPodKeepsPendingOutputsWithoutImportingAnotherProjectsHistory() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = try temporaryFolder()
        let other = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: other)
        }
        let run = fixtureRun()
        let comparison = GeneratedComparison(
            runID: "generation-first", sourceRunID: run.runID, checkpoint: run.checkpoints[0].path,
            trainer: run.trainer, volumeID: run.volumeID, startedAt: Date(), state: .pending,
            folder: first.appendingPathComponent("results/generation-first").path, paramsJSON: Data("{}".utf8)
        )
        var record = try ProjectTrainingRecord(results: [#require(run.result)])
        record.runs = [run]
        record.comparisons = [comparison]
        try record.save(to: first)
        let saved = SavedPod(
            pod: RentedPod(id: "old-pod", status: "EXITED", cost: 1, gpu: .init(count: 1)),
            started: Date(), hourlyRate: 1, budget: 10, trainer: run.trainer,
            runID: run.runID, volumeID: run.volumeID,
            result: run.result, run: run, generation: comparison
        )
        try preferences.set(JSONEncoder().encode(saved), forKey: GPUWorkspace.activePodKey)
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = other
        try workspace.configure(runpodKey: "", hubToken: "", imageName: "offline")
        #expect(workspace.runHistory.isEmpty)
        #expect(workspace.generations.isEmpty)
        #expect(workspace.generation == comparison) // global custody remains available for reconnect/Stop
        workspace.saveProjectRecord()
        #expect(ProjectTrainingRecord.load(from: other) == ProjectTrainingRecord())
        await workspace.retrieveResult()
        #expect(workspace.message.contains("original project"))
        #expect(workspace.generation?.state == .pending)
        workspace.persist()
        let persisted = try #require(preferences.data(forKey: GPUWorkspace.activePodKey))
        #expect(try JSONDecoder().decode(SavedPod.self, from: persisted).generation?.state == .pending)
        workspace.projectFolder = first
        #expect(workspace.runHistory == [run])
        #expect(workspace.generations == [comparison])
        #expect(workspace.projectOwnsRun(run.runID))
    }

    @MainActor @Test
    func ltxGenerationUsesSelectedMotionLengthAndRefusesInvalidBucket() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        workspace.trainer = "ltx"
        let run = fixtureRun(trainer: "ltx")
        workspace.runHistory = [run]
        await workspace.generateComparison(
            run: run, checkpoint: run.checkpoints[0], prompts: ["NORA7 moves"], seeds: [42], videoFrames: 16
        )
        #expect(await agent.starts.isEmpty)
        await workspace.generateComparison(
            run: run, checkpoint: run.checkpoints[0], prompts: ["NORA7 moves"], seeds: [42], videoFrames: 129
        )
        let start = try #require(await agent.starts.first)
        #expect(start.service == "generate-ltx")
        #expect(start.params["num_frames"] == .int(129))
        #expect(start.params["frame_rate"] == .double(24))
    }

    @MainActor @Test
    func historyRoundTripRetainsRevisionSettingsResultsCostsAndCurves() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = ProjectTrainingRecord()
        record.runs = [fixtureRun()]
        try record.save(to: folder)
        let restored = ProjectTrainingRecord.load(from: folder)
        #expect(restored == record)
        #expect(restored.runs[0].params["rank"]?.intValue == 16)
        #expect(restored.runs[0].datasetRevision == "old-sha")
        #expect(restored.runs[0].estimatedGPUCostUSD == 0.4)
        #expect(restored.runs[0].latestStep == 200)
    }

    @MainActor @Test
    func repeatPinsSavedDatasetDespiteCurrentProjectRevisionAndUsesChangedSettings() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        let run = fixtureRun()
        workspace.runHistory = [run]
        workspace.repeatSettings(from: run)
        workspace.steps = 400
        workspace.rank = 8
        workspace.datasetRevision = "new-project-sha" // configureGPU refreshes current project metadata
        await workspace.train(datasetRepo: "me/current-data")
        let starts = await agent.starts
        let pull = try #require(starts.first { $0.service == "pull-dataset" })
        #expect(pull.params["repo_id"]?.stringValue == "me/old-data")
        #expect(pull.params["revision"]?.stringValue == "old-sha")
        #expect(pull.params["only_metadata"] == .bool(true))
        let train = try #require(starts.first { $0.service == "trainer-aitoolkit" })
        #expect(train.params["run_id"]?.stringValue != run.runID)
        #expect(train.params["rank"]?.intValue == 8)
        #expect(train.params["steps"]?.intValue == 400)
        #expect(workspace.runHistory.count == 2)
        #expect(workspace.runHistory.last?.datasetRevision == "resolved-revision")
        #expect(ProjectTrainingRecord.load(from: folder).runs.count == 2)
    }

    @MainActor @Test
    func repeatWithoutRecordedRevisionUsesLatestOfSavedRepo() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        var run = fixtureRun()
        run.datasetRevision = nil
        workspace.runHistory = [run]
        workspace.repeatSettings(from: run)
        workspace.datasetRevision = "other-project-revision"
        await workspace.train(datasetRepo: "me/current-data")
        let pull = try #require(await agent.starts.first { $0.service == "pull-dataset" })
        #expect(pull.params["repo_id"]?.stringValue == run.datasetRepo)
        #expect(pull.params["revision"] == nil)
    }

    @MainActor @Test
    func resumeContinuesSameRunWithoutRepullingDataset() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        let run = fixtureRun()
        workspace.runHistory = [run]
        await workspace.resumeRun(run, totalSteps: 400)
        let starts = await agent.starts
        #expect(starts.count == 1)
        #expect(starts[0].service == "trainer-aitoolkit")
        #expect(starts[0].gpus == [1])
        #expect(starts[0].params["resume"] == .bool(true))
        #expect(starts[0].params["run_id"]?.stringValue == "saved-run")
        #expect(starts[0].params["steps"]?.intValue == 400)
        #expect(starts[0].params["dataset"] == run.params["dataset"])
        #expect(workspace.runHistory.count == 1)
        #expect(workspace.runHistory[0].previousGPUCostUSD == 0.4)
    }

    @MainActor @Test
    func mismatchedStorageRefusesResumeBeforeServiceStart() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        workspace.saved?.volumeID = "different"
        await workspace.resumeRun(fixtureRun(), totalSteps: 400)
        #expect(await agent.starts.isEmpty)
        #expect(workspace.message.contains("saved storage"))
    }

    @MainActor @Test
    func videoTrainingRefusesFluxThenUsesExplicitLTXBucket() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        workspace.datasetContainsVideo = true
        await workspace.train(datasetRepo: "me/clips")
        #expect(await agent.starts.isEmpty)
        #expect(workspace.message.contains("LTX"))
        workspace.trainer = "ltx"
        await workspace.train(datasetRepo: "me/clips")
        let start = try #require(await agent.starts.last { $0.service == "trainer-ltx" })
        #expect(start.params["extra"]?.objectValue?["preprocess"]?.objectValue?["buckets_from_media"] == .bool(true))
        #expect(workspace.runHistory.last?.datasetContainsVideo == true)
    }

    @MainActor @Test
    func generationDownloadsMatchedManifestAndGuardsUnsavedOutputs() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        let run = fixtureRun()
        workspace.runHistory = [run]
        await workspace.generateComparison(
            run: run,
            checkpoint: run.checkpoints[0],
            prompts: ["NORA7 outdoors"],
            seeds: [42]
        )
        let start = try #require(await agent.starts.first)
        #expect(start.service == "generate-aitoolkit")
        #expect(start.gpus == [1])
        #expect(start.params["checkpoint"]?.stringValue == "saved-run/chosen.safetensors")
        workspace.generation?.state = .pending
        #expect(workspace.resultNeedsSaving)
        await workspace.stopEverything()
        #expect(workspace.hasRunningPod)
        let manifest = Data(#"""
        {"state":"complete","pairs":[{"prompt":"NORA7 outdoors","seed":42,
        "base_path":"base.png","lora_path":"lora.png"}]}
        """#.utf8)
        let outputs = [
            "comparison.json": manifest,
            "base.png": Data("synthetic base".utf8),
            "lora.png": Data("synthetic trained".utf8),
        ]
        await agent.serve(outputs, damaged: true)
        await workspace.retrieveResult()
        #expect(workspace.generation?.state == .pending)
        #expect(workspace.message.contains("checksum"))
        await agent.serve(outputs)
        await workspace.retrieveResult()
        let comparison = try #require(workspace.generation)
        #expect(comparison.state == .saved)
        #expect(!workspace.resultNeedsSaving)
        #expect(workspace.comparisonManifest(comparison)?.pairs.first?.seed == 42)
        #expect(workspace.comparisonFile("base.png", in: comparison) != nil)
        #expect(workspace.comparisonFile("../job.yaml", in: comparison) == nil)
        #expect(ProjectTrainingRecord.load(from: folder).comparisons.last?.state == .saved)
    }
}

extension GPURunHistoryTests {
    @MainActor @Test
    func selectedPublishedRunDownloadsWithoutReplacingAnotherPendingResultAndReopens() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        var selected = fixtureRun()
        selected.result?.state = .pushed(repo: "me/published-model")
        workspace.runHistory = [selected]
        workspace.runID = "current-other-run"
        let pending = TrainingResult(
            runID: workspace.runID, outputRepo: "", destination: .download, volumeID: "storage", state: .pending
        )
        workspace.result = pending
        let weights = Data("synthetic selected checkpoint".utf8)
        await agent.serve(["saved-run/final.safetensors": weights, "run.yaml": Data("synthetic config".utf8)])
        await workspace.downloadRun(selected)
        #expect(await agent.listedRunIDs == [selected.runID])
        #expect(await agent.downloadedRunIDs.allSatisfy { $0 == selected.runID })
        #expect(await agent.downloadedRunIDs.count == 2)
        #expect(workspace.runID == pending.runID)
        #expect(workspace.result == pending)
        #expect(workspace.resultNeedsSaving)
        let saved = try #require(workspace.runHistory.first?.localFolder)
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved)
                .appendingPathComponent("saved-run/final.safetensors")) == weights)
        #expect(workspace.runHistory.first?.result?.state == .pushed(repo: "me/published-model"))
        let reopened = makeWorkspace(GPUTransport(), preferences)
        reopened.projectFolder = folder
        #expect(reopened.runHistory.first?.localSavedFolder == saved)
        #expect(reopened.runHistory.first?.result?.state == .pushed(repo: "me/published-model"))
    }

    @MainActor @Test
    func selectedRunChecksumFailureDoesNotRecordALocalCopy() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        var selected = fixtureRun()
        selected.result?.state = .pushed(repo: "me/published-model")
        workspace.runHistory = [selected]
        workspace.saveProjectRecord()
        await agent.serve(["final.safetensors": Data("synthetic weights".utf8)], damaged: true)
        await workspace.downloadRun(selected)
        #expect(workspace.message.contains("checksum"))
        #expect(workspace.runHistory.first?.localFolder == nil)
        #expect(ProjectTrainingRecord.load(from: folder).runs.first?.localFolder == nil)
        #expect(workspace.runHistory.first?.result?.state == .pushed(repo: "me/published-model"))
    }

    @MainActor @Test
    func selectedRunRecordFailureDoesNotClaimPersistentLocalCopy() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        var selected = fixtureRun()
        selected.result?.state = .pushed(repo: "me/published-model")
        workspace.runHistory = [selected]
        // A directory at the record's exact file path forces the real atomic write to fail.
        try FileManager.default.createDirectory(
            at: ProjectTrainingRecord.url(in: folder), withIntermediateDirectories: true
        )
        await agent.serve(["final.safetensors": Data("synthetic weights".utf8)])
        await workspace.downloadRun(selected)
        #expect(workspace.message.contains("Could not record"))
        #expect(workspace.runHistory.first?.localFolder == nil)
        #expect(workspace.runHistory.first?.result?.state == .pushed(repo: "me/published-model"))
    }

    @MainActor @Test
    func selectedRunDownloadRejectsOtherProjectsAndMismatchedStorageBeforeListingFiles() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        let selected = fixtureRun()
        #expect(selected.localSavedFolder == nil)
        await workspace.downloadRun(selected)
        #expect(workspace.message.contains("original project"))
        #expect(await agent.listedRunIDs.isEmpty)
        workspace.runHistory = [selected]
        workspace.saved?.volumeID = "other-storage"
        await workspace.downloadRun(selected)
        #expect(workspace.message.contains("saved storage"))
        #expect(await agent.listedRunIDs.isEmpty)
    }
}

extension GPURunHistoryTests {
    @MainActor @Test
    func repeatOfADirectUploadRunTrainsOnTheProjectsPublishedDataset() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = HistoryAgent()
        let workspace = connected(folder, preferences: preferences, agent: agent)
        let run = fixtureRun(datasetRepo: "") // recorded by a direct upload: settings only
        workspace.runHistory = [run]
        workspace.repeatSettings(from: run)
        workspace.datasetRevision = "project-sha"
        await workspace.train(datasetRepo: "me/current-data")
        let pull = try #require(await agent.starts.first { $0.service == "pull-dataset" })
        #expect(pull.params["repo_id"]?.stringValue == "me/current-data")
        #expect(pull.params["revision"]?.stringValue == "project-sha")
    }
}
