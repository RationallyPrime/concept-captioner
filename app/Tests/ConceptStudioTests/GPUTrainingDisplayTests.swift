import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Training and Monitor explanations")
@MainActor
struct GPUTrainingDisplayTests {
    private func workspace(_ defaults: UserDefaults) -> GPUWorkspace {
        makeWorkspace(GPUTransport(), defaults)
    }

    @Test func emptyCurveDistinguishesNoRunLoadingEndedAndDisconnected() throws {
        let (defaults, suite) = try temporaryPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gpu = workspace(defaults)
        gpu.pod = RentedPod(id: "fixture", status: "RUNNING", cost: 0, gpu: .init(count: 1))
        #expect(gpu.curveDisplay == .noRun)
        #expect(gpu.trainingStatus == "Not started")
        gpu.runID = "fixture-run"
        gpu.trainingState = "running"
        #expect(gpu.curveDisplay == .waiting)
        gpu.trainingState = "exited"
        #expect(gpu.curveDisplay == .ended)
        #expect(!gpu.curveDisplay.explanation.contains("Start a run"))
        gpu.trainingState = "running"
        gpu.pod = nil
        #expect(gpu.curveDisplay == .disconnected)
        #expect(gpu.trainingStatus == "Not connected")
        gpu.result = TrainingResult(
            runID: gpu.runID, outputRepo: "", destination: .download, volumeID: "storage", state: .pending
        )
        #expect(gpu.curveDisplay == .ended)
        #expect(gpu.trainingStatus == "Finished")
        gpu.result?.state = .failed
        #expect(gpu.curveDisplay == .failed)
        gpu.points = [.init(step: 1, loss: 0.1)]
        #expect(gpu.curveDisplay == .available)
    }

    @Test func computerRunningDoesNotClaimThatTrainingHasStartedOrContinuesAfterStop() throws {
        let (defaults, suite) = try temporaryPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gpu = workspace(defaults)
        gpu.pod = RentedPod(id: "fixture", status: "RUNNING", cost: 0, gpu: .init(count: 1))
        #expect(gpu.computerStatus == "Running" && gpu.trainingStatus == "Not started")
        gpu.runID = "fixture-run"
        gpu.trainingState = "running"
        #expect(gpu.trainingStatus == "In progress")
        gpu.pod = RentedPod(id: "fixture", status: "EXITED", cost: 0, gpu: .init(count: 1))
        #expect(gpu.computerStatus == "Stopped" && gpu.trainingStatus == "Stopped")
        #expect(gpu.curveDisplay == .stopped)
    }

    @Test func hostedAndCustomCaptioningPlansUseActualServiceStateAndSeparateReviewerRoute() throws {
        let (defaults, suite) = try temporaryPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: defaults, secrets: MemorySecretStore())
        session.gpu = workspace(defaults)
        session.gpu.plan = TrainingPlan(mode: "sequential", caption: .init(gpus: [0]), train: .init(gpus: [0]))
        session.endpointKind = "google"
        session.gpu.captionServerActive = false
        let hosted = session.trainingPlanExplanation
        #expect(hosted.contains("Google Gemini") && hosted.contains("Training can use the GPU directly"))
        #expect(!hosted.contains("Finish captioning") && !hosted.contains("stops that model"))
        session.gpu.captionServerActive = true
        #expect(session.trainingPlanExplanation.contains("A caption model is running"))
        #expect(session.trainingPlanExplanation.contains("Starting training stops that model"))
        session.gpu.captionServerActive = nil
        #expect(session.trainingPlanExplanation.contains("only if one is running"))
        session.endpointKind = "vllm"
        #expect(session.trainingPlanExplanation.contains("your custom server"))
        #expect(!session.trainingPlanExplanation.contains("Finish captioning"))
        session.endpointKind = "google"
        session.usingPodCaptioner = true
        session.useCritic = true
        session.criticKind = "vllm"
        #expect(session.trainingPlanExplanation.contains("Captioning uses Google Gemini"))
        #expect(session.trainingPlanExplanation.contains("caption reviewer uses this computer"))
        #expect(session.trainingPlanExplanation.contains("Finish captioning or review work"))
    }

    @Test func multiGPUPlanShowsActualAssignmentsAndDoesNotPromiseAnUnstartedCaptionServer() throws {
        let (defaults, suite) = try temporaryPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: defaults, secrets: MemorySecretStore())
        session.gpu = workspace(defaults)
        session.gpu.plan = TrainingPlan(
            mode: "concurrent", caption: .init(gpus: [0]), train: .init(gpus: [1, 2, 3])
        )
        session.endpointKind = "vllm"
        session.usingPodCaptioner = true
        session.gpu.captionServerActive = false
        #expect(session.trainingPlanExplanation.contains("Training uses GPUs 1, 2, 3"))
        #expect(session.trainingPlanExplanation.contains("No pod caption model is started"))
        #expect(session.trainingPlanExplanation.contains("Start its model from Captioning"))
        session.gpu.keepCaptionServer = true
        #expect(session.trainingPlanExplanation.contains("start a pod caption model on GPU 0"))
        session.gpu.captionServerActive = true
        #expect(session.trainingPlanExplanation.contains("existing pod caption model stays on GPU 0"))
    }

    @Test func serviceCacheComesFromFetchedAgentServicesAndResetsForAnotherOrStoppedComputer() async throws {
        let (defaults, suite) = try temporaryPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let gpu = makeWorkspace(transport, defaults)
        #expect(gpu.captionServerActive == nil)
        try gpu.configure(runpodKey: "fixture", hubToken: "fixture", imageName: "fixture")
        await gpu.refreshOffers()
        await gpu.rent()
        gpu.monitorTask?.cancel()
        await gpu.monitorTask?.value
        await gpu.refresh()
        #expect(gpu.captionServerActive == false)
        #expect(await gpu.startCaptioning())
        await gpu.refresh()
        #expect(gpu.captionServerActive == true)
        await transport.finish("vllm", state: "stopped")
        await gpu.refresh()
        #expect(gpu.captionServerActive == false)
        let requests = await transport.agentRequests.count
        _ = gpu.computerStatus
        _ = gpu.trainingStatus
        _ = gpu.curveDisplay
        #expect(await transport.agentRequests.count == requests)
        gpu.pod = RentedPod(id: "another", status: "RUNNING", cost: 0, gpu: .init(count: 1))
        #expect(gpu.captionServerActive == nil)
        gpu.captionServerActive = true
        gpu.pod = RentedPod(id: "another", status: "EXITED", cost: 0, gpu: .init(count: 1))
        #expect(gpu.captionServerActive == false)
    }

    @Test func savedRunExplainsCurrentLocalDataPinnedDataAndUnrecordedDataWithoutHidingExactInputs() {
        var run = TrainingRun(
            runID: "fixture-run", trainer: "aitoolkit", datasetRepo: "fixture/images", datasetRevision: "pinned",
            datasetContainsVideo: false, paramsJSON: JSONValue.object([:]).pythonDumpsData(),
            volumeID: "storage", startedAt: Date(), updatedAt: Date(), result: nil, podSpendAtStart: 0
        )
        #expect(run.newRunExplanation.contains("saved version of the published training data"))
        run.datasetRevision = nil
        #expect(run.newRunExplanation.contains("latest data in this dataset"))
        run.localInputDigest = "fixture-digest"
        #expect(run.newRunExplanation.contains("current included media and saved captions"))
        #expect(run.localInputDigest == "fixture-digest" && run.volumeID == "storage")
        run.result = TrainingResult(
            runID: run.runID, outputRepo: "fixture/model", destination: .hub, volumeID: run.volumeID,
            state: .pushed(repo: "fixture/model")
        )
        #expect(run.resultExplanation == "Uploaded to Hugging Face: fixture/model")
    }

    @Test func reopenedFinishedRunKeepsItsRecordedCurveInsteadOfClaimingNoRun() throws {
        let (defaults, suite) = try temporaryPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let savedFolder = folder.resolvingSymlinksInPath().appendingPathComponent("results/saved-run")
        try FileManager.default.createDirectory(at: savedFolder, withIntermediateDirectories: true)
        let result = TrainingResult(
            runID: "saved-run", outputRepo: "", destination: .download, volumeID: "storage",
            state: .saved(folder: savedFolder.path)
        )
        let run = TrainingRun(
            runID: result.runID, trainer: "aitoolkit", datasetRepo: "fixture/images", datasetContainsVideo: false,
            paramsJSON: JSONValue.object([:]).pythonDumpsData(), volumeID: result.volumeID,
            startedAt: Date(), updatedAt: Date(), result: result, points: [.init(step: 200, loss: 0.1)],
            podSpendAtStart: 0
        )
        var record = ProjectTrainingRecord()
        record.runs = [run]
        record.results = [result]
        try record.save(to: folder)
        let gpu = workspace(defaults)
        gpu.projectFolder = folder
        #expect(gpu.runID.isEmpty && gpu.points.isEmpty)
        #expect(gpu.curveDisplay == .available && gpu.monitoredPoints == run.points)
        #expect(gpu.trainingStatus == "Last run finished" && gpu.computerStatus == "Not rented")
        gpu.runHistory[0].points = []
        #expect(gpu.curveDisplay == .ended)
        #expect(gpu.monitoredResultState == result.state)
    }
}
