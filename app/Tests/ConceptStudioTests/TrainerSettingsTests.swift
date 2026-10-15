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
        workspace.captionDropout = 0.1
        let changed = params(workspace)
        #expect(changed["caption_dropout"] == .double(0.1))
        workspace.chooseTrainingModel(Self.flux)
        #expect(workspace.captionDropout == 0.1)
        workspace.captionDropout = 0.05
        let run = savedRun(changed)
        workspace.runHistory = [run]
        workspace.repeatSettings(from: run)
        #expect(params(workspace, "concept-repeat")["caption_dropout"] == .double(0.1))
    }

    /// A row whose `trainer_config` hook builds its own recipe takes none of them.
    @Test func hookRecipeTakesNoTrainerSettings() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.captionDropout = 0.3
        workspace.chooseTrainingModel(GPUWorkspace.h3BaseModel)
        #expect(!workspace.editsTrainerSettings)
        #expect(params(workspace)["caption_dropout"] == nil)
    }
}
