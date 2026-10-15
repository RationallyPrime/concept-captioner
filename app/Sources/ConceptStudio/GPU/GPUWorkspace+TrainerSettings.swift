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

    /// run.json's trainer settings (POD-SPEC 4.1), in the order Advanced shows them.
    static let keys = ["caption_dropout", "gradient_checkpointing"]

    init(_ row: ModelRow) {
        captionDropout = row.recipe.captionDropout ?? 0
        gradientCheckpointing = row.architecture.gradientCheckpointing
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
        return values
    }

    /// Moves to a newly chosen model's defaults. Caption dropout follows only while it is still at the old model's
    /// default, as rank and learning rate do; gradient checkpointing belongs to the model's memory recipe, so it always
    /// takes the new model's.
    mutating func adopt(from old: ModelRow, to new: ModelRow) {
        let fresh = TrainerSettings(new)
        if old.recipe.captionDropout == nil || captionDropout == old.recipe.captionDropout {
            captionDropout = fresh.captionDropout
        }
        gradientCheckpointing = fresh.gradientCheckpointing
    }

    /// A saved run's settings; one the run left to its model takes `row`'s value.
    init(restoring params: JSONObject, row: ModelRow) {
        self.init(row)
        captionDropout = params["caption_dropout"]?.doubleValue ?? captionDropout
        gradientCheckpointing = params["gradient_checkpointing"]?.boolValue ?? gradientCheckpointing
    }

    static func line(_ key: String, _ value: JSONValue) -> String {
        switch key {
        case "caption_dropout": "Caption dropout: " + String(format: "%g", value.doubleValue ?? 0)
        case "gradient_checkpointing": "Gradient checkpointing " + (value.boolValue == true ? "on" : "off")
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

    func validateTrainerSettings() throws {
        guard editsTrainerSettings else { return }
        let dropout = trainerSettings.captionDropout
        guard dropout.isFinite, dropout >= 0, dropout <= 1 else {
            throw StudioError.message("Choose a caption dropout from 0 to 1.")
        }
    }
}

extension TrainingRun {
    /// One line per trainer setting the run set itself rather than leaving to its model.
    var trainerSettingSummary: [String] {
        TrainerSettings.keys.compactMap { key in params[key].map { TrainerSettings.line(key, $0) } }
    }
}
