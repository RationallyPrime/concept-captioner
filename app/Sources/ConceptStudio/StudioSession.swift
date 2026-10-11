import AppKit
import ConceptCore
import Observation

struct CaptionDraft: Equatable {
    var text: String
    var isFinal: Bool
}

@MainActor @Observable
final class StudioSession {
    var project: StudioProject?
    var demoMode = false
    var step: StudioStep? = .images
    var selectedImageID: String?
    var message = ""
    var errorMessage: String?
    var busy = false
    var completed = 0
    var task: Task<Void, Never>?
    var scenario: DemoScenario = .success
    var analyses: [String: ImageAnalysis] = [:]
    var datasetAdvice = ""
    var mappingProposals: [String: Job.Mapping] = [:]
    var comparison = ""
    private(set) var captionDrafts: [String: CaptionDraft] = [:]
    var usingPodCaptioner = false
    var startupRestored = false
    var recentPaths = ProjectAccess.recentPaths
    var endpointKind = ""
    var modelName = ""
    var criticKind = ""
    var criticModel = ""
    var openAIUsesChatGPT = false
    var chatGPT: ChatGPTAccounts
    var showChatGPTPlanNotice = false
    var chatGPTUsageLimitReached = false
    @ObservationIgnored var chatGPTWorkGeneration = 0
    var useCritic = false
    var modelThinking = ThinkingLevel.none
    var criticThinking = ThinkingLevel.none
    var concurrency = 4
    var outputMode = OutputMode.native
    var customBaseURL = ""
    var requestBaseURL = ""
    var criticRequestBaseURL = ""
    var repoID = ""
    var privateDataset = true
    var podImageName = ""
    var volumeID = ""
    var skillAccess: URL?
    var projectAccess: URL?
    var gpu = GPUWorkspace(demoMode: false)
    let inspector = VisionInspector()
    let preferences: UserDefaults

    init(preferences: UserDefaults = .standard, chatGPT: ChatGPTAccounts? = nil) {
        self.preferences = preferences
        self.chatGPT = chatGPT ?? ChatGPTAccounts(preferences: preferences)
        loadSavedChoices()
    }

    var selectedImage: ProjectImage? {
        project?.images.first { $0.id == selectedImageID }
    }

    func captionDraft(for image: ProjectImage) -> CaptionDraft {
        captionDrafts[image.id] ?? CaptionDraft(text: image.caption, isFinal: image.isFinal)
    }

    func setCaptionDraft(_ draft: CaptionDraft, for id: String) {
        guard let image = project?.images.first(where: { $0.id == id }) else { return }
        let saved = CaptionDraft(text: image.caption, isFinal: image.isFinal)
        captionDrafts[id] = draft == saved ? nil : draft
    }

    func discardCaptionDraft(for image: ProjectImage) {
        captionDrafts[image.id] = nil
    }

    func hasUnsavedCaption(for image: ProjectImage) -> Bool {
        captionDraft(for: image) != CaptionDraft(text: image.caption, isFinal: image.isFinal)
    }

    var unsavedCaptionCount: Int {
        project?.images.count(where: { hasUnsavedCaption(for: $0) }) ?? 0
    }

    var captionDiscardWarning: String? {
        guard unsavedCaptionCount > 0 else { return nil }
        return "\(unsavedCaptionCount) unsaved caption edits will be discarded. "
            + "Save those captions on Review to keep them. Saved captions are unchanged."
    }

    var needsCloseConfirmation: Bool {
        unsavedCaptionCount > 0 || busy || chatGPT.isBusy || gpu.hasRunningPod || gpu.isBusy
    }

    func clearSavedCaptionDraft(_ draft: CaptionDraft, for id: String) {
        // A later edit must survive completion of an earlier save.
        if captionDrafts[id] == draft { captionDrafts[id] = nil }
    }

    var unmappedCount: Int {
        project?.job.unmapped(project?.images.map(\.id) ?? []).count ?? 0
    }

    var keyStore: KeychainStore {
        KeychainStore(vllmBaseURL: customBaseURL.isEmpty ? nil : customBaseURL)
    }

    func perform(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        completed = 0
        message = title
        errorMessage = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await operation()
                if Task.isCancelled { message = "Cancelled. Your completed work is saved." }
            } catch is CancellationError {
                message = "Cancelled. Your completed work is saved."
            } catch {
                errorMessage = Self.describe(error)
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? StudioError { return error.localizedDescription }
        return error.localizedDescription + " Check the relevant settings and try again."
    }

    func cancel() {
        task?.cancel()
    }

    static func startupNeedsPodRecovery(_ data: Data?) -> Bool {
        guard let data, let saved = try? JSONDecoder().decode(SavedPod.self, from: data) else { return false }
        return saved.pod.isRunning
    }

    func restoreStartupComputer() {
        guard !startupRestored else { return }
        startupRestored = true
        guard !demoMode, Self.startupNeedsPodRecovery(UserDefaults.standard.data(forKey: "ConceptStudio.activePod"))
        else { return }
        do {
            // Restore the known running state before credentials can fail or Welcome actions can replace it.
            try gpu.configure(runpodKey: "", hubToken: "", imageName: podImageName)
        } catch {
            errorMessage = Self.describe(error)
            gpu.message = "A retained computer may still be billing. Add your RunPod key in Settings and stop it."
        }
        configureGPU()
    }

    func useDemo() {
        guard !gpu.hasRunningPod, !gpu.isBusy else {
            errorMessage = "Stop the rented computer before switching to the demo."
            return
        }
        guard confirmDiscardCaptionDrafts() else { return }
        perform("Opening the offline demo…") {
            await self.releaseProject()
            self.demoMode = true
            self.showChatGPTPlanNotice = false
            self.gpu = GPUWorkspace(demoMode: true)
            self.project = try await DemoProject.create()
            self.repoID = "demo/concept-studio"
            self.selectedImageID = self.project?.images.first?.id
            self.step = .images
            self.message = "Demo uses synthetic illustrations, fake services, and no money."
            try await self.analyzeImages()
        }
    }

    func createProject() {
        guard !gpu.hasRunningPod, !gpu.isBusy else {
            errorMessage = "Finish the current computer action or Stop everything before changing projects."
            return
        }
        guard confirmDiscardCaptionDrafts() else { return }
        guard let url = ProjectAccess.chooseFolder(prompt: "Create project here") else { return }
        perform("Creating your project…") {
            await self.releaseProject()
            self.demoMode = false
            self.loadSavedChoices()
            self.gpu = GPUWorkspace(demoMode: false)
            self.projectAccess = url
            _ = url.startAccessingSecurityScopedResource()
            self.project = try StudioProject.create(at: url)
            try ProjectAccess.remember(url)
            self.recentPaths = ProjectAccess.recentPaths
            self.step = .images
            self.message = "Project saved. Import your first photos."
        }
    }

    func openProject(url: URL? = nil) {
        guard !gpu.hasRunningPod, !gpu.isBusy else {
            errorMessage = "Finish the current computer action or Stop everything before changing projects."
            return
        }
        guard confirmDiscardCaptionDrafts() else { return }
        guard let selected = url ?? ProjectAccess.chooseFolder(prompt: "Open project") else { return }
        perform("Opening your project…") {
            await self.releaseProject()
            self.demoMode = false
            self.loadSavedChoices()
            self.gpu = GPUWorkspace(demoMode: false)
            self.projectAccess = selected
            _ = selected.startAccessingSecurityScopedResource()
            self.project = try await StudioProject.open(at: selected)
            if let skillPath = self.project?.job.skill,
               let skillURL = try? ProjectAccess.restore(skillPath, collection: "skillBookmarks") {
                _ = skillURL.startAccessingSecurityScopedResource()
                self.skillAccess = skillURL
            }
            try ProjectAccess.remember(selected)
            self.recentPaths = ProjectAccess.recentPaths
            if let job = self.project?.job { self.applyJobChoices(job) }
            self.selectedImageID = self.project?.images.first?.id
            self.message = "Project opened. Your saved choices and final captions are preserved."
            try await self.analyzeImages()
        }
    }

    func openRecent(_ path: String) {
        do { try openProject(url: ProjectAccess.restore(path)) } catch { errorMessage = Self.describe(error) }
    }

    func releaseProject() async {
        chatGPTWorkGeneration += 1
        await chatGPT.cancelAndWait()
        projectAccess?.stopAccessingSecurityScopedResource()
        skillAccess?.stopAccessingSecurityScopedResource()
        projectAccess = nil
        skillAccess = nil
        project = nil
        analyses = [:]
        mappingProposals = [:]
        datasetAdvice = ""
        comparison = ""
        captionDrafts = [:]
        usingPodCaptioner = false
        requestBaseURL = ""
    }

    func closeProject() async {
        await stopEverything()
        guard !gpu.hasRunningPod else { errorMessage = gpu.message; return }
        await releaseProject()
    }

    func stopEverything() async {
        chatGPTWorkGeneration += 1
        await chatGPT.cancelAndWait()
        task?.cancel()
        await task?.value
        await gpu.stopEverything()
    }

    func saveProject() {
        do {
            try project?.save()
            message = unsavedCaptionCount > 0
                ? "Project configuration saved. "
                + "Save your \(unsavedCaptionCount) caption drafts on Review before closing."
                : "Project saved."
        } catch { errorMessage = Self.describe(error) }
    }

    func next() {
        step = StudioStep(rawValue: min((step ?? .images).rawValue + 1, 8))
    }

    func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform("Importing photos…") {
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try self.project?.importFiles([url])
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            try await self.analyzeImages()
            self.message = "Photos imported. Warnings help you choose a varied, clear set."
        }
    }

    func importFolder() {
        guard let folder = ProjectAccess.chooseFolder(prompt: "Import photos") else { return }
        perform("Importing folder photos…") {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let source = try LocalFolderSource(directory: folder)
            try self.project?.importFiles(source.files)
            self.selectedImageID = self.project?.images.first?.id
            try await self.analyzeImages()
            self.message = "Photos imported."
        }
    }

    func analyzeImages() async throws {
        guard let project else { return }
        analyses = try await inspector.analyze(project.images.map(\.url))
    }

    func chooseSkill() {
        guard let url = ProjectAccess.chooseFolder(prompt: "Choose skill") else { return }
        do {
            _ = url.startAccessingSecurityScopedResource()
            let skill = try Skills.load(url)
            skillAccess?.stopAccessingSecurityScopedResource()
            skillAccess = url
            project?.job.skill = url.path
            if let first = skill.profiles().first { project?.job.profile = first }
            try ProjectAccess.remember(url, collection: "skillBookmarks")
            saveProject()
        } catch { url.stopAccessingSecurityScopedResource(); errorMessage = Self.describe(error) }
    }

    func configureGPU() {
        normalizePodImageChoice()
        gpu.triggerWords = project?.job.triggers.joined(separator: ",") ?? ""
        gpu.profile = project?.job.profile ?? "flux-image"
        if !gpu.hasRunningPod { gpu.trainer = gpu.profile == "ltx-image" ? "ltx" : "aitoolkit" }
        guard !demoMode else { return }
        do {
            try gpu.configure(
                runpodKey: keyStore.read("runpod") ?? "",
                hubToken: keyStore.read("huggingface") ?? "",
                imageName: podImageName,
                networkVolumeID: volumeID.isEmpty ? nil : volumeID
            )
        } catch { errorMessage = Self.describe(error) }
    }

    func selectedSkill() throws -> Skill {
        guard let path = project?.job.skill else { return try Skills.load() }
        guard let skillAccess, skillAccess.path == path else {
            throw StudioError
                .message("Choose this project's skill folder on Captioning to grant access before running.")
        }
        return try Skills.load(skillAccess)
    }

    // MARK: - Lane ui stored state (added 2026-10-11; owned by the view layer, see AppLifetime.swift)

    /// The confirmation the window is presenting, if any. Views present it; `ask(_:)` awaits the answer.
    var pendingPrompt: StudioPrompt?
    /// Set once the user has answered the quit confirmation, so the second terminate pass does not ask again.
    var quitDecision: StudioCloseDecision?
    /// The GPU workspace whose RunPod and Hub keys were last read from the Keychain.
    @ObservationIgnored weak var gpuKeysLoadedFor: GPUWorkspace?
    /// Review's list selection; kept here so it survives moving between screens.
    var reviewSelection: Set<String> = []
    /// The Monitor tab last shown.
    var monitorTab = MonitorTab.progress
    /// True only while an action the person already confirmed discarding drafts for is starting.
    /// `confirmDiscardCaptionDrafts()` reads it; the drafts themselves are cleared by `releaseProject()`
    /// once the switch or close really happens, so a refused or cancelled action keeps them.
    @ObservationIgnored var draftDiscardConfirmed = false

    // MARK: - End lane ui stored state
}
