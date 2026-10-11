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

    static let ltxTrainingExtra: JSONObject = [
        "optimization": .object(["optimizer_type": .string("adamw8bit")]),
        "acceleration": .object([
            "quantization": .string("int8-quanto"),
            "load_text_encoder_in_8bit": .bool(true),
            "offload_optimizer_during_validation": .bool(true),
        ]),
        "preprocess": .object(["args": .array([
            .string("--load-text-encoder-in-8bit"), .string("--vae-tiling"), .string("--skip-audio"),
        ])]),
    ]

    func train(datasetRepo: String) async {
        await perform {
            guard let agent = self.agent, self.hasRunningPod else {
                throw StudioError.message("Rent a training computer first, then return here.")
            }
            guard !datasetRepo.isEmpty, self.steps > 0, self.rank > 0, !self.baseModel.isEmpty,
                  Self.resolutionChoices.contains(self.resolution) else {
                throw StudioError
                    .message("Publish your dataset first and choose a model with positive training steps and rank.")
            }
            // A pending result on other storage cannot be retrieved from here; it stays in the project's
            // training record and is retrieved from a computer on that storage.
            if let result = self.result, result.state == .pending, self.resultIsOnThisPod(result) {
                throw StudioError.message(
                    "Save the trained LoRA from run \(result.runID) first (Retrieve now), then start another run."
                )
            }
            let servicesBeforeStart = try await agent.services()
            guard !servicesBeforeStart.contains(where: { $0.name.hasPrefix("trainer-") && $0.active }) else {
                throw StudioError.message("A training run is active. Stop it before starting another.")
            }
            let plan = try await agent.plan()
            self.plan = plan
            let dataset = "conceptstudio"
            try await agent.start("pull-dataset", gpus: [], params: [
                "repo_id": .string(datasetRepo), "name": .string(dataset),
            ])
            self.message = "Downloading your published photos and captions."
            try await self.waitForService("pull-dataset")
            try await self.prepareCaptionServerForTraining(agent, plan: plan)
            self.runID = "concept-" + UUID().uuidString.prefix(12).lowercased()
            self.points = []
            self.historyRunID = self.runID
            await self.defaultOutputRepo()
            let destination: TrainingResult.Destination = self.canPushToHub && !self.outputRepo.isEmpty
                ? .hub : .download
            try await agent.start(
                "trainer-\(self.trainer)", gpus: plan.train?.gpus ?? [],
                params: self.trainingParams(dataset: dataset, destination: destination)
            )
            self.result = TrainingResult(
                runID: self.runID, outputRepo: self.outputRepo, destination: destination,
                volumeID: self.currentVolumeID, state: .training
            )
            self.persist()
            self.persistResult()
            self.saveProjectRecord()
            let services = try await agent.services()
            if !services.contains(where: { $0.name == "tensorboard" && $0.active }) {
                try await agent.start("tensorboard", gpus: [], params: ["logdir": .string("/workspace/runs")])
            }
            self.trainingState = "running"
            self.lastActivity = Date()
            self.message = destination == .hub
                ? "Training started. When it finishes, the LoRA is pushed to \(self.outputRepo)."
                : "Training started. When it finishes, the LoRA is saved into this project’s results folder."
        }
    }

    /// Signed in to Hugging Face with no output repo chosen: push to `<account>/<project>-lora`
    /// (private unless the user turned that off). If the account cannot be read, the result is
    /// downloaded into the project instead, as for a user without a Hub account.
    func defaultOutputRepo() async {
        guard !demoMode, !hubToken.isEmpty, outputRepo.isEmpty,
              let url = URL(string: "https://huggingface.co/api/whoami-v2") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(hubToken)", forHTTPHeaderField: "Authorization")
        guard let response = try? await transport.send(request), response.status == 200,
              let account = try? JSONValue(parsing: response.body).objectValue?["name"]?.stringValue,
              !account.isEmpty, !account.contains("/") else { return }
        outputRepo = "\(account)/\(Self.repoName(project: projectFolder?.lastPathComponent ?? ""))"
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

    private func prepareCaptionServerForTraining(_ agent: any PodAgent, plan: TrainingPlan) async throws {
        let services = try await agent.services()
        let captionActive = services.contains(where: { $0.name == "vllm" && $0.active })
        if plan.mode == "sequential", captionActive {
            try await agent.stop("vllm")
            try await waitForService("vllm", allowStopped: true)
        } else if plan.mode != "sequential", keepCaptionServer, !captionActive {
            try await agent.start("vllm", gpus: plan.caption?.gpus ?? [], params: captionStartParams)
        }
    }

    private func trainingParams(dataset: String, destination: TrainingResult.Destination) -> JSONObject {
        let words = triggerWords.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let checkpointEvery = min(250, steps)
        var params: JSONObject = [
            "run_id": .string(runID),
            "dataset": .object(["path": .string("/workspace/datasets/\(dataset)")]),
            "triggers": .array(words.map(JSONValue.string)), "profile": .string(profile),
            "base_model": .string(baseModel), "steps": .int(steps), "rank": .int(rank),
            "learning_rate": .double(learningRate), "resolution": .int(resolution),
            "save_every": .int(checkpointEvery), "sample_every": .int(samplesEnabled ? checkpointEvery : 0),
        ]
        if samplesEnabled {
            params["sample_prompts"] = .array([.string(words.joined(separator: " "))])
        }
        if trainer == "ltx" {
            params["extra"] = .object(Self.ltxTrainingExtra)
        }
        if destination == .hub {
            params["hub"] = .object([
                "repo_id": .string(outputRepo), "private": .bool(privateResult), "push_on_finish": .bool(true),
            ])
        }
        return params
    }

    func publishResult() async {
        await perform {
            guard let agent = self.agent, !self.outputRepo.isEmpty, !self.runID.isEmpty else {
                throw StudioError.message("Enter a destination model repository and finish a training run first.")
            }
            try await agent.start("push-lora", gpus: [], params: [
                "run_id": .string(self.runID), "repo_id": .string(self.outputRepo),
                "private": .bool(self.privateResult),
            ])
            try await self.waitForService("push-lora")
            if self.result?.runID == self.runID {
                self.updateResult(.pushed(repo: self.outputRepo))
            }
            self.message = "Your LoRA was uploaded to your model repository. You can now stop the computer."
        }
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
            if plan.mode == "sequential",
               services.contains(where: { $0.name.hasPrefix("trainer-") && $0.active }) {
                throw StudioError.message("Finish training before captioning on this single-GPU computer.")
            }
            if !services.contains(where: { $0.name == "vllm" && $0.active }) {
                try await agent.start("vllm", gpus: plan.caption?.gpus ?? [], params: self.captionStartParams)
            }
            self.lastActivity = Date()
            self.message = "The caption model is starting. Large models can take several minutes to download."
            if !self.demoMode {
                try await self.waitForCaptionModel()
            }
            ready = true
            self.message = "The caption model is ready. You can now caption with this computer."
        }
        return ready
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
