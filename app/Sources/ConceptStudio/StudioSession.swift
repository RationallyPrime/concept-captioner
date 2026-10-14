import ConceptCore
import Foundation
import Observation

struct CaptionDraft: Equatable {
    var text: String
    var isFinal: Bool
}

struct MappingSnapshot: Equatable {
    let sampleID: String
    let mapping: Job.Mapping?
}

struct MappingUndo: Equatable {
    let snapshots: [MappingSnapshot]
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
    var project: StudioProject? {
        didSet {
            if step == .mapping, project?.job.requiresLocatorMapping == false { step = .captioning }
            if project?.job.concepts.isEmpty == true, step != .images, step != .concepts { step = .concepts }
        }
    }

    var advancedUser = false {
        didSet { preferences.set(advancedUser, forKey: "ConceptStudio.advancedUser") }
    }

    var demoMode = false
    var step: StudioStep? = .images {
        didSet {
            if step != oldValue, !busy, !editing { message = "" }
        }
    }

    var selectedImageID: String?
    var message = ""
    var errorMessage: String?
    /// The run gate is occupied (see `WorkGate.run`).
    var busy = false
    /// The edit gate is occupied (see `WorkGate.edit`).
    var editing = false
    var completed = 0
    var partialCaptions: [String: String] = [:]
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
    @ObservationIgnored var activePublishID: UUID?
    var datasetAdvice = ""
    var mappingProposals: [String: Job.Mapping] = [:]
    var mappingUndo: [MappingUndo] = []
    var comparison = ""
    var captionDrafts: [String: CaptionDraft] = [:]
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
    var providerModelChoices: [ProviderModelCacheKey: [ProviderModelChoice]] = [:]
    var providerCredentialRevision = 0
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
        advancedUser = preferences.bool(forKey: "ConceptStudio.advancedUser")
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
        invalidateMappingUndo()
        comparison = ""
    }

    func invalidateMappingUndo() {
        mappingUndo = []
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
        let originatingStep = step
        let work = Task {
            defer {
                switch gate {
                case .run: busy = false; task = nil
                case .edit: editing = false; editTask = nil
                }
                // Keep active progress visible across navigation, but do not leave its result
                // underneath a different step when the operation settles.
                if busy || editing {
                    message = busy ? runTitle : editTitle
                } else if step != originatingStep {
                    message = ""
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

    func cancel() {
        activePublishID = nil
        task?.cancel()
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

extension StudioSession {
    static func describe(_ error: any Error) -> String {
        if let error = error as? StudioError { return error.localizedDescription }
        return error.localizedDescription + " Check the relevant settings and try again."
    }
}
