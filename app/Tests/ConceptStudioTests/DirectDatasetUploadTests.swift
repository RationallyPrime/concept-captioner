import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

actor DatasetUploadAgent: PodAgent {
    struct Upload { let stage: String; let name: String; let data: Data }
    private(set) var uploads: [Upload] = []
    private(set) var starts: [HistoryAgent.Start] = []
    var failUpload = false
    private var holdFirstUpload = false
    private var uploadContinuation: CheckedContinuation<Void, Never>?

    func upload(name: String, fileName: String, from file: URL, size: Int64) async throws {
        if failUpload { throw StudioError.message("Synthetic upload failure") }
        let data = try Data(contentsOf: file)
        #expect(Int64(data.count) == size)
        uploads.append(Upload(stage: name, name: fileName, data: data))
        if holdFirstUpload {
            holdFirstUpload = false
            await withCheckedContinuation { uploadContinuation = $0 }
        }
    }

    func plan() -> TrainingPlan {
        TrainingPlan(mode: "sequential", caption: .init(gpus: [0]), train: .init(gpus: [0]))
    }

    func services() -> [AgentService] {
        starts.map { AgentService(name: $0.service, state: "exited", groupAlive: false, runID: nil) }
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) {
        starts.append(.init(
            service: service,
            gpus: gpus,
            params: params
        ))
    }

    func stop(_ service: String) {}
    func runLog(runID: String) -> String {
        "Offline"
    }

    func latest(runID: String) -> TrainingPoint? {
        nil
    }

    func history(runID: String) -> [TrainingPoint] {
        []
    }

    func runFiles(runID: String) -> [RunFile] {
        []
    }

    func download(runID: String, path: String, to destination: URL) {}
    func fail() {
        failUpload = true
    }

    func pauseFirstUpload() {
        holdFirstUpload = true
    }

    var uploadIsPaused: Bool {
        uploadContinuation != nil
    }

    func releaseUpload() {
        holdFirstUpload = false
        uploadContinuation?.resume()
        uploadContinuation = nil
    }
}

actor RecordingUploader: FileUploading {
    private(set) var requests: [URLRequest] = []
    private(set) var bytes: [Data] = []
    func upload(_ request: URLRequest, from file: URL) throws -> HTTPResponse {
        requests.append(request)
        let data = try Data(contentsOf: file)
        bytes.append(data)
        let url = try #require(request.url)
        return HTTPResponse(status: 200, body: JSONValue.object([
            "name": .string(url.deletingLastPathComponent().lastPathComponent),
            "file_name": .string(url.lastPathComponent), "size": .int(data.count),
        ]).pythonDumpsData())
    }
}

@Suite("Direct training dataset upload")
struct DirectDatasetUploadTests {
    @MainActor private func connected(
        project: StudioProject,
        agent: DatasetUploadAgent,
        preferences: UserDefaults
    ) -> GPUWorkspace {
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = project.directory
        workspace.pod = RentedPod(id: "offline", status: "RUNNING", cost: 0, gpu: .init(count: 1))
        workspace.selectedVolume = "storage"
        workspace.agent = agent
        workspace.hubToken = ""
        return workspace
    }

    @MainActor private func captionedProject() async throws -> StudioProject {
        try await captionedUploadProject()
    }

    @MainActor @Test func noHubTokenUploadsIncludedExactInputsThenTrainsAndPersistsLocalProvenance() async throws {
        var project = try await captionedProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let excluded = try #require(project.images.last?.id)
        try project.setIncluded(excluded, false)
        let agent = DatasetUploadAgent()
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = connected(project: project, agent: agent, preferences: preferences)
        await workspace.train(datasetRepo: "")
        #expect(workspace.trainingState == "running")
        let uploads = await agent.uploads
        #expect(uploads.contains { $0.name == "job.yaml" })
        #expect(uploads.contains { $0.name == "metadata.jsonl" })
        #expect(!uploads.contains { $0.name == excluded })
        for image in project.images {
            let expected = try Data(contentsOf: image.url)
            let received = uploads.first(where: { $0.name == image.id })?.data
            #expect(received == expected)
        }
        let starts = await agent.starts
        let pull = try #require(starts.first { $0.service == "pull-dataset" })
        #expect(pull.params["local_name"]?.stringValue == workspace.runID)
        #expect(pull.params["repo_id"] == nil && pull.params["revision"] == nil && pull.params["hf_token"] == nil)
        #expect(pull.params["only_metadata"] == .bool(true))
        let run = try #require(workspace.runHistory.last)
        #expect(run.localInputDigest?.count == 64)
        #expect(run.datasetRepo.isEmpty && run.datasetRevision == nil)
        let reopened = ProjectTrainingRecord.load(from: project.directory)
        #expect(reopened.runs.last?.localInputDigest == run.localInputDigest)
    }

    @MainActor @Test func localResumeReuploadsAfterPruneAndRefusesChangedInputsBeforeAnyAgentAction() async throws {
        let project = try await captionedProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let agent = DatasetUploadAgent()
        let workspace = connected(project: project, agent: agent, preferences: preferences)
        await workspace.train(datasetRepo: "")
        var run = try #require(workspace.runHistory.last)
        run.result?.state = .saved(folder: project.directory.path)
        run.points = [.init(step: 200, loss: 0.1)]
        workspace.result = run.result
        let count = await agent.uploads.count
        workspace.hubToken = "fixture-newly-configured-hub"
        await workspace.resumeRun(run, totalSteps: 400)
        #expect(await agent.uploads.count == count * 2)
        let resumed = await agent.starts.last { $0.service == "trainer-aitoolkit" }
        #expect(resumed?.params["resume"] == .bool(true))
        let starts = await agent.starts.count
        try Data("changed saved caption".utf8).write(to: project.imagesDirectory.appendingPathComponent(
            (project.images[0].id as NSString).deletingPathExtension + ".txt"
        ))
        workspace.result?.state = .saved(folder: project.directory.path)
        await workspace.resumeRun(run, totalSteps: 600)
        #expect(workspace.message.contains("have changed"))
        #expect(await agent.starts.count == starts)
        #expect(await agent.uploads.count == count * 2)
    }

    @MainActor @Test func uploadFailureNeverStartsPullOrTrainerAndRepeatCanUseChangedInputs() async throws {
        let project = try await captionedProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let failed = DatasetUploadAgent()
        await failed.fail()
        let workspace = connected(project: project, agent: failed, preferences: preferences)
        await workspace.train(datasetRepo: "")
        #expect(await failed.starts.isEmpty)
        let working = DatasetUploadAgent()
        workspace.agent = working
        await workspace.train(datasetRepo: "")
        let previous = try #require(workspace.runHistory.last)
        workspace.result?.state = .saved(folder: project.directory.path)
        workspace.trainingState = "exited"
        workspace.repeatSettings(from: previous)
        try Data("NORA7, changed caption for a new run.".utf8).write(to: project.imagesDirectory.appendingPathComponent(
            (project.images[0].id as NSString).deletingPathExtension + ".txt"
        ))
        await workspace.train(datasetRepo: "")
        #expect(workspace.runHistory.last?.runID != previous.runID)
        #expect(workspace.runHistory.last?.localInputDigest != previous.localInputDigest)
    }

    @Test func nativeUploadUsesFileTransportLengthBearerAndExactReceipt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let data = Data("approved-clip".utf8)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let uploader = RecordingUploader()
        let client = try PodAgentClient(
            baseURL: #require(URL(string: "https://owned.invalid")),
            token: "fixture",
            transport: GPUTransport(),
            uploader: uploader
        )
        try await client.upload(name: "stage-1", fileName: "selected.mp4", from: file, size: Int64(data.count))
        let request = try #require(await uploader.requests.first)
        #expect(request.httpMethod == "PUT" && request.url?.path() == "/uploads/stage-1/selected.mp4")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == String(data.count))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(await uploader.bytes == [data])
        await #expect(throws: StudioError.self) {
            try await client.upload(name: "stage-1", fileName: "../outside.mp4", from: file, size: Int64(data.count))
        }
        #expect(await uploader.requests.count == 1)
    }
}

extension DirectDatasetUploadTests {
    @MainActor @Test(arguments: [false, true])
    func publishEntryLoadsOnlyExistingHubCredentialWithoutSettingsOrProviderActions(configured: Bool) throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore(configured ? ["huggingface": "fixture-hub"] : [:])
        let session = StudioSession(preferences: preferences, secrets: secrets)
        #expect(session.gpu.hubToken.isEmpty)
        session.preparePublishing()
        #expect(session.gpu.usesLocalDataset == !configured)
        #expect(session.gpu.hubToken == (configured ? "fixture-hub" : ""))
        #expect(secrets.readAccounts == ["huggingface"])
        #expect(session.gpu.provider == nil && session.gpu.agent == nil)
        #expect(session.gpu.pod == nil)
    }
}

extension DirectDatasetUploadTests {
    @Test func sharedDigestReferenceUsesLiteralUTF8NamesIncludingCanonicalEquivalentSpelling() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/local-input-digest.json")
        let reference = try JSONValue(parsing: Data(contentsOf: fixture))
        let rows = try #require(reference.objectValue?["files"]?.arrayValue)
        let files = try rows.map { row in
            let object = try #require(row.objectValue)
            return try LocalTrainingDataset.File(
                name: #require(object["name"]?.stringValue),
                url: fixture,
                size: Int64(#require(object["size"]?.intValue)),
                sha256: #require(object["sha256"]?.stringValue)
            )
        }
        #expect(LocalTrainingDataset.inputDigest(files) == reference.objectValue?["sha256"]?.stringValue)
        #expect(LocalTrainingDataset.inputDigest(files.reversed()) == reference.objectValue?["sha256"]?.stringValue)
    }
}

@MainActor
func captionedUploadProject(at destination: URL? = nil) async throws -> StudioProject {
    let project = try await DemoProject.create(at: destination ?? temporaryTestDirectory("upload-inputs"))
    let sink = try SidecarSink(directory: project.imagesDirectory)
    for image in project.images {
        let caption = "NORA7, a geometric figure."
        let record = ResponseRecord(
            sampleID: image.id,
            status: .written,
            skill: "fixture",
            profile: "flux-image",
            captioner: .init(requested: "fixture", served: nil),
            critic: nil
        )
        try await sink.write(image.id, caption: caption, record: record)
    }
    return project
}

extension DirectDatasetUploadTests {
    @MainActor @Test func trainingUsesCapturedProfileAndTriggersWhenProjectDefaultsChangeDuringUpload() async throws {
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let agent = DatasetUploadAgent()
        await agent.pauseFirstUpload()
        let workspace = connected(project: project, agent: agent, preferences: preferences)
        workspace.profile = "flux-image"
        workspace.triggerWords = "NORA7"
        let selectedModel = workspace.baseModel
        let session = StudioSession(preferences: preferences, secrets: MemorySecretStore())
        session.project = project
        session.gpu = workspace
        session.gpuKeysLoadedFor = workspace
        let work = Task { await workspace.train(datasetRepo: "", captureLocal: session.captureTrainingInputs) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !(agent.uploadIsPaused), ContinuousClock.now < deadline {
            await Task.yield()
        }
        let paused = await agent.uploadIsPaused
        #expect(!session.busy && !session.editing)
        var concept = project.job.concepts[0]
        concept.trigger = "NEW8"
        try session.saveConcept(concept, replacing: "NORA7")
        session.project?.job.profile = "ltx-video"
        session.prepareGPUStep()
        workspace.baseModel = "edited after input capture"
        #expect(workspace.triggerWords == "NEW8" && workspace.profile == "ltx-video")
        await agent.releaseUpload()
        await work.value
        #expect(paused)
        let start = try #require(await agent.starts.last { $0.service == "trainer-aitoolkit" })
        #expect(start.params["profile"] == .string("flux-image"))
        #expect(start.params["triggers"] == .array([.string("NORA7")]))
        #expect(start.params["base_model"] == .string(selectedModel))
    }

    @MainActor @Test func oversizedInputIsRefusedBeforeSnapshotCopyOrHTTPUpload() async throws {
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let file = project.images[0].url
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(LocalTrainingDataset.maximumFileBytes + 1))
        try handle.close()
        await #expect(throws: StudioError.self) {
            try await LocalTrainingDataset.prepare(projectFolder: project.directory)
        }
        let uploader = RecordingUploader()
        let client = try PodAgentClient(
            baseURL: #require(URL(string: "https://owned.invalid")), token: "fixture",
            transport: GPUTransport(), uploader: uploader
        )
        await #expect(throws: StudioError.self) {
            try await client.upload(
                name: "stage-1", fileName: file.lastPathComponent, from: file,
                size: LocalTrainingDataset.maximumFileBytes + 1
            )
        }
        #expect(await uploader.requests.isEmpty)
    }

    @MainActor @Test func capturedInputsReleaseProjectGatesAndMetadataUsesCopiedCaptionBytes() async throws {
        let project = try await captionedUploadProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: preferences, secrets: MemorySecretStore())
        session.project = project
        session.editing = true
        await #expect(throws: StudioError.self) { try await session.captureTrainingInputs() }
        session.editing = false
        let snapshot = try await session.captureTrainingInputs()
        defer { snapshot.remove() }
        #expect(!session.busy && !session.editing && session.task == nil)
        let image = project.images[0]
        let captionName = (image.id as NSString).deletingPathExtension + ".txt"
        let stored = try String(contentsOf: snapshot.folder.appendingPathComponent(captionName), encoding: .utf8)
        #expect(session.perform("A later caption edit", gate: .edit) {
            try Data("NORA7, a changed caption after capture.".utf8).write(to:
                project.imagesDirectory.appendingPathComponent(captionName))
        })
        await session.editTask?.value
        let rows = try ImageFolderMetadata
            .parse(Data(contentsOf: snapshot.folder.appendingPathComponent("metadata.jsonl")))
        #expect(rows.first { $0.fileName == image.id }?.caption == stored)
        #expect(try String(contentsOf: snapshot.folder.appendingPathComponent(captionName), encoding: .utf8) == stored)
    }
}
