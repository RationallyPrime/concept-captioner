import ConceptCore
import Foundation

/// vLLM launch settings for the caption server on GPU 0.
struct CaptionServerSettings: Equatable {
    let maxModelLen: Int
    let maxNumSeqs: Int
    let gpuMemoryUtilization: Double
    let extraArgs: [String]

    func params(model: String) -> JSONObject {
        [
            "model": .string(model), "max_model_len": .int(maxModelLen), "max_num_seqs": .int(maxNumSeqs),
            "gpu_memory_utilization": .double(gpuMemoryUtilization),
            "extra_args": .array(extraArgs.map(JSONValue.string)),
        ]
    }
}

extension GPUWorkspace {
    /// Measured, not universal: each row is what fit and served captions on the GPUs it was tried
    /// on (Qwen3-VL-8B on the 32 GB RTX PRO 4500 pods, POD-STATUS 2026-10-10). A different model or
    /// GPU size needs its own measured row; until then it gets the 8B row, the smallest footprint
    /// known to work, rather than the agent's generic defaults (POD-SPEC 3.1).
    nonisolated static let measuredCaptionServers: [String: CaptionServerSettings] = [
        "Qwen/Qwen3-VL-8B-Instruct": CaptionServerSettings(
            maxModelLen: 16384, maxNumSeqs: 2, gpuMemoryUtilization: 0.85,
            extraArgs: ["--enforce-eager", "--max-num-batched-tokens=4096"]
        ),
    ]

    nonisolated static func captionServerSettings(for model: String) -> CaptionServerSettings {
        measuredCaptionServers[model] ?? measuredCaptionServers["Qwen/Qwen3-VL-8B-Instruct"]!
    }

    var captionStartParams: JSONObject {
        Self.captionServerSettings(for: captionModel).params(model: captionModel)
    }

    func updateTrainingService(_ services: [AgentService]) {
        guard let state = services.first(where: { $0.name.hasPrefix("trainer-") && $0.active })
            ?? services.first(where: { $0.name == "trainer-\(trainer)" }) else { return }
        if state.active { trainer = String(state.name.dropFirst("trainer-".count)) }
        if let id = state.runID { runID = id }
        trainingState = state.state
    }

    func updateCaptionServerState(_ services: [AgentService]) {
        captionServerActive = services.contains { $0.name == "vllm" && $0.active }
    }

    /// Starts a run on the rented computer. `output` is the open project's training destination: a
    /// non-empty repo with a Hub token pushes the LoRA there on finish; otherwise it is saved to the project.
    func train(
        datasetRepo: String,
        output: HubDestination = HubDestination(),
        captureLocal: (@MainActor () async throws -> LocalTrainingDataset)? = nil,
        regularizationCaptioning: (@MainActor ([String]) throws -> RegularizationCaptioning)? = nil
    ) async {
        await perform {
            guard let agent = self.agent, self.hasRunningPod else {
                throw StudioError.message("Rent a training computer first, then return here.")
            }
            let cap = self.runBudget
            guard cap.isFinite, cap > 0 else {
                throw StudioError.message("Choose a positive budget for this training run before preparing its inputs.")
            }
            let baseline = self.estimatedPodCost
            let selectedTrainer = self.trainer
            let selectedModel = self.baseModel
            if let hook = self.nativeRecipeHook {
                try hook.validateGuidance(settings: self.h3RecipeSettings, guidanceLoss: self.guidanceLoss)
            }
            if let row = self.exactModelRow, row.gpu.verifyOnPod {
                let plan = try await agent.plan()
                try await self.verifyGPUMemory(agent, gpus: plan.train?.gpus ?? [], row: row)
            }
            let local = try await self.currentLocalDataset(capture: captureLocal)
            defer { local?.remove() }
            guard self.trainer == selectedTrainer, self.baseModel == selectedModel else {
                throw StudioError.message("The training model changed during input preparation. "
                    + "Check the selected model and start again; no training was submitted.")
            }
            let repeated = self.publishedRepeatRun
            let repo = repeated?.datasetRepo ?? datasetRepo
            let revision = repeated.map(\.datasetRevision)
                ?? (self.datasetRevision.isEmpty ? nil : self.datasetRevision)
            let containsVideo = local?.containsVideo ?? repeated?.datasetContainsVideo ?? self.datasetContainsVideo
            let inputFacts = (profile: self.profile, triggers: self.triggerWords, video: containsVideo)
            let items = local?.itemCount ?? self.publishedRepeatItemCount ?? self.datasetItemCount
            try self.validateTrainingSettings(
                local: local != nil, repo: repo, containsVideo: containsVideo, items: items
            )
            let captioning = try self.captioningForRegularization(regularizationCaptioning)
            let initialization = try self.trainingInitialization()
            let dataset = "concept-" + UUID().uuidString.prefix(12).lowercased()
            var params = self.trainingParams(dataset: dataset, inputFacts: inputFacts, items: items)
            let servicesBeforeStart = try await agent.services()
            self.updateCaptionServerState(servicesBeforeStart)
            guard !servicesBeforeStart.contains(where: { $0.active && ($0.name.hasPrefix("trainer-")
                    || $0.name.hasPrefix("generate-")) }) else {
                throw StudioError.message("A training run is active. Stop it before starting another.")
            }
            let plan = try await agent.plan()
            self.plan = plan
            params = self.admitNewRun(
                dataset, params: params, repo: repo, local: local, revision: revision,
                budget: (cap, baseline), inputs: (containsVideo, items), output: output
            )
            let destination = self.result?.destination ?? .download
            var trainerStartAttempted = false
            defer { if !trainerStartAttempted { self.finishFailedPreparation() } }
            try await self.installTrainingDataset(local, repo: repo, revision: revision, name: dataset, agent: agent)
            if let initialization {
                params["initialization"] = try await .object(initialization.upload(to: agent))
            }
            params = try await self.captionedRegularization(params, plan: plan, captioning: captioning, agent: agent)
            try await self.prepareCaptionServerForTraining(agent, plan: plan)
            self.historyRunID = self.runID
            try Task.checkCancellation()
            try self.checkCurrentRunBudget()
            trainerStartAttempted = true
            try await agent.start("trainer-\(selectedTrainer)", gpus: plan.train?.gpus ?? [], params: params)
            self.persist()
            self.persistResult()
            await self.recordNewTrainingRun(
                agent, datasetRepo: local == nil ? repo : "", params: params, localInputDigest: local?.digest
            )
            let services = try await agent.services()
            self.updateCaptionServerState(services)
            if !services.contains(where: { $0.name == "tensorboard" && $0.active }) {
                try await agent.start("tensorboard", gpus: [], params: ["logdir": .string("/workspace/runs")])
            }
            self.trainingState = "running"
            self.lastActivity = Date()
            self.message = destination == .hub
                ? "Training started. When it finishes, the LoRA is pushed to \(output.repo)."
                : "Training started. When it finishes, the LoRA is saved into this project’s results folder."
        }
    }

    private func validateTrainingSettings(local: Bool, repo: String, containsVideo: Bool, items: Int) throws {
        let row = effectiveModelRow
        guard nativeRecipe == nil || nativeRecipeHook != nil else {
            throw StudioError.message("This imported recipe is for \(nativeRecipeName). Choose another training model "
                + "to clear it before using a different base model.")
        }
        guard !triggerWords.split(whereSeparator: { $0 == "," || $0.isWhitespace }).isEmpty else {
            throw StudioError.message("Define a concept and its trigger in Concepts before starting training.")
        }
        guard local || !repo.isEmpty, steps > 0, rank > 0, !baseModel.isEmpty,
              !trainingResolutions.isEmpty, trainingResolutions.allSatisfy(resolutionChoices.contains) else {
            throw StudioError.message("Prepare your dataset and choose a model with positive training steps and rank.")
        }
        guard !containsVideo || row.video != nil else {
            let capable = ModelTable.sentenceList(modelTable.videoRows.map(\.shortName), conjunction: "or")
            throw StudioError.message(
                "\(row.shortName) image training does not accept video clips. Choose \(capable) training."
            )
        }
        if let hook = nativeRecipeHook {
            try hook.validateGuidance(settings: h3RecipeSettings, guidanceLoss: guidanceLoss)
        }
        guard seed >= 0, learningRate.isFinite, learningRate > 0, learningRate <= 1,
              alpha > 0, batchSize > 0, accumulation > 0 else {
            throw StudioError.message("Choose positive training values and a nonnegative seed.")
        }
        let checkpointsValid = !row.recipe.checkpoints.editable || (checkpointEvery > 0 && checkpointRetention >= 0
            && ["float16", "float32", "bfloat16", "fp16", "fp32", "bf16"].contains(checkpointPrecision))
        let guidanceValid = nativeRecipeHook?.validGuidanceTarget(guidanceTarget) ?? true
        guard checkpointsValid, guidanceValid else {
            throw StudioError.message("Choose a positive checkpoint interval, retention of zero or more, "
                + "a supported saved precision and guidance target from 0 to 20 (or a two-value range).")
        }
        guard row.recipe.lengthUnit == .steps || items > 0 else {
            throw StudioError.message("Training length in epochs needs the number of included images and clips. "
                + "Open the project that holds them.")
        }
        try validateTrainerSettings()
        try validateTrainingAids()
        guard !resultNeedsSaving else {
            throw StudioError.message("Retrieve pending trained models or generated outputs before starting a run.")
        }
    }

    private func admitNewRun(
        _ id: String, params: JSONObject, repo: String, local: LocalTrainingDataset?, revision: String?,
        budget: (cap: Double, baseline: Double), inputs: (containsVideo: Bool, items: Int), output: HubDestination
    ) -> JSONObject {
        var params = params
        runID = id
        let destination: TrainingResult.Destination = canPushToHub && !output.repo.isEmpty ? .hub : .download
        if destination == .hub {
            params["hub"] = .object([
                "repo_id": .string(output.repo), "private": .bool(output.isPrivate), "push_on_finish": .bool(true),
            ])
        }
        points = []
        regularizationProgress = nil
        datasetContainsVideo = inputs.containsVideo
        datasetRevision = local == nil ? (revision ?? "") : ""
        result = TrainingResult(
            runID: id,
            outputRepo: output.repo,
            isPrivate: output.isPrivate,
            destination: destination,
            volumeID: currentVolumeID,
            state: .training
        )
        trainingState = "Preparing inputs"
        recordStartedRun(
            datasetRepo: local == nil ? repo : "",
            params: params,
            resumed: false,
            localInputDigest: local?.digest,
            itemCount: inputs.items,
            budget: budget.cap,
            baseline: budget.baseline
        )
        persist()
        persistResult()
        return params
    }

    /// The default destination for a project signed in to Hugging Face with none chosen:
    /// `<account>/<project>-lora`. Nil without a token or when the account cannot be read; the result
    /// is then downloaded into the project, as for a user without a Hub account.
    func suggestedOutputRepo() async -> String? {
        guard !demoMode, !hubToken.isEmpty, let projectFolder,
              let url = URL(string: "https://huggingface.co/api/whoami-v2") else { return nil }
        // Asked as Start is pressed: the idle stop must not take the computer while this answers.
        beginAppWork()
        defer { endAppWork() }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(hubToken)", forHTTPHeaderField: "Authorization")
        guard let response = try? await transport.send(request), response.status == 200,
              let account = try? JSONValue(parsing: response.body).objectValue?["name"]?.stringValue,
              !account.isEmpty, !account.contains("/") else { return nil }
        return "\(account)/\(Self.repoName(project: projectFolder.lastPathComponent))"
    }

    /// A Hub model name from the project folder: letters, digits, `-`, `_` and `.`, ending in `-lora`.
    nonisolated static func repoName(project: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        var cleaned = String(project.lowercased().map { allowed.contains($0) ? $0 : "-" }.prefix(80))
        while cleaned.contains("--") || cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "--", with: "-").replacingOccurrences(of: "..", with: ".")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return (cleaned.isEmpty ? "concept" : cleaned) + "-lora"
    }

    func prepareCaptionServerForTraining(_ agent: any PodAgent, plan: TrainingPlan) async throws {
        let services = try await agent.services()
        updateCaptionServerState(services)
        let captionActive = services.contains(where: { $0.name == "vllm" && $0.active })
        if plan.mode == "sequential", captionActive {
            try await agent.stop("vllm")
            try await waitForService("vllm", allowStopped: true)
        } else if plan.mode != "sequential", keepCaptionServer, !captionActive {
            try await agent.start("vllm", gpus: plan.caption?.gpus ?? [], params: captionStartParams)
        }
    }

    /// The optimizer steps the next run takes: the length as entered, or for a model that counts epochs the
    /// passes over each of `items` images and clips turned into steps.
    func optimizerSteps(items: Int) -> Int {
        effectiveModelRow.recipe.lengthUnit.optimizerSteps(
            length: steps, items: items, batchSize: batchSize, accumulation: accumulation
        )
    }

    func trainingParams(
        dataset: String, inputFacts: (profile: String, triggers: String, video: Bool), items: Int? = nil
    ) -> JSONObject {
        let words = inputFacts.triggers.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let row = effectiveModelRow
        let totalSteps = trainerSteps(items: items ?? datasetItemCount)
        let saveInterval = row.recipe.checkpoints.editable
            ? checkpointEvery : min(row.recipe.checkpoints.every, totalSteps)
        var params: JSONObject = [
            "run_id": .string(dataset),
            "dataset": .object(["path": .string("/workspace/datasets/\(dataset)")]),
            "triggers": .array(words.map(JSONValue.string)), "profile": .string(inputFacts.profile),
            "base_model": .string(baseModel), "steps": .int(totalSteps), "rank": .int(rank),
            "alpha": .int(alpha), "batch_size": .int(batchSize), "gradient_accumulation": .int(accumulation),
            "learning_rate": .double(learningRate),
            "resolution": trainingResolutions.count > 1
                ? .array(trainingResolutions.map(JSONValue.int)) : .int(resolution),
            "seed": .int(seed),
            "save_every": .int(saveInterval), "sample_every": .int(samplesEnabled ? saveInterval : 0),
        ]
        if samplesEnabled {
            params["sample_prompts"] = .array([.string(words.joined(separator: " "))])
        }
        for setting in trainerSettingOverrides.pairs {
            params[setting.key] = setting.value
        }
        if let block = regularizationBlock(triggers: words) { params["regularization"] = .object(block) }
        if let block = repaBlock() { params["repa"] = .object(block) }
        if trainer == "ltx" {
            let extra = row.runExtra ?? [:]
            params["extra"] = .object(row.hooks.runExtra?.apply(to: extra, containsVideo: inputFacts.video) ?? extra)
        } else {
            var extra = nativeRecipe?.settings
                ?? runHistory.first(where: { $0.runID == repeatSourceRunID })?.params["extra"]?.objectValue ?? [:]
            if row.recipe.checkpoints.editable {
                var save = extra["save"]?.objectValue ?? [:]
                save["save_every"] = .int(saveInterval)
                save["max_step_saves_to_keep"] = .int(checkpointRetention)
                save["dtype"] = .string(checkpointPrecision)
                extra["save"] = .object(save)
            }
            if nativeRecipeHook != nil {
                var train = extra["train"]?.objectValue ?? [:]
                train["do_guidance_loss"] = .bool(guidanceLoss)
                train["guidance_loss_target"] = guidanceTarget
                extra["train"] = .object(train)
            }
            extra["training_seed"] = .int(seed)
            params["extra"] = .object(extra)
        }
        return params
    }

    func startCaptioning() async -> Bool {
        var ready = false
        await perform {
            guard let agent = self.agent, self.hasRunningPod else {
                throw StudioError.message("Rent a computer before starting its caption model.")
            }
            let plan = try await agent.plan()
            self.plan = plan
            let services = try await agent.services()
            self.updateCaptionServerState(services)
            if plan.mode == "sequential",
               services.contains(where: { $0.name.hasPrefix("trainer-") && $0.active }) {
                throw StudioError.message("Finish training before captioning on this single-GPU computer.")
            }
            try await self.ensureCaptionServer(agent, plan: plan, services: services)
            ready = true
            self.message = "The caption model is ready. You can now caption with this computer."
        }
        return ready
    }

    /// Starts the caption server on the rented computer unless it runs, and waits until it serves the model.
    func ensureCaptionServer(_ agent: any PodAgent, plan: TrainingPlan, services: [AgentService]) async throws {
        if !services.contains(where: { $0.name == "vllm" && $0.active }) {
            try await agent.start("vllm", gpus: plan.caption?.gpus ?? [], params: captionStartParams)
            captionServerActive = nil
        }
        lastActivity = Date()
        message = "The caption model is starting. Large models can take several minutes to download."
        if !demoMode {
            try await waitForCaptionModel()
        }
    }

    private func waitForCaptionModel() async throws {
        guard let endpoint = captionEndpoint else {
            throw StudioError.message("Your captioning computer is stopped. Rent or start one first.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(600))
        while clock.now < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint.appendingPathComponent("models"), timeoutInterval: 15)
            request.setValue("Bearer \(agentToken)", forHTTPHeaderField: "Authorization")
            do {
                let response = try await transport.send(request)
                if response.status == 200,
                   let models = try JSONValue(parsing: response.body).objectValue?["data"]?.arrayValue,
                   models.contains(where: { $0.objectValue?["id"]?.stringValue == captionModel }) {
                    return
                }
                if [401, 403].contains(response.status) {
                    throw StudioError.message("This computer rejected its captioning key. Stop it and rent a new one.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as StudioError {
                throw error
            } catch {
                // The inference server may not yet be listening while model weights download.
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw StudioError
            .message("The caption model is still not ready. Check the computer’s logs or stop it before retrying.")
    }
}
