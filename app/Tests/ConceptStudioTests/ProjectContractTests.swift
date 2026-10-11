import ConceptCore
@testable import ConceptStudio
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Records every request and answers with one fixed piece of dataset advice.
private actor AdviceRecorder {
    private(set) var requests: [(output: String, images: [UserContent])] = []

    func record(_ output: String, _ messages: [ChatMessage]) {
        let images = messages.flatMap(\.content).filter { if case .image = $0 { true } else { false } }
        requests.append((output, images))
    }
}

private struct AdviceClient: ModelClient {
    let recorder: AdviceRecorder
    var requestedModel = "advice-test"

    func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings
    ) async throws -> ModelReply {
        await recorder.record(output.name, messages)
        return ModelReply(
            text: #"{"summary":"Vary the backgrounds.","suggestions":["Add outdoor photos."]}"#,
            servedModel: requestedModel
        )
    }
}

@Suite("project contract and app-only state")
@MainActor
struct ProjectContractTests {
    private func newProject() throws -> URL {
        let directory = temporaryTestDirectory("ConceptStudio-project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func chosenSkillIsCopiedIntoTheProjectAndReferencedRelatively() async throws {
        let parent = temporaryTestDirectory("ConceptStudio-skills")
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = try makeSkill(named: "my-captions", in: parent)
        let session = makeTestSession()
        session.project = try await makeDemoProject()
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        session.chooseSkill(original)
        #expect(session.errorMessage == nil)
        #expect(session.project?.job.skill == "./skill/my-captions")
        let yaml = try String(contentsOf: directory.appendingPathComponent("job.yaml"), encoding: .utf8)
        #expect(yaml.contains("skill: ./skill/my-captions"))
        #expect(!yaml.contains(parent.path))
        #expect(FileManager.default
            .fileExists(atPath: directory.appendingPathComponent("skill/my-captions/SKILL.md").path))
        #expect(try session.selectedSkill().name == "my-captions")

        // The original folder is no longer needed: the project carries its own copy.
        try FileManager.default.removeItem(at: original)
        #expect(try session.selectedSkill().name == "my-captions")

        // Published beside the job file so its relative path resolves there; images and app-only files stay home.
        let project = try #require(session.project)
        let paths = try await ProjectPublisher.operations(for: project).map(\.path)
        #expect(paths.contains("concept-captioner/skill/my-captions/SKILL.md"))
        #expect(paths.contains("concept-captioner/skill/my-captions/references/profiles/flux-image.md"))
        #expect(!paths.contains { $0.contains(".conceptstudio") || $0.hasPrefix("references/") })

        // A moved project keeps working because nothing points outside it.
        let moved = temporaryTestDirectory("ConceptStudio-moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.copyItem(at: directory, to: moved)
        session.project = try await StudioProject.open(at: moved)
        #expect(try session.selectedSkill().name == "my-captions")

        session.useBundledSkill()
        #expect(session.project?.job.skill == nil)
        #expect(try !String(contentsOf: moved.appendingPathComponent("job.yaml"), encoding: .utf8).contains("skill:"))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("skill").path))
        #expect(try session.selectedSkill().name == Skills.defaultSkillName)
    }

    @Test func skillOutsideTheProjectIsCopiedInWhenTheProjectOpens() async throws {
        let parent = temporaryTestDirectory("ConceptStudio-skills")
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = try makeSkill(named: "old-skill", in: parent)
        let directory = try newProject()
        defer { try? FileManager.default.removeItem(at: directory) }
        var created = try StudioProject.create(at: directory)
        created.job.skill = outside.path
        try created.save()
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let session = makeTestSession(preferences: preferences.defaults)
        session.openProject(url: directory)
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.project?.job.skill == "./skill/old-skill")
        #expect(try session.selectedSkill().name == "old-skill")
        await session.closeProject()
    }

    @Test func unreadableOutsideSkillAsksToChooseItAgain() async throws {
        let session = makeTestSession()
        session.project = try await makeDemoProject()
        defer { if let directory = session.project?.directory { try? FileManager.default.removeItem(at: directory) } }
        session.project?.job.skill = "../not-in-this-project"
        #expect(session.project?.skillIsOutsideProject == true)
        #expect(throws: StudioError.self) { try session.selectedSkill() }
    }

    @Test func publishDestinationsBelongToEachProject() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let first = try newProject()
        let second = try newProject()
        defer { for url in [first, second] {
            try? FileManager.default.removeItem(at: url)
        } }
        let session = makeTestSession(preferences: preferences.defaults)
        session.createProject(at: first)
        await session.task?.value
        #expect(session.repoID.isEmpty)
        session.repoID = "owner/first-dataset"
        session.privateDataset = false
        session.trainingOutputRepo = "owner/first-lora"

        session.createProject(at: second)
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.repoID.isEmpty)
        #expect(session.privateDataset)
        #expect(session.trainingOutputRepo.isEmpty)

        session.openProject(url: first)
        await session.task?.value
        #expect(session.repoID == "owner/first-dataset")
        #expect(!session.privateDataset)
        #expect(session.trainingOutputRepo == "owner/first-lora")

        // App-only: not in the shared job file, not published, not an app-wide preference.
        let yaml = try String(contentsOf: first.appendingPathComponent("job.yaml"), encoding: .utf8)
        #expect(!yaml.contains("first-dataset"))
        #expect(preferences.defaults.string(forKey: "hubRepo") == nil)
        let project = try #require(session.project)
        #expect(try await !ProjectPublisher.operations(for: project).contains { $0.path.contains(".conceptstudio") })
        await session.closeProject()
    }

    @Test func appOnlyStateToleratesMissingFields() throws {
        let state = try JSONDecoder().decode(ProjectAppState.self, from: Data(#"{"dataset":{"repo":"a/b"}}"#.utf8))
        #expect(state.dataset == HubDestination(repo: "a/b", isPrivate: true))
        #expect(state.trainingOutput == HubDestination())
    }

    @Test func recentProjectsAreRecentFirstBoundedAndPruned() throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let recents = RecentProjects(preferences: preferences.defaults)
        var folders: [URL] = []
        defer { for url in folders {
            try? FileManager.default.removeItem(at: url)
        } }
        for _ in 0 ..< RecentProjects.limit + 2 {
            let folder = try newProject()
            _ = try StudioProject.create(at: folder)
            folders.append(folder)
            try recents.remember(folder)
        }
        #expect(recents.paths.count == RecentProjects.limit)
        #expect(recents.paths.first == folders.last?.path)
        try recents.remember(folders[5])
        #expect(recents.paths.first == folders[5].path)
        #expect(recents.paths.count == RecentProjects.limit)
        #expect(Set(recents.paths).count == recents.paths.count)

        try FileManager.default.removeItem(at: folders[5])
        #expect(throws: StudioError.self) { try recents.restore(folders[5].path) }
        #expect(!recents.paths.contains(folders[5].path))
        let restored = try recents.restore(folders[6].path)
        #expect(restored.resolvingSymlinksInPath().path == folders[6].resolvingSymlinksInPath().path)
    }

    @Test func startupRecoveryUsesInjectedPreferencesAndSecrets() throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let saved = SavedPod(
            pod: RentedPod(id: "injected-pod", status: "RUNNING", cost: 1, gpu: .init(count: 1)),
            started: Date(), hourlyRate: 1, budget: 10, trainer: "aitoolkit", runID: "", outputRepo: ""
        )
        try preferences.defaults.set(JSONEncoder().encode(saved), forKey: "ConceptStudio.activePod")
        let secrets = MemorySecretStore(["pod.injected-pod": "agent-token"])
        let session = makeTestSession(preferences: preferences.defaults, secrets: secrets)
        session.restoreStartupComputer()
        #expect(session.gpu.hasRunningPod)
        #expect(session.gpu.agentToken == "agent-token")
        #expect(secrets.readAccounts.contains("pod.injected-pod"))
    }

    @Test func demoLivesInOneLocationAndIsRemovedOnClose() async throws {
        let session = makeTestSession()
        session.useDemo()
        await session.task?.value
        let directory = try #require(session.project?.directory)
        #expect(directory.standardizedFileURL == session.demoDirectory.standardizedFileURL)
        session.useDemo()
        await session.task?.value
        #expect(session.project?.directory.standardizedFileURL == session.demoDirectory.standardizedFileURL)
        await session.closeProject()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func switchingProjectWithDraftsWaitsForTheUsersAnswer() async throws {
        let session = makeTestSession()
        session.useDemo()
        await session.task?.value
        let image = try #require(session.project?.images.first)
        session.setCaptionDraft(CaptionDraft(text: "NORA7 unsaved.", isFinal: false), for: image.id)
        session.useDemo()
        #expect(session.pendingConfirmation?.confirmation == .discardCaptionDrafts(count: 1))
        #expect(session.task == nil)
        session.resolveConfirmation(false)
        #expect(session.pendingConfirmation == nil)
        #expect(session.unsavedCaptionCount == 1)
        session.useDemo()
        session.resolveConfirmation(true)
        await session.task?.value
        #expect(session.unsavedCaptionCount == 0)

        session.setCaptionDraft(CaptionDraft(text: "NORA7 another.", isFinal: false), for: image.id)
        async let answer = session.confirmCloseIfNeeded()
        await Task.yield()
        #expect(session.pendingConfirmation?.confirmation == .discardCaptionDrafts(count: 1))
        session.resolveConfirmation(true)
        #expect(await answer)
        await session.closeProject()
    }

    @Test func editsStayAvailableDuringACaptionRunAndRefusalsSayWhy() async throws {
        let session = makeTestSession()
        session.useDemo()
        await session.task?.value
        let images = try #require(session.project?.images)
        session.caption(only: [images[0].id], overwrite: true)
        #expect(session.busy)
        session.datasetCritique()
        #expect(session.errorMessage?.contains("Writing captions") == true)
        session.errorMessage = nil
        session.saveCaption(id: images[0].id, text: "NORA7 typed while running.", final: true)
        #expect(session.errorMessage?.contains("still being captioned") == true)
        session.errorMessage = nil
        session.saveCaption(id: images[1].id, text: "NORA7 saved during the run.", final: true)
        #expect(session.editing)
        await session.editTask?.value
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.project?.images[1].caption == "NORA7 saved during the run.")
        #expect(session.project?.images[1].isFinal == true)
        #expect(session.project?.images[0].status == .written)
        #expect(session.runPendingIDs.isEmpty)
        await session.closeProject()
    }

    @Test func importedCaptionsAreMarkedAndCanBeProtectedTogether() async throws {
        let session = makeTestSession()
        session.project = try await makeDemoProject()
        let project = try #require(session.project)
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let sink = try SidecarSink(directory: project.imagesDirectory)
        for image in project.images.prefix(2) {
            try await sink.write(image.id, caption: "NORA7 from the Hub.", record: ResponseRecord(
                sampleID: image.id, status: .written, skill: project.skillName, profile: project.job.profile,
                captioner: ModelNames(requested: ProjectImage.importedCaptioner), critic: nil
            ))
        }
        session.project = try await StudioProject.open(at: project.directory)
        #expect(session.project?.images.filter(\.isImported).count == 2)
        #expect(session.unprotectedImportedCount == 2)
        session.protectImportedCaptions()
        await session.editTask?.value
        #expect(session.errorMessage == nil)
        #expect(session.unprotectedImportedCount == 0)
        for image in project.images.prefix(2) {
            let record = try #require(try await sink.record(image.id))
            #expect(record.isHumanFinal)
            #expect(record.source == "human")
        }
        let reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.images.prefix(2).allSatisfy { $0.isFinal && !$0.isImported })
    }

    @Test func jobFileIsWrittenOnlyWhenItChanges() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        try FileManager.default.removeItem(at: project.jobURL)
        #expect(try !project.update(job: project.job))
        #expect(!FileManager.default.fileExists(atPath: project.jobURL.path))
        var changed = project.job
        changed.captionerThinking = .high
        #expect(try project.update(job: changed))
        #expect(try Job.load(contentsOf: project.jobURL).captionerThinking == .high)
    }
}

@Suite("provider vocabulary, money and photo names")
@MainActor
struct StudioVocabularyTests {
    @Test func switchingProviderKeepsATypedModel() {
        #expect(ProviderChoices
            .model(afterSwitchingFrom: "openrouter", to: "google", current: "") == "gemini-3.8-flash")
        #expect(ProviderChoices.model(
            afterSwitchingFrom: "openrouter", to: "google", current: "google/gemini-3.8-flash"
        ) == "gemini-3.8-flash")
        #expect(ProviderChoices.model(
            afterSwitchingFrom: "openrouter", to: "google", current: "my-org/custom-model"
        ) == "my-org/custom-model")
        let session = makeTestSession()
        session.endpointKind = "anthropic"
        session.modelName = "claude-sonnet-4-6"
        session.providerChanged(from: "anthropic", to: "vllm")
        #expect(session.modelName == "Qwen/Qwen3-VL-8B-Instruct")
        session.modelName = "my-local-model"
        session.providerChanged(from: "vllm", to: "openrouter")
        #expect(session.modelName == "my-local-model")
        #expect(ProviderChoices.kinds.allSatisfy { !ProviderChoices.defaultModel(for: $0).isEmpty })
        #expect(ProviderChoices.title("openai") == "OpenAI")
    }

    @Test func moneyUsesOneDollarFormat() {
        #expect(StudioMoney.style.locale(Locale(identifier: "en_US")).format(1.5) == "$1.50")
        #expect(StudioMoney.format(0.333) == 0.333.formatted(StudioMoney.style))
        #expect(StudioMoney.perHour(2).hasSuffix("/hour"))
    }

    @Test func photoNamesAreReadableAndStable() {
        let data = Data("pixels".utf8)
        let hash = String(VisionInspector.contentHash(data).prefix(8))
        #expect(PhotoImportName.make(suggested: "IMG_1234.HEIC", captured: nil, data: data, suffix: "jpg")
            == "IMG_1234-\(hash).jpg")
        let captured = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(PhotoImportName.make(
            suggested: UUID().uuidString + ".jpeg", captured: captured, data: data, suffix: "jpg"
        ) == "photo-\(PhotoImportName.dateStem(captured))-\(hash).jpg")
        #expect(PhotoImportName.make(suggested: nil, captured: nil, data: data, suffix: "png") == "photo-\(hash).png")
        #expect(PhotoImportName.readableStem("../My holiday (1).png") == "My-holiday-1")
    }

    @Test func unsupportedPhotoFormatsBecomeJPEG() throws {
        let tiff = try Self.image(type: .tiff)
        let (converted, suffix) = try PhotoImportName.readable(tiff)
        #expect(suffix == "jpg")
        let source = try #require(CGImageSourceCreateWithData(converted as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let png = try Self.image(type: .png)
        let (same, pngSuffix) = try PhotoImportName.readable(png)
        #expect(same == png)
        #expect(pngSuffix == "png")
    }

    private static func image(type: UTType) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

@Suite("dataset advice and on-device analysis")
struct DatasetAdviceTests {
    @Test func adviceSamplesBatchesThumbnailsAndMerges() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let original = try Data(contentsOf: project.images[0].url)
        for index in 0 ..< 27 {
            _ = try project.importData(original, name: "copy-\(index).png")
        }
        #expect(project.images.count == 30)
        let recorder = AdviceRecorder()
        let assistant = StudioAssistant(
            endpoint: ResolvedEndpoint(client: AdviceClient(recorder: recorder)),
            demo: false
        )
        let advice = try await assistant.critique(project, warnings: [:])
        #expect(advice.contains("Vary the backgrounds."))
        #expect(advice.contains("• Add outdoor photos."))
        let requests = await recorder.requests
        // 30 photos: batches of 12, 12 and 6, then one text-only merge.
        #expect(requests.map(\.images.count) == [12, 12, 6, 0])
        #expect(requests.allSatisfy { $0.output == "DatasetAdvice" })
        for case let .image(data, mediaType) in requests.flatMap(\.images) {
            #expect(mediaType == "image/jpeg")
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
            #expect(width <= StudioAssistant.critiqueThumbnailPixels)
        }
    }

    @Test func largeSetsAreSampledEvenly() {
        let images = (0 ..< 200).map { ProjectImage(url: URL(fileURLWithPath: "/photos/\($0).png")) }
        let sample = StudioAssistant.critiqueSample(images)
        #expect(sample.count == StudioAssistant.critiquePhotoLimit)
        #expect(sample.first?.id == "0.png")
        #expect(Set(sample.map(\.id)).count == sample.count)
        #expect(StudioAssistant.critiqueSample(Array(images.prefix(5))).count == 5)
        checkStrict(DatasetAdvice.schema)
    }

    @Test func analysisIsCachedByContentAndReportedAsItGoes() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let urls = project.images.map(\.url)
        let inspector = VisionInspector()
        let seen = Seen()
        let first = try await inspector.analyze(urls, cacheIn: project.directory) { name, _ in await seen.add(name) }
        #expect(await seen.names == urls.map(\.lastPathComponent))
        var cache = VisionCache.load(from: project.directory)
        #expect(cache.entries.count == urls.count)
        // A changed cache entry is what the next pass reports: the file is not analysed again.
        let hash = try VisionInspector.contentHash(Data(contentsOf: urls[0]))
        cache.entries[hash]?.analysis.warnings = ["cached marker"]
        try cache.save(to: project.directory)
        let second = try await inspector.analyze(urls, cacheIn: project.directory)
        #expect(second[urls[0].lastPathComponent]?.warnings == ["cached marker"])
        #expect(second[urls[1].lastPathComponent] == first[urls[1].lastPathComponent])
    }

    private func checkStrict(_ value: JSONValue) {
        guard let object = value.objectValue else { return }
        #expect(object["additionalProperties"] == .bool(false))
        let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(required == Set(object["properties"]?.objectValue?.keys ?? []))
    }
}

private actor Seen {
    private(set) var names: [String] = []
    func add(_ name: String) {
        names.append(name)
    }
}
