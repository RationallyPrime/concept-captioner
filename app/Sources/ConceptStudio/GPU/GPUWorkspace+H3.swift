import ConceptCore
import Foundation

extension GPUWorkspace {
    static let minimumGPUMemoryGB = 32
    nonisolated static let h3BaseModel = "Comfy-Org/MiniMax-H3"
    nonisolated static let resolutionChoices = [512, 768, 1024]

    /// Host CUDA floor per trainer image, from pod/images/README.md "CUDA and drivers": the
    /// ai-toolkit image carries cu130 wheels and the LTX image cu132 wheels, both needing an R580+
    /// driver, which RunPod reports as CUDA 13.0. The base image alone (vLLM cu129 on CUDA 12.8.1)
    /// would run on 12.x, but the app only rents trainer images.
    nonisolated static let minimumCUDAByTrainer = ["aitoolkit": "13.0", "ltx": "13.0"]

    nonisolated static func minimumCUDA(_ trainer: String) -> String {
        minimumCUDAByTrainer[trainer] ?? "13.0"
    }

    var isH3Training: Bool {
        trainer == "aitoolkit" && baseModel == Self.h3BaseModel
    }

    var hasNativeRecipe: Bool {
        nativeRecipe != nil
    }

    var requiredGPUMemoryGB: Int {
        isH3Training ? 96 : Self.minimumGPUMemoryGB
    }

    func validateH3Computer(_ agent: any PodAgent, gpus: [Int]) async throws {
        let inventory = try await agent.gpus()
        // Provider offers use decimal GB; the agent reports MiB. A 96 GB class GPU can
        // expose less than 96 GiB after firmware reservations (the reference reports 97,887 MiB).
        let minimumMiB = Int((96_000_000_000.0 / 1_048_576).rounded(.up))
        guard !gpus.isEmpty, gpus.allSatisfy({ index in
            inventory.contains { $0.index == index && $0.memoryTotalMiB >= minimumMiB }
        }) else {
            throw StudioError.message("This H3 recipe's known reference used a 96 GB GPU. "
                +
                "Choose a computer with at least that memory before uploading inputs. Fit still depends on the recipe.")
        }
    }

    /// Changes the next run's model; an existing computer keeps its installed trainer image.
    func chooseTrainingModel(_ model: String) {
        guard !isBusy, !isTraining else { return }
        let neededTrainer = model == "Lightricks/LTX-2" ? "ltx" : "aitoolkit"
        guard !hasRunningPod || trainer == neededTrainer else {
            message = "This computer has a different trainer. Stop and remove it before choosing this model."
            return
        }
        trainer = neededTrainer
        baseModel = model
        nativeRecipe = nil
        nativeRecipeOriginal = nil
        initialCheckpoint = nil
        selectAvailableOffer()
    }

    func importTrainingRecipe(from source: URL) throws {
        guard !isBusy, !isTraining, let projectFolder else {
            throw StudioError.message("Open a project and finish the current action before importing a recipe.")
        }
        guard !hasRunningPod || trainer == "aitoolkit" else {
            throw StudioError.message("H3 uses the AI Toolkit trainer. Choose a matching computer first.")
        }
        let recipe = try NativeTrainingRecipe.load(Data(contentsOf: source))
        let folder = projectFolder.appendingPathComponent(".conceptstudio/initializers/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original-recipe." + source.pathExtension)
        try FileManager.default.copyItem(at: source, to: original)
        trainer = "aitoolkit"
        baseModel = Self.h3BaseModel
        nativeRecipe = recipe
        nativeRecipeOriginal = original
        initialCheckpoint = nil
        rank = recipe.rank
        alpha = recipe.alpha
        learningRate = recipe.learningRate
        batchSize = recipe.batchSize
        accumulation = recipe.accumulation
        trainingResolutions = recipe.resolutions
        // Counters and the old target step count never become this new run's target.
        message = "H3 recipe imported. Choose starting LoRA weights to warm-start a new run, "
            + "or train from the base model. Your new training length stays editable."
        selectAvailableOffer()
    }

    func importInitialCheckpoint(from source: URL) async {
        await perform {
            guard let original = self.nativeRecipeOriginal, self.nativeRecipe != nil else {
                throw StudioError.message("Import the matching H3 training recipe before choosing its LoRA weights.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard source.pathExtension == "safetensors", values.isRegularFile == true,
                  values.isSymbolicLink != true, let size = values.fileSize,
                  size > 0, Int64(size) <= LocalTrainingDataset.maximumFileBytes else {
                throw StudioError.message("Choose a regular .safetensors LoRA file of at most 2 GiB.")
            }
            let target = original.deletingLastPathComponent().appendingPathComponent("initial-lora.safetensors")
            try await Task.detached {
                if FileManager.default
                    .fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: source, to: target)
            }.value
            guard self.nativeRecipeOriginal == original else { throw CancellationError() }
            try Task.checkCancellation()
            self.initialCheckpoint = target
            self.message = "Starting weights copied into this project. The next run starts at step zero "
                + "with this project's selected dataset; it does not resume the old run."
        }
    }

    func trainingInitialization() throws -> TrainingInitialization? {
        guard let checkpoint = initialCheckpoint else { return nil }
        guard isH3Training, let recipe = nativeRecipe, let original = nativeRecipeOriginal,
              rank == recipe.rank else {
            throw StudioError.message("Starting LoRA weights require their imported H3 recipe and matching rank. "
                + "Restore the imported rank or remove the starting weights for a new rank.")
        }
        let canonical = original.deletingLastPathComponent().appendingPathComponent("initial-recipe.json")
        try JSONValue.object(recipe.settings).pythonDumpsData().write(to: canonical, options: .atomic)
        return try TrainingInitialization(
            checkpoint: checkpoint,
            recipe: canonical,
            originalRecipe: original,
            loraSHA256: RunArtifacts.sha256(of: checkpoint),
            recipeSHA256: RunArtifacts.sha256(of: canonical)
        )
    }
}
