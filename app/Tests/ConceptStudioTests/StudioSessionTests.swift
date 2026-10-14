import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor ImageChoiceTransport: HTTPTransport {
    private var stopped = false
    private(set) var createdImages: [String] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let body: String
        if url.host() != "api.runpod.io" {
            body = #"{"services":[]}"#
        } else if url.path().contains("catalog/gpus") {
            body = #"{"gpus":[{"id":"test","name":"Test GPU","memory":80,"secure":true,"#
                + #""price":{"secure":1},"maxCount":{"secure":4},"#
                + #""dataCenters":[{"id":"test","availability":"HIGH"}]}]}"#
        } else if url.path().hasSuffix("network-volumes") {
            body = #"{"networkVolumes":[{"id":"test","name":"Data","size":100,"dataCenter":"test"}]}"#
        } else if url.path().contains("account/secrets") {
            // Credentials are stored as account secrets before the pod is created (POD-SPEC §1).
            body = request.httpMethod == "GET" ? #"{"secrets":[]}"# : #"{"id":"secret","name":"secret"}"#
        } else {
            if url.path() == "/v2/pods", request.httpMethod == "POST" {
                let payload = try JSONValue(parsing: #require(request.httpBody)).objectValue
                try createdImages.append(#require(payload?["image"]?.stringValue))
            }
            if url.path().hasSuffix("action") { stopped = true }
            body = "{\"id\":\"test\",\"status\":\"\(stopped ? "EXITED" : "RUNNING")\",\"cost\":1,"
                + "\"gpu\":{\"count\":1}}"
        }
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

@Suite("studio offline actions")
@MainActor
struct StudioSessionTests {
    @Test(arguments: [nil, "", " \n\t", "ghcr.io/example/custom-{trainer}:chosen"] as [String?], ["aitoolkit", "ltx"])
    func savedTrainingImageReachesTheSelectedTrainer(saved: String?, trainer: String) async throws {
        let suite = "StudioSessionTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        if let saved { preferences.set(saved, forKey: "podImage") }
        let session = StudioSession(preferences: preferences)
        let transport = ImageChoiceTransport()
        session.gpu = GPUWorkspace(
            demoMode: false, transport: transport, preferences: preferences, saveAgentToken: { _, _ in }
        )
        try session.gpu.configure(runpodKey: "fake", hubToken: "fake", imageName: session.podImageName)
        session.gpu.trainer = trainer
        await session.gpu.refreshOffers()
        await session.gpu.rent()
        let expected = if let saved, !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saved.replacingOccurrences(of: "{trainer}", with: trainer)
        } else {
            "ghcr.io/rationallyprime/concept-captioner-pod-\(trainer):v0.3.3-20261014"
        }
        #expect(await transport.createdImages == [expected])
        await session.gpu.stopEverything()
    }

    @Test(arguments: [
        ("ghcr.io/rationallyprime/concept-captioner-pod-{trainer}:v0.1.0-verify20261010", ""),
        ("ghcr.io/rationallyprime/concept-captioner-pod-{trainer}:v0.2.3-clean-20261011", ""),
        (
            "ghcr.io/rationallyprime/concept-captioner-pod-aitoolkit:v0.2.3-clean-20261011",
            "ghcr.io/rationallyprime/concept-captioner-pod-aitoolkit:v0.2.3-clean-20261011"
        ),
        (
            "ghcr.io/rationallyprime/concept-captioner-pod-{trainer}:v0.2.3 extra",
            "ghcr.io/rationallyprime/concept-captioner-pod-{trainer}:v0.2.3 extra"
        ),
        ("ghcr.io/example/custom-{trainer}:chosen", "ghcr.io/example/custom-{trainer}:chosen"),
    ])
    func previouslySavedDefaultImageBecomesAutomaticOnce(saved: String, loaded: String) throws {
        let suite = "StudioSessionTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(saved, forKey: "podImage")
        let session = StudioSession(preferences: preferences)
        #expect(session.podImageName == loaded)
        #expect(preferences.string(forKey: "podImage") == loaded)
        // After the one-time migration a deliberately entered default is kept.
        session.podImageName = StudioSession.defaultPodImageName
        session.rememberChoices()
        #expect(StudioSession(preferences: preferences).podImageName == StudioSession.defaultPodImageName)
    }

    @Test(arguments: ["", " \n\t", "ghcr.io/example/custom:chosen"])
    func changedTrainingImageIsRememberedImmediately(_ changed: String) throws {
        let suite = "StudioSessionTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("ghcr.io/example/previous:chosen", forKey: "podImage")
        let session = StudioSession(preferences: preferences)
        session.podImageName = changed
        session.rememberChoices()
        let loaded = StudioSession(preferences: preferences)
        #expect(session.podImageName == loaded.podImageName)
        #expect(preferences.string(forKey: "podImage") == session.podImageName)
        if changed.isEmpty {
            #expect(session.podImageName.isEmpty)
            #expect(preferences.string(forKey: "podImage") == "")
        } else {
            #expect(session.podImageName == changed)
        }
    }

    @Test func startupRecoveryOnlyRoutesKnownRunningMetadata() throws {
        #expect(!StudioSession.startupNeedsPodRecovery(nil))
        for status in ["RUNNING", "STARTING", "EXITED", "ERROR", "TERMINATED"] {
            let saved = SavedPod(
                pod: RentedPod(id: "test-pod", status: status, cost: 1, gpu: .init(count: 1)),
                started: Date(),
                hourlyRate: 1,
                budget: 10,
                trainer: "aitoolkit",
                runID: "",
                outputRepo: ""
            )
            let data = try JSONEncoder().encode(saved)
            #expect(StudioSession.startupNeedsPodRecovery(data) == ["RUNNING", "STARTING"].contains(status))
        }
    }

    @Test func demoCompletesNineScreensWithoutCredentials() async throws {
        let session = makeTestSession()
        session.useDemo()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.demoMode)
        #expect(session.project?.images.count == 3)
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.datasetCritique()
        await session.task?.value
        #expect(!session.datasetAdvice.isEmpty)
        session.proposeMappings(useModel: true)
        await session.task?.value
        #expect(session.mappingProposals.count == 3)
        for (id, mapping) in session.mappingProposals {
            session.confirmMapping(id: id, mapping: mapping)
        }
        session.caption()
        await session.task?.value
        #expect(session.project?.images.allSatisfy { $0.status == .written } == true)
        let id = try #require(session.project?.images.first?.id)
        session.saveCaption(id: id, text: "NORA7 final user caption.", final: true)
        await session.editTask?.value
        session.compare(id: id, model: "another-model", kind: "openai")
        await session.task?.value
        #expect(!session.comparison.isEmpty)
        #expect(session.project?.images.first?.caption == "NORA7 final user caption.")
        session.caption(only: [id], overwrite: true)
        await session.task?.value
        #expect(session.project?.images.first?.isFinal == true)
        session.publish()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.message.contains("No upload"))
        session.configureGPU()
        await session.gpu.refreshOffers()
        session.gpu.gpuCount = 2
        await session.gpu.rent()
        #expect(session.gpu.hasRunningPod)
        #expect(session.gpu.triggerWords == "NORA7")
        #expect(session.gpu.profile == "flux-image")
        await session.gpu.train(datasetRepo: session.repoID)
        #expect(!session.gpu.runID.isEmpty)
        for _ in 0 ..< 10 {
            await session.gpu.refresh()
        }
        #expect(!session.gpu.points.isEmpty)
        #expect(session.gpu.trainingState == "exited")
        session.gpu.outputRepo = "demo/result"
        await session.gpu.publishResult()
        #expect(session.gpu.message.contains("uploaded"))
        for _ in 0 ..< 8 {
            session.next()
        }
        #expect(session.step == .monitor)
        await session.closeProject()
        #expect(session.project == nil)
        #expect(!session.gpu.hasRunningPod)
    }

    @Test func cancellationSettlesBeforeProjectClose() async throws {
        let session = makeTestSession()
        session.useDemo()
        await session.task?.value
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.caption()
        await session.closeProject()
        #expect(!session.busy)
        #expect(session.task == nil)
        #expect(session.project == nil)
    }

    @Test func closingDemoCannotStopOrDetachARealWorkspace() async throws {
        let suite = "StudioSessionTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let demoDirectory = temporaryTestDirectory("crossed-demo-workspace")
        defer { try? FileManager.default.removeItem(at: demoDirectory) }
        let session = StudioSession(
            preferences: preferences, secrets: MemorySecretStore(), demoDirectory: demoDirectory
        )
        let transport = ImageChoiceTransport()
        let realWorkspace = GPUWorkspace(
            demoMode: false, transport: transport, preferences: preferences, saveAgentToken: { _, _ in }
        )
        defer { Task { await realWorkspace.stopEverything() } }
        session.gpu = realWorkspace
        try realWorkspace.configure(runpodKey: "fake", hubToken: "fake", imageName: "test")
        await realWorkspace.refreshOffers()
        await realWorkspace.rent()
        #expect(realWorkspace.hasRunningPod)

        session.project = try await DemoProject.create(at: demoDirectory)
        session.gpu.projectFolder = demoDirectory
        session.demoMode = true
        await session.closeProject()

        #expect(!session.demoMode)
        #expect(session.project == nil)
        #expect(session.gpu === realWorkspace)
        #expect(realWorkspace.hasRunningPod)
        #expect(realWorkspace.projectFolder == nil)
        await realWorkspace.stopEverything()
    }

    @Test func publishingAnEmptyProjectReportsWhyInsteadOfCancelling() async throws {
        let session = makeTestSession()
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.images = []
        session.project = project
        session.publish()
        await session.task?.value
        #expect(session.errorMessage?.contains("Import images or clips before publishing") == true)
        #expect(session.message.contains("Dataset publication failed"))
    }

    @Test func latePublishProgressCannotReplaceOutcomeOrCrossProjects() async throws {
        let session = makeTestSession()
        let first = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: first.directory) }
        let second = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: second.directory) }
        let publication = UUID()
        session.project = first
        session.activePublishID = publication
        session.message = "Dataset published. https://example.test/commit"
        session.activePublishID = nil
        session.receivePublishProgress("committing: late.json", id: publication, projectDirectory: first.directory)
        #expect(session.message == "Dataset published. https://example.test/commit")

        session.activePublishID = publication
        session.project = second
        session.message = "Second project is ready."
        session.receivePublishProgress("committing: stale.json", id: publication, projectDirectory: first.directory)
        #expect(session.message == "Second project is ready.")
    }

    @Test func ownedPodCaptionKeyIsTrustedWithoutEnteringTheJob() async throws {
        let session = makeTestSession()
        session.useDemo()
        await session.task?.value
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await session.gpu.refreshOffers()
        await session.gpu.rent()
        session.usePodCaptionServer()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.usingPodCaptioner)
        // Keep the fake GPU backend; inspect real resolver construction without sending HTTP or reading Keychain.
        session.demoMode = false
        let endpoint = try session.endpoint()
        let client = try #require(endpoint.client as? OpenAICompatibleClient)
        #expect(client.apiKey == session.gpu.agentToken)
        #expect(client.baseURL == session.gpu.captionEndpoint)
        let job = try session.jobForCaptioning()
        // The rented computer's caption URL is temporary, so job.yaml never stores it.
        let podURL = try #require(session.gpu.captionEndpoint?.absoluteString)
        #expect(job.endpoints?.captioner.baseURL == nil)
        #expect(!job.jsonValue.pythonDumps().contains(podURL))
        #expect(!job.jsonValue.pythonDumps().contains(session.gpu.agentToken))
        await session.gpu.stopEverything()
        #expect(throws: StudioError.self) { try session.endpoint() }
        await session.closeProject()
    }

    @Test func sharedRequestSettingsAndThinkingSurvivePreparation() async throws {
        let session = makeTestSession()
        session.project = try await makeDemoProject()
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.project?.job.endpoints = try Endpoints(captioner: EndpointSpec(
            kind: "openrouter",
            model: "m",
            settings: ["temperature": .double(0.2)]
        ))
        session.modelThinking = .low
        session.criticThinking = .high
        let job = try session.jobForCaptioning()
        #expect(job.endpoints?.captioner.settings["temperature"] == .double(0.2))
        #expect(job.captionerThinking == .low)
        #expect(job.criticThinking == .high)
        session.project?.job.skill = "/unselected/skill"
        #expect(throws: StudioError.self) { try session.selectedSkill() }
    }
}
