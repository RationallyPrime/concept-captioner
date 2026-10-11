import AppKit
import ConceptCore
import Observation

struct CaptionDraft: Equatable {
    var text: String
    var isFinal: Bool
}

/// A question the session needs the user to answer before it continues. The session never
/// presents UI itself: `confirm(_:)` asks through `ask(_:)` (AppLifetime.swift), which publishes
/// `pendingPrompt` for the window's `StudioPromptPresenter`.
enum StudioConfirmation: Equatable {
    /// Switching project, opening the demo or closing would discard unsaved caption edits.
    case discardCaptionDrafts(count: Int)
    /// Closing (the project, the window or the app) while work runs or a rented computer bills.
    case stopAndClose(podRunning: Bool)

    var title: String {
        switch self {
        case .discardCaptionDrafts: "Discard unsaved caption edits?"
        case let .stopAndClose(podRunning):
            podRunning ? "Stop the rented computer before closing?" : "Cancel the current work?"
        }
    }

    var message: String {
        switch self {
        case let .discardCaptionDrafts(count):
            "\(count) unsaved caption edits will be discarded. "
                + "Save those captions on Review to keep them. Saved captions are unchanged."
        case let .stopAndClose(podRunning):
            podRunning
                ? "The computer is still running and costing money. Closing will cancel local work and stop it. "
                + "If the stop cannot be confirmed, this project will stay open."
                : "Completed captions are saved. Work still in progress will be cancelled before the project closes."
        }
    }

    var confirmTitle: String {
        switch self {
        case .discardCaptionDrafts: "Discard edits"
        case .stopAndClose: "Stop and close"
        }
    }

    var cancelTitle: String {
        switch self {
        case .discardCaptionDrafts: "Keep editing"
        case .stopAndClose: "Keep open"
        }
    }

    /// Confirming loses work or stops something; present the confirm button as destructive.
    var isDestructive: Bool {
        true
    }
}

/// Two independent work slots. `run` holds long work (caption runs, imports, publishing, opening a
/// project, model requests); `edit` holds short saves the user makes while reviewing, so Review and
/// Concepts stay usable while a run is in progress.
enum WorkGate {
    case run, edit
}

@MainActor @Observable
final class StudioSession {
    var project: StudioProject?
    var demoMode = false
    var step: StudioStep? = .images
    var selectedImageID: String?
    var message = ""
    var errorMessage: String?
    /// The run gate is occupied (see `WorkGate.run`).
    var busy = false
    /// The edit gate is occupied (see `WorkGate.edit`).
    var editing = false
    var completed = 0
    var task: Task<Void, Never>?
    var editTask: Task<Void, Never>?
    @ObservationIgnored var runTitle = ""
    @ObservationIgnored var editTitle = ""
    /// Photos the current caption run has not reported yet; saving one of them waits for its result.
    var runPendingIDs: Set<String> = []
    var scenario: DemoScenario = .success
    var analyses: [String: ImageAnalysis] = [:]
    var analyzing = false
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var analysisGeneration = 0
    var datasetAdvice = ""
    var mappingProposals: [String: Job.Mapping] = [:]
    var comparison = ""
    private(set) var captionDrafts: [String: CaptionDraft] = [:]
    var usingPodCaptioner = false
    var startupRestored = false
    var recentPaths: [String] = []
    var endpointKind = ""
    var modelName = ""
    var criticKind = ""
    var criticModel = ""
    var openAIUsesChatGPT = false
    var chatGPT: ChatGPTAccounts
    var openRouter: OpenRouterConnection
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
    /// App-only settings for the open project (`<project>/.conceptstudio/project.json`).
    var projectState = ProjectAppState()
    var podImageName = ""
    var volumeID = ""
    var projectAccess: URL?
    var gpu: GPUWorkspace
    let inspector = VisionInspector()
    let preferences: UserDefaults
    let secrets: any SecretStore
    let demoDirectory: URL

    init(
        preferences: UserDefaults = .standard,
        chatGPT: ChatGPTAccounts? = nil,
        openRouter: OpenRouterConnection? = nil,
        secrets: any SecretStore = KeychainStore(),
        demoDirectory: URL = DemoProject.defaultDirectory
    ) {
        self.preferences = preferences
        self.secrets = secrets
        self.demoDirectory = demoDirectory
        self.chatGPT = chatGPT ?? ChatGPTAccounts(preferences: preferences)
        self.openRouter = openRouter ?? OpenRouterConnection(secrets: secrets)
        gpu = Self.makeGPUWorkspace(demoMode: false, preferences: preferences, secrets: secrets)
        recentPaths = recents.paths
        loadSavedChoices()
    }

    static func makeGPUWorkspace(demoMode: Bool, preferences: UserDefaults, secrets: any SecretStore) -> GPUWorkspace {
        GPUWorkspace(
            demoMode: demoMode,
            preferences: preferences,
            readAgentToken: { try secrets.read($0) },
            saveAgentToken: { token, account in try secrets.save(token, account: account) }
        )
    }

    func makeGPUWorkspace(demoMode: Bool) -> GPUWorkspace {
        Self.makeGPUWorkspace(demoMode: demoMode, preferences: preferences, secrets: secrets)
    }

    var recents: RecentProjects {
        RecentProjects(preferences: preferences)
    }

    var selectedImage: ProjectImage? {
        project?.images.first { $0.id == selectedImageID }
    }

    // MARK: Project-only settings

    /// The dataset repository Publish writes to; remembered per project, blank for a new project.
    var repoID: String {
        get { projectState.dataset.repo }
        set { updateProjectState {
            if $0.dataset.repo != newValue { $0.datasetRevision = "" }
            $0.dataset.repo = newValue
        } }
    }

    var privateDataset: Bool {
        get { projectState.dataset.isPrivate }
        set { updateProjectState { $0.dataset.isPrivate = newValue } }
    }

    /// Where training uploads the LoRA; remembered per project like the dataset destination.
    var trainingOutputRepo: String {
        get { projectState.trainingOutput.repo }
        set { updateProjectState { $0.trainingOutput.repo = newValue } }
    }

    var trainingOutputPrivate: Bool {
        get { projectState.trainingOutput.isPrivate }
        set { updateProjectState { $0.trainingOutput.isPrivate = newValue } }
    }

    /// Change the project's app-only settings and save them with the project (not in demo mode).
    func updateProjectState(_ change: (inout ProjectAppState) -> Void) {
        var state = projectState
        change(&state)
        guard state != projectState else { return }
        projectState = state
        guard let project, !demoMode else { return }
        do { try state.save(to: project.directory) } catch { errorMessage = Self.describe(error) }
    }

    // MARK: Caption drafts

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

    func invalidateMediaDraft(id: String) {
        captionDrafts[id] = nil
        mappingProposals[id] = nil
        comparison = ""
    }

    func hasUnsavedCaption(for image: ProjectImage) -> Bool {
        captionDraft(for: image) != CaptionDraft(text: image.caption, isFinal: image.isFinal)
    }

    var unsavedCaptionCount: Int {
        project?.allMedia.count(where: { hasUnsavedCaption(for: $0) }) ?? 0
    }

    var captionDiscardWarning: String? {
        guard unsavedCaptionCount > 0 else { return nil }
        return StudioConfirmation.discardCaptionDrafts(count: unsavedCaptionCount).message
    }

    var needsCloseConfirmation: Bool {
        unsavedCaptionCount > 0 || busy || editing || chatGPT.isBusy || openRouter.isBusy
            || gpu.hasRunningPod || gpu.isBusy
    }

    func clearSavedCaptionDraft(_ draft: CaptionDraft, for id: String) {
        // A later edit must survive completion of an earlier save.
        if captionDrafts[id] == draft { captionDrafts[id] = nil }
    }

    var unmappedCount: Int {
        project?.job.unmapped(project?.images.map(\.id) ?? []).count ?? 0
    }

    var keyStore: SessionKeyStore {
        SessionKeyStore(secrets: secrets, vllmBaseURL: customBaseURL.isEmpty ? nil : customBaseURL)
    }

    // MARK: Work gates

    /// Start `operation` in the given gate and return true. When that gate is occupied the action
    /// does not start, `errorMessage` says what it is waiting for, and the result is false.
    @discardableResult
    func perform(
        _ title: String,
        gate: WorkGate = .run,
        operation: @escaping @MainActor () async throws -> Void
    ) -> Bool {
        switch gate {
        case .run:
            guard !busy else { refuse(title, waitingFor: runTitle); return false }
            busy = true
            runTitle = title
            completed = 0
        case .edit:
            guard !editing else { refuse(title, waitingFor: editTitle); return false }
            editing = true
            editTitle = title
        }
        message = title
        errorMessage = nil
        let work = Task {
            defer {
                switch gate {
                case .run: busy = false; task = nil
                case .edit: editing = false; editTask = nil
                }
            }
            do {
                try await operation()
                if Task.isCancelled { message = "Cancelled. Your completed work is saved." }
            } catch is CancellationError {
                message = "Cancelled. Your completed work is saved."
            } catch {
                errorMessage = Self.describe(error)
            }
        }
        switch gate {
        case .run: task = work
        case .edit: editTask = work
        }
        return true
    }

    private func refuse(_ title: String, waitingFor current: String) {
        errorMessage = "“\(Self.plain(title))” did not start because “\(Self.plain(current))” is still in progress. "
            + "Wait for it to finish, or choose Cancel and try again."
    }

    private static func plain(_ title: String) -> String {
        title.trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? StudioError { return error.localizedDescription }
        return error.localizedDescription + " Check the relevant settings and try again."
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Confirmations

    /// Ask the user and wait for the answer, through the window's one prompt (`ask(_:)`). A newer
    /// question replaces (and declines) an older one.
    func confirm(_ confirmation: StudioConfirmation) async -> Bool {
        switch confirmation {
        case .discardCaptionDrafts:
            await ask(.discardCaptionDrafts(warning: confirmation.message)) == .confirm
        case .stopAndClose:
            await ask(.stopWork(runningWork(for: .closeProject))) == .confirm
        }
    }

    /// Run `action` now when nothing needs confirming, otherwise after the user confirms.
    func whenConfirmed(_ confirmation: StudioConfirmation?, _ action: @escaping @MainActor () -> Void) {
        guard let confirmation else { return action() }
        Task { if await confirm(confirmation) { action() } }
    }

    var discardDraftsConfirmation: StudioConfirmation? {
        unsavedCaptionCount > 0 ? .discardCaptionDrafts(count: unsavedCaptionCount) : nil
    }

    // MARK: Startup and projects

    static func startupNeedsPodRecovery(_ data: Data?) -> Bool {
        guard let data, let saved = try? JSONDecoder().decode(SavedPod.self, from: data) else { return false }
        return saved.pod.isRunning
    }

    func restoreStartupComputer() {
        guard !startupRestored else { return }
        startupRestored = true
        guard !demoMode, Self.startupNeedsPodRecovery(preferences.data(forKey: "ConceptStudio.activePod"))
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

    private func refuseWhileComputerBusy(_ reason: String) -> Bool {
        guard gpu.hasRunningPod || gpu.isBusy else { return false }
        errorMessage = reason
        return true
    }

    func useDemo() {
        guard !refuseWhileComputerBusy("Stop the rented computer before switching to the demo.") else { return }
        whenConfirmed(discardDraftsConfirmation) {
            self.perform("Opening the offline demo…") {
                await self.releaseProject()
                self.demoMode = true
                self.showChatGPTPlanNotice = false
                self.gpu = self.makeGPUWorkspace(demoMode: true)
                self.project = try await DemoProject.create(at: self.demoDirectory)
                self.gpu.projectFolder = self.project?.directory
                self.projectState = ProjectAppState(dataset: HubDestination(repo: "demo/concept-studio"))
                self.selectedImageID = self.project?.images.first?.id
                self.step = .images
                self.message = "Offline demo: synthetic photos, prepared captions and simulated services."
                self.startImageAnalysis()
            }
        }
    }

    func createProject(at url: URL) {
        guard !refuseWhileComputerBusy(
            "Finish the current computer action or Stop everything before changing projects."
        ) else { return }
        whenConfirmed(discardDraftsConfirmation) {
            self.perform("Creating your project…") {
                await self.releaseProject()
                self.demoMode = false
                self.loadSavedChoices()
                self.gpu = self.makeGPUWorkspace(demoMode: false)
                self.projectAccess = url
                _ = url.startAccessingSecurityScopedResource()
                self.project = try StudioProject.create(at: url)
                self.gpu.projectFolder = self.project?.directory
                self.projectState = ProjectAppState()
                self.rememberRecent(url)
                self.step = .images
                self.message = "Project created. Import the images or clips for your concept."
            }
        }
    }

    func openProject(url selected: URL) {
        guard !refuseWhileComputerBusy(
            "Finish the current computer action or Stop everything before changing projects."
        ) else { return }
        whenConfirmed(discardDraftsConfirmation) {
            self.perform("Opening your project…") {
                await self.releaseProject()
                self.demoMode = false
                self.loadSavedChoices()
                self.gpu = self.makeGPUWorkspace(demoMode: false)
                self.projectAccess = selected
                _ = selected.startAccessingSecurityScopedResource()
                self.project = try await StudioProject.open(at: selected)
                self.gpu.projectFolder = self.project?.directory
                self.projectState = ProjectAppState.load(from: selected)
                self.rememberRecent(selected)
                if let job = self.project?.job { self.applyJobChoices(job) }
                self.selectedImageID = self.project?.images.first?.id
                self.message = "Project opened. Your saved choices and final captions are preserved."
                self.migrateOutsideSkill()
                self.startImageAnalysis()
            }
        }
    }

    func releaseProject() async {
        chatGPTWorkGeneration += 1
        await chatGPT.cancelAndWait()
        await openRouter.cancelAndWait()
        stopImageAnalysis()
        editTask?.cancel()
        await editTask?.value
        if let prompt = pendingPrompt { answer(prompt, .cancel) }
        if demoMode, let directory = project?.directory,
           directory.standardizedFileURL == demoDirectory.standardizedFileURL {
            DemoProject.remove(at: directory)
        }
        projectAccess?.stopAccessingSecurityScopedResource()
        projectAccess = nil
        project = nil
        projectState = ProjectAppState()
        analyses = [:]
        mappingProposals = [:]
        datasetAdvice = ""
        comparison = ""
        captionDrafts = [:]
        runPendingIDs = []
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
        await openRouter.cancelAndWait()
        task?.cancel()
        editTask?.cancel()
        stopImageAnalysis()
        await task?.value
        await editTask?.value
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

    // MARK: Photos and analysis

    func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform("Importing training data…") {
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try self.project?.importFiles([url])
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            self.startImageAnalysis()
            self.message = "Training data imported. Review the selected images and clips before captioning."
        }
    }

    func importFolder(_ folder: URL) {
        perform("Importing folder contents…") {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            try self.project?.importFiles(MediaEditor.importableFiles(in: folder))
            self.selectedImageID = self.project?.images.first?.id
            self.startImageAnalysis()
            self.message = "Training data imported."
        }
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

    // MARK: - End lane ui stored state
}
