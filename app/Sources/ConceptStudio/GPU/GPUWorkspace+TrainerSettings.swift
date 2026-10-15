import ConceptCore
import Foundation

// Trainer settings a person can change in Advanced, each defaulting to the selected model's row (docs/model-table.md)
// and sent as run.json's own fields (POD-SPEC 4.1). They exist for AI Toolkit rows whose recipe the pod builds from the
// row; a row with a `trainer_config` hook builds its whole recipe itself, and the LTX trainer takes its settings
// through `extra`. A field is sent only when its value differs from the row's: an absent field means the row's value,
// so a run that changes nothing sends the run.json it always sent.

/// The next run's trainer settings, starting from a row's values.
struct TrainerSettings: Equatable {
    /// The share of training images seen without their caption (`recipe.caption_dropout`).
    var captionDropout: Double
    /// Recompute activations instead of keeping them (`architecture.gradient_checkpointing`).
    var gradientCheckpointing: Bool
    /// AI Toolkit's optimizer name (`recipe.optimizer`).
    var optimizer: String
    /// One of `schedulers` (`recipe.lr_scheduler`).
    var lrScheduler: String
    /// Steps at the start that ramp the learning rate up; only the warmup schedule has them.
    var lrWarmupSteps: Int

    /// run.json's trainer settings (POD-SPEC 4.1), in the order Advanced shows them.
    static let keys = ["caption_dropout", "gradient_checkpointing", "optimizer", "lr_scheduler", "lr_warmup_steps"]
    /// The optimizers Advanced offers, the two the verified recipes use; a saved run's other name stays selectable.
    static let optimizers = [("adamw8bit", "AdamW 8-bit · less memory"), ("adamw", "AdamW · full precision")]
    /// The schedules the pod accepts, with the names Advanced shows.
    static let schedulers = [
        ("constant", "Constant"), (warmupScheduler, "Constant after a warmup"), ("cosine", "Cosine decay to zero"),
    ]
    static let warmupScheduler = "constant_with_warmup"

    init(_ row: ModelRow) {
        captionDropout = row.recipe.captionDropout ?? 0
        gradientCheckpointing = row.architecture.gradientCheckpointing
        optimizer = row.recipe.optimizer
        lrScheduler = row.recipe.lrScheduler ?? "constant"
        lrWarmupSteps = row.recipe.lrWarmupSteps ?? 0
    }

    var usesWarmup: Bool {
        lrScheduler == Self.warmupScheduler
    }

    /// The run.json fields whose values differ from `row`'s.
    func overrides(of row: ModelRow) -> JSONObject {
        var values = JSONObject()
        if let standard = row.recipe.captionDropout, captionDropout != standard {
            values["caption_dropout"] = .double(captionDropout)
        }
        if gradientCheckpointing != row.architecture.gradientCheckpointing {
            values["gradient_checkpointing"] = .bool(gradientCheckpointing)
        }
        if optimizer != row.recipe.optimizer { values["optimizer"] = .string(optimizer) }
        if let standard = row.recipe.lrScheduler, lrScheduler != standard {
            values["lr_scheduler"] = .string(lrScheduler)
        }
        // The pod keeps the row's warmup when none is sent, and takes a warmup only with the warmup schedule.
        if usesWarmup, lrWarmupSteps != (row.recipe.lrWarmupSteps ?? 0) {
            values["lr_warmup_steps"] = .int(lrWarmupSteps)
        }
        return values
    }

    /// Moves to a newly chosen model's defaults. Caption dropout follows only while it is still at the old model's
    /// default, as rank and learning rate do; the rest belongs to the model's own recipe (memory, optimizer and its
    /// schedule), so it always takes the new model's.
    mutating func adopt(from old: ModelRow, to new: ModelRow) {
        let kept = captionDropout
        self = TrainerSettings(new)
        if old.recipe.captionDropout != nil, kept != old.recipe.captionDropout { captionDropout = kept }
    }

    /// A saved run's settings; one the run left to its model takes `row`'s value.
    init(restoring params: JSONObject, row: ModelRow) {
        self.init(row)
        captionDropout = params["caption_dropout"]?.doubleValue ?? captionDropout
        gradientCheckpointing = params["gradient_checkpointing"]?.boolValue ?? gradientCheckpointing
        optimizer = params["optimizer"]?.stringValue ?? optimizer
        lrScheduler = params["lr_scheduler"]?.stringValue ?? lrScheduler
        lrWarmupSteps = params["lr_warmup_steps"]?.intValue ?? lrWarmupSteps
    }

    static func line(_ key: String, _ value: JSONValue) -> String {
        switch key {
        case "caption_dropout": "Caption dropout: " + String(format: "%g", value.doubleValue ?? 0)
        case "gradient_checkpointing": "Gradient checkpointing " + (value.boolValue == true ? "on" : "off")
        case "optimizer": "Optimizer: " + (value.stringValue ?? "")
        case "lr_scheduler":
            "Learning-rate schedule: "
                + (schedulers.first { $0.0 == value.stringValue }?.1 ?? value.stringValue ?? "")
        case "lr_warmup_steps": "Warmup steps: \(value.intValue ?? 0)"
        default: "\(key): \(value)"
        }
    }
}

extension GPUWorkspace {
    /// Whether Advanced offers the trainer settings for the selected model.
    var editsTrainerSettings: Bool {
        trainer == "aitoolkit" && exactModelRow?.hooks.trainerConfig == nil
    }

    /// run.json's trainer settings for the next run: each one the person moved away from the model's default.
    var trainerSettingOverrides: JSONObject {
        editsTrainerSettings ? trainerSettings.overrides(of: effectiveModelRow) : [:]
    }

    /// The Advanced summary's lines for the trainer settings that differ from the model's defaults.
    var trainerSettingOverrideLines: [String] {
        trainerSettingOverrides.pairs.map { TrainerSettings.line($0.key, $0.value) }
    }

    /// Adds or removes one image bucket. A bucket larger than the model's own default sizes, on a model that trains
    /// without gradient checkpointing, turns checkpointing on: the row's memory figures hold only for its default
    /// sizes (Qwen-Image-2.1 at 1024 px on a 96 GB card). Advanced can still turn it off again.
    func selectResolution(_ resolution: Int, selected: Bool) {
        trainingResolutions.removeAll { $0 == resolution }
        if selected { trainingResolutions.append(resolution) }
        trainingResolutions.sort()
        let row = effectiveModelRow
        if selected, editsTrainerSettings, !row.architecture.gradientCheckpointing,
           resolution > (row.resolution.defaults.max() ?? 0) {
            trainerSettings.gradientCheckpointing = true
        }
    }

    func validateTrainerSettings() throws {
        guard editsTrainerSettings else { return }
        let dropout = trainerSettings.captionDropout
        guard dropout.isFinite, dropout >= 0, dropout <= 1 else {
            throw StudioError.message("Choose a caption dropout from 0 to 1.")
        }
        guard TrainerSettings.schedulers.contains(where: { $0.0 == trainerSettings.lrScheduler }),
              trainerSettings.lrWarmupSteps >= 0, !trainerSettings.optimizer.isEmpty else {
            throw StudioError.message("Choose an optimizer, a learning-rate schedule and zero or more warmup steps.")
        }
    }
}

extension TrainingRun {
    /// One line per trainer setting the run set itself rather than leaving to its model.
    var trainerSettingSummary: [String] {
        TrainerSettings.keys.compactMap { key in params[key].map { TrainerSettings.line(key, $0) } }
    }
}
