import ConceptCore
import Foundation

extension GPUWorkspace {
    func generateComparison(
        run: TrainingRun, checkpoint: RunFile, prompts: [String], seeds: [Int], inferenceSteps: Int = 20,
        videoFrames: Int? = nil
    ) async {
        await perform {
            guard !self.demoMode else {
                throw StudioError.message("The demo has no trained weights. Generation uses a real checkpoint.")
            }
            guard let agent = self.agent, self.hasRunningPod, self.projectFolder != nil,
                  self.currentVolumeID == run.volumeID, self.trainer == run.trainer else {
                throw StudioError.message("Connect the matching trainer to this run's saved storage before generating.")
            }
            guard run.supportsGeneration(in: self.modelTable) else {
                throw StudioError.message("Generation supports \(self.modelTable.generationModelList) checkpoints.")
            }
            let frames = videoFrames ?? run.defaultGenerationFrames(in: self.modelTable)
            if let problem = Self.generationFramesError(run: run, frames: frames, table: self.modelTable) {
                throw StudioError.message(problem)
            }
            guard !prompts.isEmpty, !seeds.isEmpty, prompts.count <= 6, seeds.count <= 4,
                  prompts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !$0.contains("--") }), seeds.allSatisfy({ $0 >= 0 && $0 <= Int(UInt32.max) }) else {
                throw StudioError.message("Enter 1–6 prompts and 1–4 seeds. Prompt '--' overrides are not supported.")
            }
            guard !self.resultNeedsSaving else {
                throw StudioError.message("Retrieve the pending outputs before generating another comparison.")
            }
            let services = try await agent.services()
            guard !services.contains(where: { $0.active && ($0.name.hasPrefix("trainer-")
                    || $0.name.hasPrefix("generate-")) }) else {
                throw StudioError.message("Finish the active training or generation action first.")
            }
            let plan = try await agent.plan()
            if let row = run.modelRow(in: self.modelTable), row.gpu.verifyOnPod {
                try await self.verifyGPUMemory(agent, gpus: plan.train?.gpus ?? [], row: row)
            }
            try await self.prepareCaptionServerForTraining(agent, plan: plan)
            let id = "generation-" + UUID().uuidString.prefix(12).lowercased()
            let resolution = run.params["resolution"]?.intValue
                ?? run.params["resolution"]?.arrayValue?.compactMap(\.intValue).max() ?? 512
            let params: JSONObject = [
                "run_id": .string(id), "source_run_id": .string(run.runID),
                "checkpoint": .string(checkpoint.path), "prompts": .array(prompts.map(JSONValue.string)),
                "seeds": .array(seeds.map(JSONValue.int)), "width": .int(resolution), "height": .int(resolution),
                "inference_steps": .int(inferenceSteps), "guidance_scale": .double(4),
                "num_frames": .int(run.generatesVideo(in: self.modelTable) ? frames : 1),
                "frame_rate": .double(Double(run.generationFrameRate(in: self.modelTable))),
            ]
            self.generation = GeneratedComparison(
                runID: id, sourceRunID: run.runID, checkpoint: checkpoint.path, trainer: run.trainer,
                volumeID: run.volumeID, startedAt: Date(), state: .generating,
                paramsJSON: JSONValue.object(params).pythonDumpsData()
            )
            self.lastActivity = Date()
            self.saveProjectRecord()
            self.persist()
            try await agent.start("generate-\(run.trainer)", gpus: [plan.train?.gpus.first ?? 0], params: params)
            self.message = "Generating matched base and LoRA outputs. "
                + "The same prompts, seeds and settings apply to both."
        }
    }

    func settleGeneration(_ agent: any PodAgent, services: [AgentService]) async throws {
        guard var generation, generation.volumeID == currentVolumeID else { return }
        if generation.state == .generating {
            let own = services.first { $0.name == "generate-\(generation.trainer)" && $0.runID == generation.runID }
            if own?.active == true { return }
            let files = try await agent.runFiles(runID: generation.runID)
            guard files.contains(where: { Self.isGeneratedOutput($0.path) }) else {
                generation.state = .failed
                generation.failure = "Generation ended without outputs. Read its saved log before retrying."
                self.generation = generation
                saveProjectRecord()
                persist()
                return
            }
            generation.state = .pending
            if own?.state != "exited" { generation.failure = "Generation was interrupted; available outputs are kept." }
            self.generation = generation
            saveProjectRecord()
            persist()
        }
        if generation.state == .pending { startAutomaticRetrieval() }
    }

    func retrieveGeneration() async throws {
        guard let source = generation?.sourceRunID, projectOwnsRun(source) else {
            throw StudioError.message("Open this comparison's original project before retrieving its outputs.")
        }
        guard var generation, generation.state == .pending, let agent, hasRunningPod,
              generation.volumeID == currentVolumeID else {
            throw StudioError.message("Connect this generation's storage to retrieve its outputs.")
        }
        let files = try await agent.runFiles(runID: generation.runID).filter {
            Self.isGeneratedOutput($0.path)
        }
        guard !files.isEmpty else { throw StudioError.message("No generated files are available yet.") }
        let folder = try resultsFolder(for: generation.runID)
        for file in files {
            try Task.checkCancellation()
            message = "Downloading generated output \(file.path)…"
            try await download(file, runID: generation.runID, into: folder, agent: agent)
        }
        generation.folder = folder.path
        let manifest = comparisonManifest(generation)
        let complete = manifest?.state == "complete" && manifest?.pairs.isEmpty == false
            && manifest?.pairs.allSatisfy { pair in
                comparisonFile(pair.basePath, in: generation) != nil
                    && comparisonFile(pair.loraPath, in: generation) != nil
            } == true
        generation.state = complete ? .saved : .failed
        generation.failure = complete ? nil
            : "Generation did not complete every base/LoRA pair. Available files are saved; inspect the run log."
        self.generation = generation
        saveProjectRecord()
        persist()
        message = complete ? "Generated outputs saved into this project. The computer can now be stopped."
            : generation.failure ?? "Generation did not finish."
    }

    nonisolated static func isGeneratedOutput(_ path: String) -> Bool {
        path == "comparison.json" || ["png", "jpg", "webp", "mp4"].contains((path as NSString).pathExtension)
    }

    func comparisonManifest(_ comparison: GeneratedComparison) -> ComparisonManifest? {
        guard let folder = comparison.folder,
              let expected = try? resultsFolder(for: comparison.runID),
              URL(fileURLWithPath: folder).resolvingSymlinksInPath().path == expected.path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("comparison.json"))
        else { return nil }
        return try? JSONDecoder().decode(ComparisonManifest.self, from: data)
    }

    func comparisonFile(_ path: String, in comparison: GeneratedComparison) -> URL? {
        guard let folder = comparison.folder, let expected = try? resultsFolder(for: comparison.runID),
              URL(fileURLWithPath: folder).resolvingSymlinksInPath().path == expected.path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { ["", ".", ".."].contains(String($0)) }) else { return nil }
        let root = URL(fileURLWithPath: folder).standardizedFileURL
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
