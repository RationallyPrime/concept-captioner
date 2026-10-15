import ConceptCore
import Foundation
import Observation

@MainActor @Observable
final class GPUWorkspace {
    let demoMode: Bool
    var offers: [GPUOffer] = []
    var volumes: [GPUVolume] = []
    var selectedGPU = ""
    var selectedVolume = ""
    @ObservationIgnored var hasLoadedVolumes = false
    var gpuCount = 1
    /// The limit for the next rental. While a pod runs, `activeBudget` is the one enforced.
    var budget = 10.0
    /// The cap selected for the next training run; separate from the whole-computer rental cap.
    var runBudget = 10.0
    var idleMinutes = 15 {
        didSet { persist() }
    }

    var pod: RentedPod? {
        didSet {
            sleepGuard.hold(!demoMode && pod?.isRunning == true)
            if oldValue?.id != pod?.id { captionServerActive = nil }
            if pod?.isRunning == false { captionServerActive = false }
        }
    }

    var plan: TrainingPlan?
    /// nil until this computer's service list has been read; never inferred from the GPU count.
    var captionServerActive: Bool?
    var storage: AgentStorageUsage?
    var message = "Refresh available computers to see current prices."
    var isBusy = false
    private var operationRevision = 0
    var isStopping = false
    var elapsedCost = 0.0
    /// The supported models. Every default below starts from its default model's row.
    @ObservationIgnored let modelTable: ModelTable
    var trainer: String {
        didSet {
            if oldValue != trainer {
                baseModel = modelTable.trainerDefault(trainer).modelRef
            }
        }
    }

    var baseModel: String
    /// The training length in the selected model's unit: steps, or passes over each item for an epochs row.
    var steps: Int
    var rank: Int
    var alpha: Int
    var batchSize: Int
    var accumulation: Int
    var nativeRecipe: NativeTrainingRecipe?
    var nativeRecipeOriginal: URL?
    var initialCheckpoint: URL?
    var learningRate: Double
    var checkpointEvery: Int
    var checkpointRetention: Int
    var checkpointPrecision: String
    /// The share of training images seen without their caption (the row's `recipe.caption_dropout`).
    var captionDropout: Double
    var guidanceLoss = false
    var guidanceTargetText = GPUWorkspace.defaultGuidanceTarget
    var guidanceTarget: JSONValue {
        (try? JSONValue(parsing: Data(guidanceTargetText.utf8))) ?? .null
    }

    /// Training resolution in pixels; one of `resolutionChoices`. Shown under Advanced.
    var trainingResolutions: [Int]
    var resolution: Int {
        get { trainingResolutions.max() ?? modelTable.defaultRow.resolution.defaults.max() ?? 0 }
        set { trainingResolutions = [newValue] }
    }

    /// Regularisation images drawn from the base model and trained beside the person's own (the row's
    /// `regularization` field). Only meaningful while the selected model offers it.
    var regularizationOn = false
    var regularizationImages: Int
    var regularizationWeight: Double
    /// The offer the count and strength last followed, to tell a value the person edited from one still at a default.
    @ObservationIgnored var regularizationAligned: ModelRow.Regularization?
    /// Representation alignment (the row's `repa` field); off unless a row turns it on by default.
    var repaOn = false
    /// The open project's concepts as trigger → class noun. Regularisation images show the class nouns.
    var conceptClassNouns: [String: String] = [:]
    /// Set while the pod draws regularisation images, before the trainer reports its first measurement.
    var regularizationProgress: RegularizationProgress?

    /// Sample images during training. Off by default: sample generation is unverified (POD-SPEC 4.2).
    var samplesEnabled = false
    var runID = ""
    static let defaultSeed = 42
    var seed = GPUWorkspace.defaultSeed
    var datasetRevision = ""
    var datasetContainsVideo = false
    /// How many images and clips the next run trains on; an epochs row turns passes into steps with it.
    var datasetItemCount = 0
    var runHistory: [TrainingRun] = []
    var selectedHistoryRunID = ""
    var repeatSourceRunID = ""
    var generations: [GeneratedComparison] = []
    var generation: GeneratedComparison?
    var triggerWords = "NORA7"
    var profile: String
    var keepCaptionServer = false
    var captionModel = "Qwen/Qwen3-VL-8B-Instruct"
    var points: [TrainingPoint] = []
    var logs = ""
    var trainingState = "Not started"
    /// The latest run's result and where it went.
    var result: TrainingResult?
    /// Running pods this app created that are not the one under its control (found on launch).
    var strayPods: [RentedPod] = []
    /// The open project; results without a Hub token are saved under `<project>/results/<run-id>/`.
    var projectFolder: URL? {
        didSet { if oldValue != projectFolder { loadProjectRecord() } }
    }

    /// The pod agent's bearer (also its vLLM key). Set only by renting, restoring or reconciling.
    private(set) var agentToken = ""
    /// A failure the window alert should show even when the GPU screen is not open.
    var failure: String?

    @ObservationIgnored let transport: any HTTPTransport
    @ObservationIgnored let preferences: UserDefaults
    @ObservationIgnored let saveAgentToken: (String, String) throws -> Void
    @ObservationIgnored let readAgentToken: (String) throws -> String?
    @ObservationIgnored let deleteAgentToken: (String) throws -> Void
    @ObservationIgnored let uploader: any FileUploading
    @ObservationIgnored let downloader: any FileDownloading
    @ObservationIgnored let sleepGuard: SleepAssertion
    @ObservationIgnored var provider: (any GPUProvider)?
    @ObservationIgnored var agent: (any PodAgent)?
    /// Observed: whether training reads a published dataset or uploads directly depends on it.
    var hubToken = ""
    @ObservationIgnored var imageName = ""
    @ObservationIgnored var saved: SavedPod?
    @ObservationIgnored var lastActivity = Date()
    /// The status line a failed refresh wrote; the next refresh that succeeds clears it.
    @ObservationIgnored var refreshFailureMessage: String?
    /// Work the app does for the computer outside `perform`, such as publishing the dataset it trains on.
    /// The idle stop waits for it and counts idle time from when it ends.
    @ObservationIgnored var appWorkInFlight = 0
    /// The stopped computer's host had no free GPU when asked to start; Remove and rent is the way out.
    var restartBlockedByHost = false
    @ObservationIgnored var monitorTask: Task<Void, Never>?
    @ObservationIgnored var operationTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var retrievalTask: Task<Void, Never>?
    @ObservationIgnored var lastAutomaticRetrieval = Date.distantPast
    /// Minimum gap between automatic retrieval attempts after one fails.
    @ObservationIgnored var automaticRetrievalInterval: TimeInterval = 60
    @ObservationIgnored var historyRunID: String?
    @ObservationIgnored var reconciled = false

    static let activePodKey = "ConceptStudio.activePod"
    static let pendingResultKey = "ConceptStudio.pendingResult"
    /// Set when the person chose "No saved storage", so later launches do not select a network volume.
    static let noSavedStorageKey = "ConceptStudio.noSavedStorage"

    init(
        demoMode: Bool,
        transport: any HTTPTransport = URLSessionTransport(timeout: 45),
        preferences: UserDefaults = .standard,
        readAgentToken: @escaping (String) throws -> String? = { try KeychainStore().read($0) },
        saveAgentToken: @escaping (String, String) throws -> Void = { token, account in
            try KeychainStore().save(token, account: account)
        },
        // KeychainStore.save with an empty value deletes the item (SecItemDelete).
        deleteAgentToken: @escaping (String) throws -> Void = { try KeychainStore().save("", account: $0) },
        downloader: any FileDownloading = URLSessionDownloader(),
        uploader: any FileUploading = URLSessionUploader(),
        keepAwake: SleepAssertion? = nil,
        modelTable: ModelTable = .shared
    ) {
        self.demoMode = demoMode
        self.modelTable = modelTable
        let start = modelTable.defaultRow
        trainer = start.trainer
        baseModel = start.modelRef
        steps = start.recipe.length
        rank = start.recipe.rank
        alpha = start.recipe.alpha
        batchSize = start.recipe.batchSize
        accumulation = start.recipe.gradientAccumulation
        learningRate = start.recipe.learningRate
        checkpointEvery = start.recipe.checkpoints.every
        checkpointRetention = start.recipe.checkpoints.keep
        checkpointPrecision = modelTable.checkpointPrecision(for: start)
        captionDropout = start.recipe.captionDropout ?? 0
        trainingResolutions = start.resolution.defaults
        let reference = modelTable.models.lazy.compactMap(\.regularization).first
        regularizationImages = reference?.images ?? 1
        regularizationWeight = reference?.weight ?? 1
        regularizationAligned = reference
        profile = start.captions.imageProfile
        self.transport = transport
        self.preferences = preferences
        self.saveAgentToken = saveAgentToken
        self.readAgentToken = readAgentToken
        self.deleteAgentToken = deleteAgentToken
        self.downloader = downloader
        self.uploader = uploader
        sleepGuard = keepAwake ?? .system()
        if demoMode {
            provider = DemoGPUProvider()
            imageName = "demo"
            message = "Demo computers are simulated. No account, network or money is used."
        }
    }

    func configure(runpodKey: String, hubToken: String, imageName: String, networkVolumeID: String? = nil) throws {
        guard !demoMode else { return }
        provider = runpodKey.isEmpty ? nil : RunPodProvider(key: runpodKey, transport: transport)
        self.hubToken = hubToken
        self.imageName = imageName
        if let networkVolumeID, !prefersNoSavedStorage { selectedVolume = networkVolumeID }
        if result == nil, let data = preferences.data(forKey: Self.pendingResultKey) {
            result = try? JSONDecoder().decode(TrainingResult.self, from: data)
            if let result, !RunArtifacts.validRunID(result.runID) { self.result = nil }
        }
        if pod == nil, let data = preferences.data(forKey: Self.activePodKey),
           let previous = try? JSONDecoder().decode(SavedPod.self, from: data) {
            saved = previous
            pod = previous.pod
            budget = previous.budget
            if repeatSourceRunID.isEmpty, previous.pod.isRunning { trainer = previous.trainer }
            runID = previous.runID
            points = previous.points
            result = previous.result ?? result
            // The loaded project record owns history. The global pod record owns billing
            // and pending-output custody, including while Welcome or another project is open.
            generation = previous.generation
            idleMinutes = previous.idleMinutes
            watch()
        }
        if provider != nil, !reconciled {
            reconciled = true
            Task { await self.reconcile() }
        }
        if let pod, agent == nil {
            agentToken = try readAgentToken("pod.\(pod.id)") ?? ""
            connectAgent(pod)
        }
    }

    /// Reads a pod's agent token from the Keychain; an unreadable token leaves the provider-level
    /// budget and idle stop working.
    func restoreAgentToken(podID: String) {
        agentToken = (try? readAgentToken("pod.\(podID)")) ?? ""
    }

    func refreshOffers() async {
        await perform {
            guard let provider = self.provider else {
                throw StudioError.message("Add your RunPod key in Settings, then refresh available computers.")
            }
            async let offers = provider.offers(
                count: self.gpuCount,
                minCudaVersion: self.modelTable.minimumCUDA(self.trainer)
            )
            async let volumes = provider.volumes()
            self.offers = try await offers
            self.volumes = try await volumes
            if (!self.hasLoadedVolumes && self.selectedVolume.isEmpty && !self.prefersNoSavedStorage)
                || (!self.selectedVolume.isEmpty && !self.volumes.contains(where: { $0.id == self.selectedVolume })) {
                self.selectedVolume = self.volumes.first?.id ?? ""
            }
            self.hasLoadedVolumes = true
            self.selectAvailableOffer()
            self.message = self.availableOffers.isEmpty
                ? "No computers are available beside this storage. Choose other storage, fewer GPUs, or refresh later."
                : "Choose a computer and storage, then check the price before renting."
        }
    }

    func rent() async {
        await perform {
            guard self.pod == nil else {
                throw StudioError
                    .message(
                        "Stop and remove your current computer before renting another. Saved network storage remains."
                    )
            }
            guard let provider = self.provider,
                  let offer = self.availableOffers.first(where: { $0.id == self.selectedGPU }),
                  self.selectedVolume.isEmpty || self.volumes.contains(where: { $0.id == self.selectedVolume }),
                  self.budget.isFinite, self.budget > 0 else {
                throw StudioError
                    .message(
                        "Choose an available computer and a positive budget."
                    )
            }
            let volume = self.volumes.first { $0.id == self.selectedVolume }
            let started = Date()
            self.agentToken = try Self.newAgentToken()
            // Credentials go to the account's secret store; the pod only ever sees placeholders.
            let credentials = try await self.storeCredentials(provider)
            let created = try await self.createPod(provider, offer: offer, volume: volume, credentials: credentials)
            self.pod = created
            self.plan = nil
            self.storage = nil
            self.runID = ""
            self.trainingState = "Not started"
            self.points = []
            self.regularizationProgress = nil
            self.logs = ""
            self.elapsedCost = 0
            self.saved = SavedPod(
                pod: created, started: started, hourlyRate: max(created.cost, self.quotedHourlyRate),
                budget: self.budget, trainer: self.trainer, runID: "",
                idleMinutes: self.idleMinutes, volumeID: volume?.id ?? "pod:" + created.id,
                agentSecret: credentials.agentSecret
            )
            self.connectAgent(created)
            self.lastActivity = Date()
            self.watch()
            if !self.demoMode {
                self.persist()
                do {
                    try self.saveAgentToken(self.agentToken, "pod.\(created.id)")
                } catch {
                    try await provider.stop(id: created.id)
                    throw error
                }
            }
            self.message = "Your computer is rented and its control agent is connecting. "
                + "Its cost is visible below; you can stop it at any time."
        }
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let work = Task { await self.refreshState() }
        refreshTask = work
        await work.value
        refreshTask = nil
    }

    private func refreshState() async {
        guard let provider, let current = pod, hasRunningPod else { return }
        let resultBefore = result
        let settlementRevision = isBusy ? nil : operationRevision
        var agentAnswered = false
        do {
            try await enforceLimits()
            // A pod found stopped ends the polling, so a resolved error must clear here too.
            guard hasRunningPod else { clearRefreshFailure(); return }
            let currentStatus = try await provider.status(id: current.id)
            if !currentStatus.isRunning { freezePodCost() }
            updateHourlyRate(currentStatus)
            pod = currentStatus
            persist()
            guard hasRunningPod else { clearRefreshFailure(); return }
            guard let agent else {
                throw StudioError.message("Open Settings to restore this computer’s saved connection.")
            }
            if plan == nil {
                plan = try await agent.plan()
                storage = try? await agent.storageUsage()
            }
            let services = try await agent.services()
            updateCaptionServerState(services)
            agentAnswered = true
            if message.hasPrefix("Your computer is rented and its control agent is connecting.") {
                message = "Your computer is connected and ready. "
                    + "Its cost is visible below; you can stop it at any time."
            }
            let active = services.contains { $0.active && !["tensorboard", "vllm"].contains($0.name) }
            if active { lastActivity = Date() }
            updateTrainingService(services)
            if !runID.isEmpty { try await updateProgress(agent, services: services) }
            // A result created while this refresh was in flight is judged on the next one.
            if settlementRevision == operationRevision, !isBusy, result == resultBefore { try await settleResult(
                agent,
                services: services
            ) }
            if settlementRevision == operationRevision,
               !isBusy { try await settleGeneration(agent, services: services) }
            clearRefreshFailure()
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
            refreshFailureMessage = message
        }
        // A failed agent/proxy request must not suppress the provider-level idle stop, but a
        // finished LoRA that is neither pushed nor downloaded keeps the computer up, and so does a
        // run the agent still answers for whose result has not been settled yet.
        if hasRunningPod, !isBusy, appWorkInFlight == 0, !resultNeedsSaving, !(agentAnswered && resultUnsettled),
           Date().timeIntervalSince(lastActivity) >= Double(idleMinutes * 60) {
            await stopEverything()
            if !hasRunningPod { message = "Stopped the idle computer to avoid further GPU charges." }
        }
    }

    func connectAgent(_ pod: RentedPod) {
        historyRunID = nil
        if demoMode {
            agent = DemoPodAgent(count: pod.gpu.count)
        } else if let provider {
            agent = PodAgentClient(
                baseURL: provider.url(for: pod, port: PodPort.agent), token: agentToken,
                transport: transport, downloader: downloader, uploader: uploader
            )
        }
    }

    func persist() {
        captureRunProgress()
        if var saved, let pod {
            saved.pod = pod
            saved.trainer = trainer
            saved.runID = runID
            saved.idleMinutes = idleMinutes
            saved.points = points
            saved.result = result
            if let run = runHistory.first(where: { $0.runID == runID }) {
                saved.run = run
            } else if saved.run?.runID != runID { saved.run = nil }
            saved.generation = generation
            self.saved = saved
            if !demoMode, let data = try? JSONEncoder().encode(saved) {
                preferences.set(data, forKey: Self.activePodKey)
            }
        }
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy, !isStopping else { return }
        operationRevision += 1
        isBusy = true
        let work = Task {
            defer {
                self.isBusy = false
                // Waiting on the app's own work (an upload, a download) is not idle time.
                self.noteActivity()
            }
            do {
                try await action()
            } catch is CancellationError {
                self.message = "Action cancelled. Check the computer status before closing."
            } catch {
                self.message = error.localizedDescription
                self.failure = self.message
            }
        }
        operationTask = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

extension GPUWorkspace {
    func watch() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard self?.hasRunningPod == true else { return }
                do {
                    try await Task.sleep(for: .seconds(self?.demoMode == true ? 1 : 5))
                } catch { return }
            }
        }
    }

    /// Waits until the service has exited. `whileWaiting` runs after each check that finds it still running.
    func waitForService(
        _ name: String, allowStopped: Bool = false, whileWaiting: (() async -> Void)? = nil
    ) async throws {
        guard let agent else { return }
        while true {
            try Task.checkCancellation()
            let services = try await agent.services()
            updateCaptionServerState(services)
            let service = services.first(where: { $0.name == name })
            if let service, !service.active {
                guard service.state == "exited" || (allowStopped && service.state == "stopped") else {
                    throw StudioError
                        .message("\(name) did not finish. Read its logs and retry after correcting the cause.")
                }
                return
            }
            await whileWaiting?()
            try await Task.sleep(for: .seconds(demoMode ? 0.1 : 2))
        }
    }

    func noteActivity() {
        lastActivity = Date()
    }

    var quotedHourlyRate: Double {
        (availableOffers.first(where: { $0.id == selectedGPU })?.price.secure ?? 0) * Double(gpuCount)
    }

    var availableOffers: [GPUOffer] {
        let volume = volumes.first { $0.id == selectedVolume }
        guard selectedVolume.isEmpty || volume != nil else { return [] }
        return offers.filter { offer in
            offer.memory >= requiredGPUMemoryGB && offer.secure && offer.maxCount.secure >= gpuCount
                && offer.price.secure > 0 && (volume.map { offer.isAvailable(in: $0.dataCenter) }
                    ?? offer.hasAvailableLocation)
        }
    }

    var prefersNoSavedStorage: Bool {
        !demoMode && preferences.bool(forKey: Self.noSavedStorageKey)
    }

    /// The person's storage choice, remembered across launches like the Settings volume ID.
    func chooseStorage(_ volumeID: String) {
        selectedVolume = volumeID
        if !demoMode { preferences.set(volumeID.isEmpty, forKey: Self.noSavedStorageKey) }
        selectAvailableOffer()
    }

    func selectAvailableOffer() {
        if !availableOffers.contains(where: { $0.id == selectedGPU }) {
            selectedGPU = availableOffers.first?.id ?? ""
        }
    }

    /// The pod's control agent, as the provider exposes its port.
    var agentURL: URL? {
        guard let pod, let provider else { return nil }
        return provider.url(for: pod, port: PodPort.agent)
    }

    var tensorBoardURL: URL? {
        agentURL?.appendingPathComponent("tensorboard/")
    }

    var captionEndpoint: URL? {
        guard let pod, pod.isRunning, let provider else { return nil }
        return provider.url(for: pod, port: PodPort.inference).appendingPathComponent("v1")
    }

    var hasRunningPod: Bool {
        pod?.isRunning == true
    }

    var isTraining: Bool {
        ["running", "stuck"].contains(trainingState)
    }

    /// Whether the user has given the app a Hub token that training can push with.
    var canPushToHub: Bool {
        demoMode || !hubToken.isEmpty
    }

    /// The network volume mounted at /workspace on the current pod.
    var currentVolumeID: String {
        if let volume = saved?.volumeID, !volume.isEmpty { return volume }
        if let pod { return pod.volumeID ?? "pod:" + pod.id }
        return selectedVolume
    }

    /// Whether the Mac is being kept awake for the running pod.
    var keepsMacAwake: Bool {
        sleepGuard.isHeld
    }
}

extension GPUWorkspace {
    private func updateProgress(_ agent: any PodAgent, services: [AgentService]) async throws {
        if historyRunID != runID {
            // TensorBoard is started by train(); after an agent restart it is down until started again.
            if !services.contains(where: { $0.name == "tensorboard" && $0.active }) {
                try? await agent.start("tensorboard", gpus: [], params: ["logdir": .string("/workspace/runs")])
            }
            // Retried on every refresh until the full curve arrives.
            if let history = try? await agent.history(runID: runID), !history.isEmpty {
                merge(history)
                historyRunID = runID
            }
        }
        if let point = try await agent.latest(runID: runID) { merge([point]) }
        if let log = try? await agent.runLog(runID: runID) { logs = log }
        persist()
        saveProjectRecord()
    }

    private func merge(_ incoming: [TrainingPoint]) {
        var byStep = Dictionary(points.map { ($0.step, $0) }, uniquingKeysWith: { first, _ in first })
        for point in incoming {
            byStep[point.step] = point
        }
        points = byStep.values.sorted { $0.step < $1.step }
    }
}
