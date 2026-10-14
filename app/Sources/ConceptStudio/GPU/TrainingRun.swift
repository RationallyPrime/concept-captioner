import ConceptCore
import Foundation

/// A project-local run snapshot. The parameters sent to the trainer remain the source of
/// settings for Repeat and Resume; no keys or pod credentials enter this file.
struct TrainingRun: Codable, Equatable, Identifiable {
    var id: String {
        runID
    }

    let runID: String
    let trainer: String
    let datasetRepo: String
    var datasetRevision: String?
    var datasetContainsVideo: Bool
    var localInputDigest: String?
    /// Training images and clips the run started with; epoch rows convert steps with it on Repeat.
    var itemCount: Int?
    var paramsJSON: Data
    var params: JSONObject {
        get { (try? JSONValue(parsing: paramsJSON).objectValue) ?? [:] }
        set { paramsJSON = JSONValue.object(newValue).pythonDumpsData() }
    }

    let volumeID: String
    let startedAt: Date
    var updatedAt: Date
    var result: TrainingResult?
    var points: [TrainingPoint] = []
    var checkpoints: [RunFile] = []
    var hourlyRateUSD: Double?
    var estimatedGPUCostUSD: Double?
    /// The selected cap belongs to this run, including its later Resume continuations.
    var gpuBudgetUSD: Double?
    /// A separately downloaded copy does not change a run's published Hub status.
    var localFolder: String?
    var previousGPUCostUSD = 0.0
    /// The running pod's accumulated estimate at the start of this run/continuation.
    var podSpendAtStart: Double

    var datasetDescription: String {
        localInputDigest == nil ? datasetRepo : "Direct project upload"
    }

    var baseModel: String {
        params["base_model"]?.stringValue ?? ""
    }

    var targetSteps: Int {
        params["steps"]?.intValue ?? 0
    }

    var rank: Int {
        params["rank"]?.intValue ?? 0
    }

    var latestStep: Int {
        points.last?.step ?? 0
    }

    var localSavedFolder: String? {
        if let localFolder { return localFolder }
        if case let .saved(folder) = result?.state { return folder }
        return nil
    }

    var hasFinishedModel: Bool {
        switch result?.state {
        case .pending, .pushed, .saved: true
        default: false
        }
    }

    /// The table's row for this run's trainer and base model, if it has one (a custom model has none).
    func modelRow(in table: ModelTable = .shared) -> ModelRow? {
        table.exact(trainer: trainer, baseModel: baseModel)
    }

    /// The row whose defaults and capabilities apply to this run: the exact row, else the trainer's default.
    func effectiveModelRow(in table: ModelTable = .shared) -> ModelRow {
        table.effective(trainer: trainer, baseModel: baseModel)
    }

    /// Whether comparison generation can run this run's checkpoints: its exact row names a generator.
    func supportsGeneration(in table: ModelTable) -> Bool {
        modelRow(in: table)?.hooks.generator != nil
    }

    /// Whether comparisons of this run are clips rather than images.
    func generatesVideo(in table: ModelTable) -> Bool {
        effectiveModelRow(in: table).preview.video != nil
    }

    /// The frame count a comparison starts with. A model without preview clips generates one frame.
    func defaultGenerationFrames(in table: ModelTable) -> Int {
        effectiveModelRow(in: table).preview.video?.defaultFrames ?? 1
    }

    /// The rate comparison clips are generated at: the model's fixed rate, else 24 fps.
    func generationFrameRate(in table: ModelTable) -> Int {
        effectiveModelRow(in: table).video?.fixedFPS ?? Self.defaultGenerationFrameRate
    }

    static let defaultGenerationFrameRate = 24

    var supportsGeneration: Bool {
        supportsGeneration(in: .shared)
    }

    var isH3: Bool {
        modelRow()?.hooks.nativeRecipe == .minimaxH3
    }

    var generatesVideo: Bool {
        generatesVideo(in: .shared)
    }

    var defaultGenerationFrames: Int {
        defaultGenerationFrames(in: .shared)
    }

    var generationFrameRate: Int {
        generationFrameRate(in: .shared)
    }

    var generationFrameChoices: [Int] {
        effectiveModelRow().preview.video?.choices ?? []
    }
}

struct GeneratedComparison: Codable, Equatable, Identifiable {
    enum State: String, Codable { case generating, pending, saved, failed }
    var id: String {
        runID
    }

    let runID: String
    let sourceRunID: String
    let checkpoint: String
    let trainer: String
    let volumeID: String
    let startedAt: Date
    var state: State
    var folder: String?
    var failure: String?
    let paramsJSON: Data
    var params: JSONObject {
        (try? JSONValue(parsing: paramsJSON).objectValue) ?? [:]
    }

    var summary: String {
        switch state {
        case .generating: "Generating base and LoRA outputs"
        case .pending: "Outputs need downloading"
        case .saved: "Comparison saved in this project"
        case .failed: failure ?? "Generation did not finish; inspect the run log"
        }
    }
}

/// Written by the real inference wrapper. A row is displayed only when its downloaded file
/// exists; an empty history never substitutes demonstration images for trained results.
struct ComparisonPair: Decodable, Identifiable {
    var id: String {
        basePath
    }

    let prompt: String
    let seed: Int
    let basePath: String
    let loraPath: String
    enum CodingKeys: String, CodingKey {
        case prompt, seed
        case basePath = "base_path"
        case loraPath = "lora_path"
    }
}

struct ComparisonManifest: Decodable {
    let state: String
    let pairs: [ComparisonPair]
}

extension GPUWorkspace {
    func recordNewTrainingRun(
        _ agent: any PodAgent, datasetRepo: String, params: JSONObject, localInputDigest: String?
    ) async {
        if let index = runHistory.firstIndex(where: { $0.runID == runID }) {
            runHistory[index].params = params
        }
        if let info = try? await agent.runConfiguration(runID: runID),
           let index = runHistory.firstIndex(where: { $0.runID == runID }) {
            if !info.config.isEmpty { runHistory[index].params = info.config }
            if localInputDigest == nil {
                runHistory[index].datasetRevision = info.dataset["revision"]?.stringValue
                    ?? runHistory[index].datasetRevision
            }
        }
        saveProjectRecord()
    }

    func recordStartedRun(
        datasetRepo: String,
        params: JSONObject,
        resumed: Bool,
        localInputDigest: String? = nil,
        itemCount: Int? = nil,
        budget: Double? = nil,
        baseline: Double? = nil
    ) {
        let now = Date()
        if resumed, let index = runHistory.firstIndex(where: { $0.runID == runID }) {
            runHistory[index].params = params
            runHistory[index].result = result
            runHistory[index].updatedAt = now
            runHistory[index].previousGPUCostUSD = runHistory[index].estimatedGPUCostUSD ?? 0
            runHistory[index].podSpendAtStart = baseline ?? estimatedPodCost
            if let budget { runHistory[index].gpuBudgetUSD = budget }
            runHistory[index].hourlyRateUSD = saved?.hourlyRate
        } else {
            runHistory.append(TrainingRun(
                runID: runID, trainer: trainer, datasetRepo: datasetRepo,
                datasetRevision: datasetRevision.isEmpty ? nil : datasetRevision,
                datasetContainsVideo: datasetContainsVideo, localInputDigest: localInputDigest, itemCount: itemCount,
                paramsJSON: JSONValue.object(params).pythonDumpsData(),
                volumeID: currentVolumeID, startedAt: now, updatedAt: now, result: result,
                hourlyRateUSD: saved?.hourlyRate, estimatedGPUCostUSD: nil, gpuBudgetUSD: budget,
                podSpendAtStart: baseline ?? estimatedPodCost
            ))
        }
        selectedHistoryRunID = runID
        saveProjectRecord()
    }

    func captureRunProgress() {
        guard let index = runHistory.firstIndex(where: { $0.runID == runID }) else {
            // Global billing remains accurate while Welcome or a different project is open.
            if var run = saved?.run, run.runID == runID, run.result?.state == .training {
                if hasRunningPod { run.estimatedGPUCostUSD = currentRunCost(run, podCost: estimatedPodCost) }
                run.result = result
                run.points = points
                run.updatedAt = Date()
                saved?.run = run
            }
            return
        }
        let ending = runHistory[index].result?.state == .training
        runHistory[index].points = points
        runHistory[index].result = result
        runHistory[index].updatedAt = Date()
        if saved != nil, hasRunningPod, result?.state == .training || ending {
            runHistory[index].estimatedGPUCostUSD = currentRunCost(runHistory[index], podCost: estimatedPodCost)
        }
    }

    var estimatedPodCost: Double {
        guard let saved else { return 0 }
        return saved.accruedGPUCostUSD
            + (hasRunningPod ? max(0, Date().timeIntervalSince(saved.started)) / 3600 * saved.hourlyRate : 0)
    }

    func refreshRunFiles(_ id: String) async {
        await perform {
            guard let run = self.runHistory.first(where: { $0.runID == id }), let agent = self.agent,
                  self.hasRunningPod, run.volumeID == self.currentVolumeID else {
                throw StudioError.message("Connect a computer to this run's saved storage to list its checkpoints.")
            }
            let files = try await agent.runFiles(runID: id)
            if let index = self.runHistory.firstIndex(where: { $0.runID == id }) {
                self.runHistory[index].checkpoints = files.filter { $0.path.hasSuffix(".safetensors") }
                if let info = try? await agent.runConfiguration(runID: id) {
                    self.runHistory[index].datasetRevision = info.dataset["revision"]?.stringValue
                        ?? self.runHistory[index].datasetRevision
                }
            }
            self.saveProjectRecord()
            self.message = "Checkpoint list refreshed from saved storage."
        }
    }

    /// The run selected for Repeat when it recorded a published dataset: the dataset the repeat trains on. A
    /// direct-upload run supplies settings only, so its repeat trains on this project's own inputs.
    var publishedRepeatRun: TrainingRun? {
        runHistory.first { $0.runID == repeatSourceRunID && !$0.datasetRepo.isEmpty }
    }

    /// Prefills editable settings; it never starts billing or submits training.
    func repeatSettings(from run: TrainingRun) {
        guard !isBusy,
              !isTraining else { message = "Finish the active action before selecting saved settings."; return }
        if hasRunningPod, trainer != run.trainer {
            message = "This computer has the other trainer image. Stop it and choose \(run.trainer) to repeat this run."
            return
        }
        trainer = run.trainer
        baseModel = run.baseModel
        let row = run.effectiveModelRow(in: modelTable)
        rank = run.rank
        alpha = run.params["alpha"]?.intValue ?? rank
        batchSize = run.params["batch_size"]?.intValue ?? 1
        accumulation = run.params["gradient_accumulation"]?.intValue ?? 1
        steps = lengthToRepeat(run, row: row)
        restoreTrainingAids(from: run)
        nativeRecipe = nil
        nativeRecipeOriginal = nil
        initialCheckpoint = nil
        learningRate = run.params["learning_rate"]?.doubleValue ?? learningRate
        if let values = run.params["resolution"]?.arrayValue?.compactMap(\.intValue) {
            trainingResolutions = values
        } else if let value = run.params["resolution"]?.intValue { trainingResolutions = [value] }
        checkpointEvery = run.params["save_every"]?.intValue ?? row.recipe.checkpoints.every
        let save = run.params["extra"]?.objectValue?["save"]?.objectValue ?? [:]
        checkpointRetention = save["max_step_saves_to_keep"]?.intValue ?? row.recipe.checkpoints.keep
        checkpointPrecision = save["dtype"]?.stringValue ?? modelTable.checkpointPrecision(for: row)
        if let hook = run.modelRow(in: modelTable)?.hooks.nativeRecipe {
            let train = run.params["extra"]?.objectValue?["train"]?.objectValue ?? [:]
            guidanceLoss = train["do_guidance_loss"]?.boolValue ?? false
            guidanceTargetText = String(
                data: (train["guidance_loss_target"] ?? .double(3.5)).pythonDumpsData(), encoding: .utf8
            ) ?? hook.defaultGuidanceTarget
        } else {
            guidanceLoss = false
            guidanceTargetText = Self.defaultGuidanceTarget
        }
        triggerWords = run.params["triggers"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ",") ?? ""
        profile = run.params["profile"]?.stringValue ?? modelTable.defaultRow.captions.imageProfile
        seed = run.params["seed"]?.intValue ?? 42
        if let cap = run.gpuBudgetUSD { runBudget = cap }
        datasetContainsVideo = run.datasetContainsVideo
        datasetRevision = run.datasetRevision ?? ""
        repeatSourceRunID = run.runID
        selectedHistoryRunID = run.runID
        message = "Saved settings loaded. Change them in Training, then start a new run. "
            + "Dataset: \(run.datasetDescription)."
    }

    /// A saved run holds optimizer steps. A model that counts epochs shows them as passes over the items
    /// that run trained on (recorded since the model table; older runs fall back to the current items).
    /// A run with regularisation images spent every other step on them, so only half its steps were passes over the
    /// person's own images.
    private func lengthToRepeat(_ run: TrainingRun, row: ModelRow) -> Int {
        let items = run.itemCount ?? datasetItemCount
        guard row.recipe.lengthUnit == .epochs, items > 0 else { return run.targetSteps }
        let perStep = Double(max(1, batchSize * accumulation))
        let ownSteps = run.params["regularization"]?.objectValue == nil ? run.targetSteps : run.targetSteps / 2
        return max(1, Int((Double(ownSteps) * perStep / Double(items)).rounded()))
    }

    func resumeRun(
        _ run: TrainingRun, totalSteps: Int, captureLocal: (@MainActor () async throws -> LocalTrainingDataset)? = nil
    ) async {
        await perform {
            guard let agent = self.agent, self.hasRunningPod, self.trainer == run.trainer,
                  self.currentVolumeID == run.volumeID else {
                throw StudioError.message("Resume needs the same trainer and this run's saved storage.")
            }
            try Self.validateH3Guidance(run, table: self.modelTable)
            guard totalSteps > run.latestStep, !self.resultNeedsSaving else {
                throw StudioError.message("Retrieve pending outputs first, then choose a total above the latest step.")
            }
            let cap = run.gpuBudgetUSD ?? self.runBudget
            guard cap.isFinite, cap > (run.estimatedGPUCostUSD ?? 0) else {
                throw StudioError.message("This run has reached its budget. Raise its budget before continuing.")
            }
            let baseline = self.estimatedPodCost
            let local: LocalTrainingDataset?
            if let expected = run.localInputDigest {
                guard let folder = self.projectFolder
                else { throw StudioError.message("Open this run's project first.") }
                let prepared: LocalTrainingDataset = if let captureLocal { try await captureLocal() } else {
                    try await LocalTrainingDataset.prepare(projectFolder: folder)
                }
                guard prepared.digest == expected else {
                    prepared.remove()
                    throw StudioError.message("The included media, saved captions or job have changed since this run. "
                        + "Resume needs the original inputs. Load settings for repeat to start a new run instead.")
                }
                local = prepared
            } else { local = nil }
            defer { local?.remove() }
            let services = try await agent.services()
            guard !services.contains(where: { $0.active && ($0.name.hasPrefix("trainer-")
                    || $0.name.hasPrefix("generate-")) }) else {
                throw StudioError.message("Finish the current GPU action before resuming training.")
            }
            let plan = try await agent.plan()
            if let row = run.modelRow(in: self.modelTable), row.gpu.verifyOnPod {
                try await self.verifyGPUMemory(agent, gpus: plan.train?.gpus ?? [], row: row)
            }
            var params = run.params
            params["steps"] = .int(totalSteps)
            params["resume"] = .bool(true)
            self.runID = run.runID
            self.points = run.points
            self.result = run.result
            self.result?.state = .training
            self.trainingState = "Preparing inputs"
            self.recordStartedRun(
                datasetRepo: run.datasetRepo,
                params: params,
                resumed: true,
                budget: cap,
                baseline: baseline
            )
            self.persist()
            self.persistResult()
            var trainerStartAttempted = false
            defer { if !trainerStartAttempted { self.finishFailedPreparation(previousResult: run.result) } }
            if let local {
                try await self.installTrainingDataset(local, repo: "", revision: nil, name: run.runID, agent: agent)
            }
            try await self.prepareCaptionServerForTraining(agent, plan: plan)
            try Task.checkCancellation()
            try self.checkCurrentRunBudget()
            trainerStartAttempted = true
            try await agent.start("trainer-\(run.trainer)", gpus: plan.train?.gpus ?? [], params: params)
            self.trainingState = "running"
            self.lastActivity = Date()
            await self.recordNewTrainingRun(
                agent,
                datasetRepo: run.datasetRepo,
                params: params,
                localInputDigest: run.localInputDigest
            )
            self.persist()
            self.persistResult()
            self.message = "Continuing run \(run.runID) toward \(totalSteps) total steps from its latest checkpoint."
        }
    }
}
