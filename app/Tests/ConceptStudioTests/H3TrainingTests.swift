import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

actor H3TestAgent: PodAgent {
    private(set) var starts: [HistoryAgent.Start] = []
    private(set) var uploads: [DatasetUploadAgent.Upload] = []
    var memoryMiB = 97887
    var failsUpload = false
    var paused = false
    private var pauseNext = false
    private var continuation: CheckedContinuation<Void, Never>?

    func gpus() -> [AgentGPU] {
        [.init(index: 0, name: "Synthetic 96 GB", memoryTotalMiB: memoryMiB)]
    }

    func setMemory(_ memory: Int) {
        memoryMiB = memory
    }

    func failUpload() {
        failsUpload = true
    }

    func holdUpload() {
        pauseNext = true
    }

    func release() {
        continuation?.resume(); continuation = nil
    }

    func upload(name: String, fileName: String, from file: URL, size: Int64) async throws {
        if failsUpload { throw StudioError.message("Synthetic upload failure") }
        let data = try Data(contentsOf: file)
        #expect(Int64(data.count) == size)
        uploads.append(.init(stage: name, name: fileName, data: data))
        if pauseNext {
            pauseNext = false
            paused = true
            await withCheckedContinuation { continuation = $0 }
            try Task.checkCancellation()
        }
    }

    func plan() -> TrainingPlan {
        .init(mode: "sequential", caption: .init(gpus: [0]), train: .init(gpus: [0]))
    }

    func services() -> [AgentService] {
        starts.map { .init(
            name: $0.service,
            state: "exited",
            groupAlive: false,
            runID: $0.params["run_id"]?.stringValue
        ) }
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) {
        starts.append(.init(service: service, gpus: gpus, params: params))
    }

    func stop(_ service: String) {}
    func latest(runID: String) -> TrainingPoint? {
        nil
    }

    func history(runID: String) -> [TrainingPoint] {
        []
    }

    func runLog(runID: String) -> String {
        "Synthetic"
    }

    func runFiles(runID: String) -> [RunFile] {
        []
    }

    func download(runID: String, path: String, to destination: URL) {}
    func runConfiguration(runID: String) -> AgentRunConfiguration {
        .init(config: starts.last { $0.service.hasPrefix("trainer-") }?.params ?? [:], dataset: [:])
    }
}

@Suite("H3 native training and initialization")
struct H3TrainingTests {
    static let recipe = """
    job: extension
    config:
      name: old-output
      process:
        - type: sd_trainer
          training_folder: /old/private/output
          hf_token: synthetic-secret
          model:
            name_or_path: Comfy-Org/MiniMax-H3
            arch: minimax_h3
            quantize: false
            quantize_te: false
            low_vram: false
            assistant_lora_path: /old/private/minimax_h3_image_training_adapter.safetensors
            model_kwargs:
              partition: fl2va_pruned
              video_vae_path: /old/private/minimax_h3_video_vae_fp16.safetensors
          network:
            type: lora
            linear: 32
            linear_alpha: 32
            pretrained_lora_path: /old/private/weights.safetensors
            network_kwargs:
              only_if_contains: [transformer.blocks.20., transformer.blocks.49.]
          train:
            start_step: 601
            steps: 9999
            lr: 0.0001
            batch_size: 1
            gradient_accumulation: 2
            optimizer: adamw
            dtype: bf16
            lr_scheduler_params: {num_warmup_steps: 35}
            audio_loss_multiplier: 0
          datasets:
            - folder_path: /old/private/data
              resolution: [768, 1024]
              fps: 24
              num_frames: 1
              cache_latents_to_disk: true
    """

    @MainActor static func connected(_ preferences: UserDefaults, folder: URL, agent: H3TestAgent) -> GPUWorkspace {
        let workspace = makeWorkspace(UnreachableAgentTransport(), preferences)
        workspace.projectFolder = folder
        workspace.pod = .init(id: "test", status: "RUNNING", cost: 1, gpu: .init(count: 1))
        workspace.saved = .init(
            pod: workspace.pod!,
            started: Date(),
            hourlyRate: 1,
            budget: 10,
            trainer: "aitoolkit",
            runID: "",
            outputRepo: "",
            volumeID: "storage"
        )
        workspace.agent = agent
        workspace.hubToken = "synthetic"
        return workspace
    }

    @MainActor @Test func importsQualitySettingsAndWarmStartsFreshWithFinalEditedValues() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        let workspace = Self.connected(preferences, folder: project.directory, agent: agent)
        let recipe = project.directory.appendingPathComponent("input.yaml")
        try Data(Self.recipe.utf8).write(to: recipe)
        try workspace.importTrainingRecipe(from: recipe)
        #expect(workspace.steps == 200)
        #expect(workspace.rank == 32 && workspace.alpha == 32 && workspace.accumulation == 2)
        let checkpoint = project.directory.appendingPathComponent("selected.safetensors")
        let weights = Data("synthetic weights".utf8)
        try weights.write(to: checkpoint)
        await workspace.importInitialCheckpoint(from: checkpoint)
        workspace.steps = 300
        workspace.alpha = 24
        workspace.learningRate = 0.00005
        workspace.batchSize = 2
        workspace.accumulation = 3
        await workspace.train(datasetRepo: "synthetic/current-data")
        let starts = await agent.starts
        let params = try #require(starts.first { $0.service == "trainer-aitoolkit" }?.params)
        #expect(params["steps"] == .int(300) && params["rank"] == .int(32) && params["alpha"] == .int(24))
        #expect(params["learning_rate"] == .double(0.00005))
        #expect(params["batch_size"] == .int(2) && params["gradient_accumulation"] == .int(3))
        #expect(params["resolution"] == .array([.int(768), .int(1024)]))
        #expect(params["resume"] == nil)
        let extra = try #require(params["extra"]?.objectValue)
        #expect(extra["model"]?.objectValue?["quantize"] == .bool(false))
        #expect(extra["model"]?.objectValue?["quantize_te"] == .bool(false))
        #expect(extra["model"]?.objectValue?["use_training_adapter"] == .bool(true))
        #expect(extra["train"]?.objectValue?["start_step"] == nil)
        #expect(extra["network"]?.objectValue?["pretrained_lora_path"] == nil)
        #expect(extra["train"]?.objectValue?["lr_scheduler_params"]?.objectValue?["num_warmup_steps"] == .int(35))
        let uploads = await agent.uploads
        #expect(uploads.map(\.name) == ["initial-lora.safetensors", "initial-recipe.json"])
        #expect(uploads[0].data == weights)
        let canonical = try #require(String(data: uploads[1].data, encoding: .utf8))
        #expect(!canonical.contains("/old/") && !canonical.contains("synthetic-secret") && !canonical.contains("601"))
        let binding = try #require(params["initialization"]?.objectValue)
        #expect(binding["name"]?.stringValue == uploads[0].stage)
        #expect(binding["lora_sha256"]?.stringValue == sha256(weights))
        #expect(binding["recipe_sha256"]?.stringValue == sha256(uploads[1].data))
        #expect(workspace.runHistory.last?.gpuBudgetUSD == 10)
    }

    @MainActor @Test func smallerRetainedComputerRefusesBeforeInputsOrTrainer() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        await agent.setMemory(32768)
        let workspace = Self.connected(preferences, folder: project.directory, agent: agent)
        workspace.baseModel = GPUWorkspace.h3BaseModel
        await workspace.train(datasetRepo: "synthetic/data")
        #expect(await agent.starts.isEmpty)
        #expect(await agent.uploads.isEmpty)
        #expect(workspace.runHistory.isEmpty)
        #expect(workspace.message.contains("96 GB"))
    }

    @Test(arguments: ["unknown-video-vae.safetensors", "minimax_h3_image_training_adapter_other.safetensors"])
    func unknownImportedModelAssetsRefuseWithoutSilentReplacement(file: String) {
        let text = Self.recipe.replacingOccurrences(of: "minimax_h3_video_vae_fp16.safetensors", with: file)
        #expect(throws: (any Error).self) { try NativeTrainingRecipe.load(Data(text.utf8)) }
    }

    @MainActor @Test func explicitResolutionEditReplacesImportedMultiresolution() throws {
        let workspace = GPUWorkspace(demoMode: true)
        let recipe = try NativeTrainingRecipe.load(Data(Self.recipe.utf8))
        workspace.nativeRecipe = recipe
        workspace.resolution = recipe.resolution
        workspace.trainingResolutions = recipe.resolutions
        let imported = workspace.trainingParams(dataset: "synthetic", inputFacts: ("h3-still", "NORA7", false))
        #expect(imported["resolution"] == .array([.int(768), .int(1024)]))
        workspace.resolution = 768
        let edited = workspace.trainingParams(dataset: "synthetic", inputFacts: ("h3-still", "NORA7", false))
        #expect(edited["resolution"] == .int(768))
    }

    @MainActor @Test(arguments: [1, 39])
    func stillTrainedH3GeneratesStillOrVideo(frames: Int) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        let workspace = Self.connected(preferences, folder: project.directory, agent: agent)
        let params: JSONObject = [
            "base_model": .string(GPUWorkspace.h3BaseModel),
            "resolution": .array([.int(768), .int(1024)]),
        ]
        let run = TrainingRun(
            runID: "still-h3",
            trainer: "aitoolkit",
            datasetRepo: "synthetic/stills",
            datasetContainsVideo: false,
            paramsJSON: JSONValue.object(params).pythonDumpsData(),
            volumeID: "storage",
            startedAt: Date(),
            updatedAt: Date(),
            podSpendAtStart: 0
        )
        workspace.runHistory = [run]
        await workspace.generateComparison(
            run: run,
            checkpoint: .init(
                path: "chosen.safetensors",
                size: 10,
                sha256: "synthetic"
            ),
            prompts: ["NORA7 synthetic figure"],
            seeds: [42],
            videoFrames: frames
        )
        let start = try #require(await agent.starts.first { $0.service == "generate-aitoolkit" })
        #expect(start.params["num_frames"] == .int(frames))
        #expect(start.params["frame_rate"] == .double(24))
        #expect(start.params["source_run_id"] == .string("still-h3"))
        #expect(start.params["width"] == .int(1024) && start.params["height"] == .int(1024))
    }

    @MainActor @Test func h3ProjectSelectsOnlyUntouchedDefaultsAndPreservesRecipeAndCustomModel() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job.profile = "h3-video"
        let session = StudioSession(preferences: preferences, secrets: MemorySecretStore())
        session.project = project
        session.updateTrainingProjectDefaults()
        #expect(session.gpu.isH3Training)
        session.gpu.baseModel = "custom/edited"
        session.gpu.trainer = "aitoolkit"
        session.project?.job.profile = "ltx-video"
        session.updateTrainingProjectDefaults()
        #expect(session.gpu.baseModel == "custom/edited")
        #expect(session.gpu.trainer == "aitoolkit")
        session.gpu.nativeRecipe = try NativeTrainingRecipe.load(Data(Self.recipe.utf8))
        session.gpu.baseModel = GPUWorkspace.h3BaseModel
        session.updateTrainingProjectDefaults()
        #expect(session.gpu.isH3Training && session.gpu.hasNativeRecipe)
    }

    @MainActor @Test func changedModelDuringCaptureCannotBypassH3MemoryAdmission() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        await agent.setMemory(32768)
        let workspace = Self.connected(preferences, folder: project.directory, agent: agent)
        workspace.hubToken = ""
        await workspace.train(datasetRepo: "", captureLocal: {
            let prepared = try await LocalTrainingDataset.prepare(projectFolder: project.directory)
            workspace.baseModel = GPUWorkspace.h3BaseModel
            return prepared
        })
        #expect(await agent.uploads.isEmpty)
        #expect(await agent.starts.isEmpty)
        #expect(workspace.message.contains("changed during input preparation"))
    }
}
