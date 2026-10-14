import ConceptCore
import Foundation

extension GPUWorkspace {
    /// The model id of the row that has the `minimax_h3` native recipe hook.
    nonisolated static let h3BaseModel: String = {
        guard let row = ModelTable.shared.nativeRecipeRow(.minimaxH3) else {
            fatalError("The bundled model table has no row with the minimax_h3 native_recipe hook")
        }
        return row.modelRef
    }()

    /// The guidance target a new selection starts with, and the one a run without guidance settings shows.
    nonisolated static let defaultGuidanceTarget = "3.5"

    /// Every resolution any model offers, for callers that have no row to ask.
    nonisolated static let resolutionChoices: [Int] = Array(
        Set(ModelTable.shared.models.flatMap(\.resolution.choices))
    ).sorted()

    /// Host CUDA floor per trainer image (`trainers.<name>.min_cuda` in the model table). The reasoning is in
    /// pod/images/README.md "CUDA and drivers": the ai-toolkit image carries cu130 wheels and the LTX image
    /// cu132 wheels, both needing an R580+ driver, which RunPod reports as CUDA 13.0. The base image alone
    /// (vLLM cu129 on CUDA 12.8.1) would run on 12.x, but the app only rents trainer images.
    nonisolated static var minimumCUDAByTrainer: [String: String] {
        ModelTable.shared.minimumCUDAByTrainer
    }

    nonisolated static func minimumCUDA(_ trainer: String) -> String {
        ModelTable.shared.minimumCUDA(trainer)
    }

    /// The table's row for the selected trainer and model, if it has one (a custom model has none).
    var exactModelRow: ModelRow? {
        modelTable.exact(trainer: trainer, baseModel: baseModel)
    }

    /// The row whose defaults and capabilities apply: the exact row, else the trainer's default row.
    var effectiveModelRow: ModelRow {
        modelTable.effective(trainer: trainer, baseModel: baseModel)
    }

    var nativeRecipeHook: ModelHooks.NativeRecipe? {
        exactModelRow?.hooks.nativeRecipe
    }

    var isH3Training: Bool {
        nativeRecipeHook == .minimaxH3
    }

    /// The row a native recipe belongs to: the imported recipe's own, else the selected model when it takes one.
    var nativeRecipeRow: ModelRow? {
        if let id = nativeRecipe?.modelID { return modelTable.row(id: id) }
        return exactModelRow.flatMap { $0.hooks.nativeRecipe == nil ? nil : $0 }
    }

    /// The name used in messages about importing a native recipe ("H3"). With no recipe imported and no
    /// recipe model selected, the first model that takes one.
    var nativeRecipeName: String {
        (nativeRecipeRow ?? modelTable.nativeRecipeRows.first)?.shortName ?? "model"
    }

    var hasNativeRecipe: Bool {
        nativeRecipe != nil
    }

    var resolutionChoices: [Int] {
        effectiveModelRow.resolution.choices
    }

    var h3RecipeSettings: JSONObject {
        nativeRecipe?.settings
            ?? runHistory.first(where: { $0.runID == repeatSourceRunID })?.params["extra"]?.objectValue ?? [:]
    }

    var h3UsesTrainingAdapter: Bool {
        h3RecipeSettings["model"]?.objectValue?["use_training_adapter"]?.boolValue ?? true
    }

    nonisolated static func validateH3Guidance(settings: JSONObject, guidanceLoss: Bool) throws {
        guard !guidanceLoss || settings["model"]?.objectValue?["use_training_adapter"]?.boolValue == false else {
            throw StudioError.message("The Circlestone H3 training adapter requires guidance preservation loss "
                + "to stay off. Import a native recipe with use_training_adapter: false to train without it.")
        }
    }

    nonisolated static func validateH3Guidance(_ run: TrainingRun, table: ModelTable = .shared) throws {
        guard let hook = run.modelRow(in: table)?.hooks.nativeRecipe else { return }
        let settings = run.params["extra"]?.objectValue ?? [:]
        try hook.validateGuidance(
            settings: settings,
            guidanceLoss: settings["train"]?.objectValue?["do_guidance_loss"]?.boolValue ?? false
        )
    }

    /// The smallest GPU memory, in decimal GB, the selected model's computer must offer.
    var requiredGPUMemoryGB: Int {
        effectiveModelRow.gpu.minVRAMGB
    }

    /// The sentence under "Choose a training computer".
    var computerSubtitle: String {
        let row = effectiveModelRow
        return "A GPU is the part that does the training. These have at least "
            + "\(row.gpu.minVRAMGB) GB of memory per GPU. " + row.gpu.note
    }

    /// The Run settings field and the words around it: steps, or epochs for a model that counts those.
    var trainingLengthLabel: String {
        effectiveModelRow.recipe.lengthUnit == .epochs ? "Training epochs" : "Training steps"
    }

    var trainingLengthHelp: String {
        effectiveModelRow.recipe.lengthUnit == .epochs
            ? "Enter how many times training passes over each image or clip, such as 100. "
            + "The app turns this into training steps for your dataset."
            : "Enter a positive whole number of training updates, such as 3000."
    }

    var trainingLengthSubtitle: String {
        effectiveModelRow.recipe.lengthUnit == .epochs
            ? "An epoch is one pass over every image and clip. More epochs take longer; "
            + "compare saved checkpoints to find the best result."
            : "A training step updates the model using a batch of your examples. More steps take longer; "
            + "compare saved checkpoints to find the best result."
    }

    /// One choice in the training model picker.
    struct TrainingModelOption: Equatable {
        let tag: String
        let label: String
    }

    /// The picker's choices in table order; a model that matches no row is shown last as custom.
    var trainingModelOptions: [TrainingModelOption] {
        var options = modelTable.models.map { TrainingModelOption(tag: $0.modelRef, label: $0.pickerTitle) }
        if modelTable.row(modelRef: baseModel) == nil {
            options.append(TrainingModelOption(tag: baseModel, label: "Custom · \(baseModel)"))
        }
        return options
    }

    /// What the picker tells the person about the selected model before they train it.
    struct TrainingModelDisclosure: Equatable {
        let notice: String
        let licenseName: String
        let licenseURL: String
        let download: String
    }

    /// The selected model's licence notice and the size of its first download, for a model whose notice is on.
    /// Nil for the others, which lay out as a bare picker.
    var trainingModelDisclosure: TrainingModelDisclosure? {
        guard let row = exactModelRow, row.license.showNotice else { return nil }
        return TrainingModelDisclosure(
            notice: row.license.notice, licenseName: row.license.name, licenseURL: row.license.url,
            download: "The first run downloads about \(String(format: "%.1f", row.source.firstDownloadGB)) GB "
                + "of model files to the computer."
        )
    }

    /// Why a comparison cannot use `frames` for this run, or nil when it can. A model without preview
    /// clips generates one frame whatever is asked, so any count passes.
    nonisolated static func generationFramesError(
        run: TrainingRun, frames: Int, table: ModelTable = .shared
    ) -> String? {
        guard let row = run.modelRow(in: table), let clips = row.preview.video, let video = row.video else {
            return nil
        }
        if row.preview.still, frames == 1 { return nil }
        if frames >= clips.minFrames, frames <= clips.maxFrames, frames >= video.first,
           (frames - video.first) % video.step == 0 { return nil }
        let largest = video.first + (clips.maxFrames - video.first) / video.step * video.step
        return "\(row.shortName) video length must be \(video.step)n + \(video.first) frames, "
            + "from \(clips.minFrames) through \(largest)" + (video.fixedFPS.map { ", at \($0) fps" } ?? "") + "."
    }

    /// Refuses a computer whose GPUs report less memory than the row's reference. The provider's offers use
    /// decimal GB and the agent reports MiB; a 96 GB class GPU can expose less than 96 GiB after firmware
    /// reservations (the H3 reference reports 97,887 MiB).
    func verifyGPUMemory(_ agent: any PodAgent, gpus: [Int], row: ModelRow) async throws {
        let inventory: [AgentGPU]
        do {
            inventory = try await agent.gpus()
        } catch is AgentCannotReportGPUMemory {
            throw StudioError.message(
                "This agent cannot report GPU memory. Update its training image before using \(row.shortName)."
            )
        }
        let minimumMiB = Int((Double(row.gpu.minVRAMGB) * 1_000_000_000 / 1_048_576).rounded(.up))
        guard !gpus.isEmpty, gpus.allSatisfy({ index in
            inventory.contains { $0.index == index && $0.memoryTotalMiB >= minimumMiB }
        }) else {
            throw StudioError.message(row.gpu.verifyMessage
                ?? "Choose a computer with at least \(row.gpu.minVRAMGB) GB of memory per GPU.")
        }
    }

    /// The model a caption profile trains by default: the row whose `profile_prefix` starts it, else the default.
    nonisolated static func projectModel(forProfile profile: String) -> String {
        ModelTable.shared.row(forProfile: profile).modelRef
    }

    /// Changes the next run's model; an existing computer keeps its installed trainer image.
    func chooseTrainingModel(_ model: String) {
        guard !isBusy, !isTraining, model != baseModel else { return }
        let neededRow = modelTable.row(modelRef: model) ?? modelTable.defaultRow
        guard !hasRunningPod || trainer == neededRow.trainer else {
            message = "This computer has a different trainer. Stop and remove it before choosing this model."
            return
        }
        // The rental filter used the current model's GPU floor; a running computer may not meet a higher one.
        // Rows that verify memory on the pod check the actual GPU before training instead.
        guard !hasRunningPod || neededRow.gpu.verifyOnPod || neededRow.gpu.minVRAMGB <= requiredGPUMemoryGB else {
            message = "\(neededRow.shortName) needs at least \(neededRow.gpu.minVRAMGB) GB of memory per GPU, "
                + "more than this computer was chosen for. Stop and remove it before choosing this model."
            return
        }
        let previous = effectiveModelRow.recipe
        trainer = neededRow.trainer
        baseModel = model
        nativeRecipe = nil
        nativeRecipeOriginal = nil
        initialCheckpoint = nil
        let row = effectiveModelRow
        adoptDefaults(from: previous, to: row.recipe)
        adoptTrainingAidDefaults(to: row)
        checkpointEvery = row.recipe.checkpoints.every
        checkpointRetention = row.recipe.checkpoints.keep
        checkpointPrecision = modelTable.checkpointPrecision(for: row)
        trainingResolutions = row.resolution.defaults
        guidanceLoss = false
        if let hook = exactModelRow?.hooks.nativeRecipe { guidanceTargetText = hook.defaultGuidanceTarget }
        selectAvailableOffer()
    }

    /// Moves the run settings to the new model's defaults, but only those still at the old model's defaults:
    /// a value the person edited stays. A length in another unit is not comparable, so it always moves.
    private func adoptDefaults(from old: ModelRow.Recipe, to new: ModelRow.Recipe) {
        if old.lengthUnit != new.lengthUnit || steps == old.length { steps = new.length }
        if rank == old.rank { rank = new.rank }
        if alpha == old.alpha { alpha = new.alpha }
        if batchSize == old.batchSize { batchSize = new.batchSize }
        if accumulation == old.gradientAccumulation { accumulation = new.gradientAccumulation }
        if learningRate == old.learningRate { learningRate = new.learningRate }
    }

    nonisolated static func validGuidanceTarget(_ value: JSONValue) -> Bool {
        if let number = value.doubleValue { return number.isFinite && number >= 0 && number <= 20 }
        if let values = value.arrayValue {
            return values.count == 2 && values.allSatisfy {
                $0.doubleValue.map { $0.isFinite && $0 >= 0 && $0 <= 20 } == true
            }
        }
        return false
    }

    /// Imports a native recipe for `recipeRow`, the model whose recipe import the user opened.
    func importTrainingRecipe(from source: URL, row recipeRow: ModelRow) throws {
        guard !isBusy, !isTraining, let projectFolder else {
            throw StudioError.message("Open a project and finish the current action before importing a recipe.")
        }
        guard !hasRunningPod || trainer == recipeRow.trainer else {
            throw StudioError.message(
                "\(recipeRow.shortName) uses the AI Toolkit trainer. Choose a matching computer first."
            )
        }
        let recipe = try NativeTrainingRecipe.load(Data(contentsOf: source), row: recipeRow, table: modelTable)
        let folder = projectFolder.appendingPathComponent(".conceptstudio/initializers/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original-recipe." + source.pathExtension)
        try FileManager.default.copyItem(at: source, to: original)
        trainer = recipeRow.trainer
        baseModel = recipeRow.modelRef
        nativeRecipe = recipe
        nativeRecipeOriginal = original
        initialCheckpoint = nil
        rank = recipe.rank
        alpha = recipe.alpha
        learningRate = recipe.learningRate
        batchSize = recipe.batchSize
        accumulation = recipe.accumulation
        trainingResolutions = recipe.resolutions
        checkpointEvery = recipe.checkpointEvery
        checkpointRetention = recipe.checkpointRetention
        checkpointPrecision = recipe.checkpointPrecision
        guidanceLoss = recipe.guidanceLoss
        guidanceTargetText = String(data: recipe.guidanceTarget.pythonDumpsData(), encoding: .utf8)
            ?? Self.defaultGuidanceTarget
        // Counters and the old target step count never become this new run's target.
        message = "\(recipeRow.shortName) recipe imported. Choose starting LoRA weights to warm-start a new run, "
            + "or train from the base model. Your new training length stays editable."
        selectAvailableOffer()
    }

    func importInitialCheckpoint(from source: URL) async {
        await perform {
            guard let original = self.nativeRecipeOriginal, self.nativeRecipe != nil else {
                throw StudioError.message(
                    "Import the matching \(self.nativeRecipeName) training recipe before choosing its LoRA weights."
                )
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
        guard nativeRecipeHook != nil, let recipe = nativeRecipe, let original = nativeRecipeOriginal,
              rank == recipe.rank else {
            throw StudioError.message("Starting LoRA weights require their imported \(nativeRecipeName) recipe "
                + "and matching rank. Restore the imported rank or remove the starting weights for a new rank.")
        }
        let canonical = original.deletingLastPathComponent().appendingPathComponent("initial-recipe.json")
        // Initializer files bind model/network quality to starting weights. Editable save
        // and guidance-target settings travel in run.extra, which the published trainer
        // already merges after the initializer. Keep that existing four-section wire shape.
        var initializer = recipe.settings
        initializer.removeValue(forKey: "save")
        var train = initializer["train"]?.objectValue ?? [:]
        train.removeValue(forKey: "guidance_loss_target")
        initializer["train"] = .object(train)
        try JSONValue.object(initializer).pythonDumpsData().write(to: canonical, options: .atomic)
        return try TrainingInitialization(
            checkpoint: checkpoint,
            recipe: canonical,
            originalRecipe: original,
            loraSHA256: RunArtifacts.sha256(of: checkpoint),
            recipeSHA256: RunArtifacts.sha256(of: canonical)
        )
    }
}

// MARK: - Hooks

extension ModelHooks.NativeRecipe {
    /// The guidance target a new selection of the model starts with.
    var defaultGuidanceTarget: String {
        switch self {
        case .minimaxH3: GPUWorkspace.defaultGuidanceTarget
        }
    }

    /// The model's guidance rules: guidance preservation loss may only be on when no training adapter is used.
    func validateGuidance(settings: JSONObject, guidanceLoss: Bool) throws {
        switch self {
        case .minimaxH3: try GPUWorkspace.validateH3Guidance(settings: settings, guidanceLoss: guidanceLoss)
        }
    }

    func validGuidanceTarget(_ value: JSONValue) -> Bool {
        switch self {
        case .minimaxH3: GPUWorkspace.validGuidanceTarget(value)
        }
    }
}

extension ModelHooks.RunExtra {
    /// The trainer's `extra` object for these inputs, starting from the row's `trainer_options.run_extra`.
    func apply(to extra: JSONObject, containsVideo: Bool) -> JSONObject {
        switch self {
        case .ltxVideoBuckets:
            guard containsVideo else { return extra }
            var extra = extra
            extra["preprocess"] = .object([
                "buckets_from_media": .bool(true),
                "args": extra["preprocess"]?.objectValue?["args"] ?? .array([]),
            ])
            return extra
        }
    }
}
