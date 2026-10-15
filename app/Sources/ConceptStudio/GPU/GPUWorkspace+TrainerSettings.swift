import ConceptCore
import Foundation

// Trainer settings a person can change in Advanced, each defaulting to the selected model's row (docs/model-table.md)
// and sent as run.json's own fields (POD-SPEC 4.1). They exist for AI Toolkit rows whose recipe the pod builds from the
// row; a row with a `trainer_config` hook builds its whole recipe itself, and the LTX trainer takes its settings
// through `extra`. A field is sent only when its value differs from the row's: an absent field means the row's value,
// so a run that changes nothing sends the run.json it always sent.

extension GPUWorkspace {
    /// Whether Advanced offers the trainer settings for the selected model.
    var editsTrainerSettings: Bool {
        trainer == "aitoolkit" && exactModelRow?.hooks.trainerConfig == nil
    }

    /// run.json's trainer settings for the next run: each one the person moved away from the model's default.
    var trainerSettingOverrides: JSONObject {
        guard editsTrainerSettings else { return [:] }
        let recipe = effectiveModelRow.recipe
        var values = JSONObject()
        if let standard = recipe.captionDropout, captionDropout != standard {
            values["caption_dropout"] = .double(captionDropout)
        }
        return values
    }

    /// The Advanced summary's lines for the trainer settings that differ from the model's defaults.
    var trainerSettingOverrideLines: [String] {
        trainerSettingOverrides.pairs.map { TrainingRun.trainerSettingLine($0.key, $0.value) }
    }

    /// Moves the trainer settings to a newly chosen model's defaults. Caption dropout follows only while it is still at
    /// the old model's default, as rank and learning rate do.
    func adoptTrainerSettingDefaults(from old: ModelRow, to new: ModelRow) {
        if captionDropout == old.recipe.captionDropout || old.recipe.captionDropout == nil {
            captionDropout = new.recipe.captionDropout ?? captionDropout
        }
    }

    /// Restores the trainer settings from a saved run; a setting the run left to its model takes the model's default.
    func restoreTrainerSettings(from run: TrainingRun, row: ModelRow) {
        captionDropout = run.params["caption_dropout"]?.doubleValue ?? row.recipe.captionDropout ?? captionDropout
    }

    func validateTrainerSettings() throws {
        guard editsTrainerSettings else { return }
        guard captionDropout.isFinite, captionDropout >= 0, captionDropout <= 1 else {
            throw StudioError.message("Choose a caption dropout from 0 to 1.")
        }
    }
}

extension TrainingRun {
    /// One line per trainer setting the run set itself rather than leaving to its model.
    var trainerSettingSummary: [String] {
        ["caption_dropout"].compactMap { key in params[key].map { Self.trainerSettingLine(key, $0) } }
    }

    static func trainerSettingLine(_ key: String, _ value: JSONValue) -> String {
        switch key {
        case "caption_dropout": "Caption dropout: " + String(format: "%g", value.doubleValue ?? 0)
        default: "\(key): \(value)"
        }
    }
}
