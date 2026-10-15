import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("training length in epochs")
@MainActor
struct TrainingLengthTests {
    /// AI Toolkit trains each image once per chosen bucket in a pass, so epochs over two buckets take twice the steps,
    /// and Repeat turns the saved steps back into the same epochs.
    @Test func epochsCountEveryResolutionBucket() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel("Qwen/Qwen-Image-2.1")
        workspace.regularizationOn = false
        workspace.steps = 4
        let facts = (profile: "plain", triggers: "NORA7", video: false)
        #expect(workspace.trainingParams(dataset: "concept-one", inputFacts: facts, items: 10)["steps"] == .int(40))
        workspace.trainingResolutions = [768, 1024]
        let params = workspace.trainingParams(dataset: "concept-two", inputFacts: facts, items: 10)
        #expect(params["steps"] == .int(80))
        let run = TrainingRun(
            runID: "concept-two", trainer: "aitoolkit", datasetRepo: "fixture/data", datasetContainsVideo: false,
            itemCount: 10, paramsJSON: JSONValue.object(params).pythonDumpsData(), volumeID: "fixture-storage",
            startedAt: Date(), updatedAt: Date(), podSpendAtStart: 0
        )
        workspace.steps = 1
        workspace.repeatSettings(from: run)
        #expect(workspace.steps == 4)
        #expect(workspace.trainingResolutions == [768, 1024])
    }

    /// Each bucket's last batch is filled on its own: 3 images at two sizes in batches of 2 is 4 batches a pass, not
    /// `ceil(6 / 2)`; with accumulation 2 that is 2 optimizer steps per pass.
    @Test func eachBucketRoundsUpItsOwnLastBatch() {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel("Qwen/Qwen-Image-2.1")
        workspace.regularizationOn = false
        workspace.trainingResolutions = [768, 1024]
        workspace.batchSize = 2
        workspace.steps = 3
        #expect(workspace.optimizerSteps(items: 3) == 12)
        workspace.accumulation = 2
        #expect(workspace.optimizerSteps(items: 3) == 6)
    }
}
