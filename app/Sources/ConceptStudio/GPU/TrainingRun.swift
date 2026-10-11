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
    /// A separately downloaded copy does not change a run's published Hub status.
    var localFolder: String?
    var previousGPUCostUSD = 0.0
    /// The running pod's accumulated estimate at the start of this run/continuation.
    var podSpendAtStart: Double

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

    var supportsGeneration: Bool {
        (trainer == "aitoolkit" && baseModel == "black-forest-labs/FLUX.1-dev")
            || (trainer == "ltx" && baseModel == "Lightricks/LTX-2")
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
    func recordStartedRun(datasetRepo: String, params: JSONObject, resumed: Bool) {
        let now = Date()
        if resumed, let index = runHistory.firstIndex(where: { $0.runID == runID }) {
            runHistory[index].params = params
            runHistory[index].result = result
            runHistory[index].updatedAt = now
            runHistory[index].previousGPUCostUSD = runHistory[index].estimatedGPUCostUSD ?? 0
            runHistory[index].podSpendAtStart = estimatedPodCost
            runHistory[index].hourlyRateUSD = saved?.hourlyRate
        } else {
            runHistory.append(TrainingRun(
                runID: runID, trainer: trainer, datasetRepo: datasetRepo,
                datasetRevision: datasetRevision.isEmpty ? nil : datasetRevision,
                datasetContainsVideo: datasetContainsVideo,
                paramsJSON: JSONValue.object(params).pythonDumpsData(),
                volumeID: currentVolumeID, startedAt: now, updatedAt: now, result: result,
                hourlyRateUSD: saved?.hourlyRate, estimatedGPUCostUSD: nil, podSpendAtStart: estimatedPodCost
            ))
        }
        selectedHistoryRunID = runID
        saveProjectRecord()
    }

    func captureRunProgress() {
        guard let index = runHistory.firstIndex(where: { $0.runID == runID }) else { return }
        let ending = runHistory[index].result?.state == .training
        runHistory[index].points = points
        runHistory[index].result = result
        runHistory[index].updatedAt = Date()
        if saved != nil, hasRunningPod, result?.state == .training || ending {
            runHistory[index].estimatedGPUCostUSD = runHistory[index].previousGPUCostUSD
                + max(0, estimatedPodCost - runHistory[index].podSpendAtStart)
        }
    }

    var estimatedPodCost: Double {
        guard let saved else { return 0 }
        return max(0, Date().timeIntervalSince(saved.started)) / 3600 * saved.hourlyRate
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
        steps = run.targetSteps
        rank = run.rank
        learningRate = run.params["learning_rate"]?.doubleValue ?? learningRate
        resolution = run.params["resolution"]?.intValue ?? resolution
        triggerWords = run.params["triggers"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ",") ?? ""
        profile = run.params["profile"]?.stringValue ?? "flux-image"
        seed = run.params["seed"]?.intValue ?? 42
        datasetContainsVideo = run.datasetContainsVideo
        datasetRevision = run.datasetRevision ?? ""
        repeatSourceRunID = run.runID
        selectedHistoryRunID = run.runID
        message = "Saved settings loaded. Change them in Training, then start a new run. Dataset: \(run.datasetRepo)."
    }

    func resumeRun(_ run: TrainingRun, totalSteps: Int) async {
        await perform {
            guard let agent = self.agent, self.hasRunningPod, self.trainer == run.trainer,
                  self.currentVolumeID == run.volumeID else {
                throw StudioError.message("Resume needs the same trainer and this run's saved storage.")
            }
            guard totalSteps > run.latestStep, !self.resultNeedsSaving else {
                throw StudioError.message("Retrieve pending outputs first, then choose a total above the latest step.")
            }
            let services = try await agent.services()
            guard !services.contains(where: { $0.active && ($0.name.hasPrefix("trainer-")
                    || $0.name.hasPrefix("generate-")) }) else {
                throw StudioError.message("Finish the current GPU action before resuming training.")
            }
            let plan = try await agent.plan()
            try await self.prepareCaptionServerForTraining(agent, plan: plan)
            var params = run.params
            params["steps"] = .int(totalSteps)
            params["resume"] = .bool(true)
            try await agent.start("trainer-\(run.trainer)", gpus: plan.train?.gpus ?? [], params: params)
            self.runID = run.runID
            self.points = run.points
            self.result = run.result
            self.result?.state = .training
            self.trainingState = "running"
            self.lastActivity = Date()
            self.recordStartedRun(datasetRepo: run.datasetRepo, params: params, resumed: true)
            self.persist()
            self.persistResult()
            self.message = "Continuing run \(run.runID) toward \(totalSteps) total steps from its latest checkpoint."
        }
    }
}
