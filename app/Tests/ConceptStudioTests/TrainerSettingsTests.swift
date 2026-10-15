import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("trainer settings in run.json")
@MainActor
struct TrainerSettingsTests {
    private static let qwen = "Qwen/Qwen-Image-2.1"
    private static let flux = "black-forest-labs/FLUX.1-dev"

    private func params(_ workspace: GPUWorkspace, _ id: String = "concept-source") -> JSONObject {
        workspace.trainingParams(dataset: id, inputFacts: ("plain", "NORA7", false), items: 10)
    }

    private func savedRun(_ params: JSONObject) -> TrainingRun {
        TrainingRun(
            runID: "concept-source", trainer: "aitoolkit", datasetRepo: "fixture/data",
            datasetContainsVideo: false, itemCount: 10, paramsJSON: JSONValue.object(params).pythonDumpsData(),
            volumeID: "fixture-storage", startedAt: Date(), updatedAt: Date(), podSpendAtStart: 0
        )
    }

    /// A value at the model's default sends nothing; a changed one travels, survives a model change and repeats.
    @Test func onlyChangedSettingsTravelAndRepeat() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel(Self.qwen)
        #expect(params(workspace)["caption_dropout"] == nil)
        #expect(params(workspace)["gradient_checkpointing"] == nil)
        workspace.trainerSettings.captionDropout = 0.1
        workspace.trainerSettings.gradientCheckpointing = true
        let changed = params(workspace)
        #expect(changed["caption_dropout"] == .double(0.1))
        #expect(changed["gradient_checkpointing"] == .bool(true))
        workspace.chooseTrainingModel(Self.flux)
        #expect(workspace.trainerSettings.captionDropout == 0.1)
        #expect(params(workspace)["gradient_checkpointing"] == nil)
        workspace.trainerSettings.captionDropout = 0.05
        let run = savedRun(changed)
        workspace.runHistory = [run]
        workspace.repeatSettings(from: run)
        let repeated = params(workspace, "concept-repeat")
        #expect(repeated["caption_dropout"] == .double(0.1))
        #expect(repeated["gradient_checkpointing"] == .bool(true))
    }

    /// Qwen-Image-2.1 trains without checkpointing at its default 768 px; adding the 1024 px bucket turns it on.
    @Test func aBucketAboveTheModelsDefaultsTurnsCheckpointingOn() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel(Self.qwen)
        workspace.selectResolution(512, selected: true)
        #expect(params(workspace)["gradient_checkpointing"] == nil)
        workspace.selectResolution(1024, selected: true)
        #expect(workspace.trainingResolutions == [512, 768, 1024])
        #expect(params(workspace)["gradient_checkpointing"] == .bool(true))
        workspace.trainerSettings.gradientCheckpointing = false
        workspace.selectResolution(512, selected: false)
        #expect(params(workspace)["gradient_checkpointing"] == nil)
    }

    /// The pod keeps the row's warmup and takes one only with the warmup schedule, so the app sends warmup steps only
    /// with that schedule and only when they differ from the row's.
    @Test func warmupTravelsOnlyWithTheWarmupSchedule() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel(Self.qwen)
        #expect(workspace.trainerSettings.lrScheduler == "constant_with_warmup")
        workspace.trainerSettings.lrWarmupSteps = 100
        #expect(params(workspace)["lr_warmup_steps"] == .int(100))
        workspace.trainerSettings.lrScheduler = "cosine"
        #expect(params(workspace)["lr_scheduler"] == .string("cosine"))
        #expect(params(workspace)["lr_warmup_steps"] == nil)
        workspace.chooseTrainingModel(Self.flux)
        #expect(workspace.trainerSettings.lrScheduler == "constant")
        workspace.trainerSettings.lrScheduler = "constant_with_warmup"
        let flux = params(workspace)
        #expect(flux["lr_scheduler"] == .string("constant_with_warmup"))
        #expect(flux["lr_warmup_steps"] == nil)
    }

    /// A row whose `trainer_config` hook builds its own recipe takes none of them.
    @Test func hookRecipeTakesNoTrainerSettings() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.trainerSettings.captionDropout = 0.3
        workspace.chooseTrainingModel(GPUWorkspace.h3BaseModel)
        #expect(!workspace.editsTrainerSettings)
        #expect(params(workspace)["caption_dropout"] == nil)
    }
}
