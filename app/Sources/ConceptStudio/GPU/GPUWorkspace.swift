import ConceptCore
import Foundation
import Observation
import Security

@MainActor @Observable
final class GPUWorkspace {
    let demoMode: Bool
    var offers: [GPUOffer] = []
    var volumes: [GPUVolume] = []
    var selectedGPU = ""
    var selectedVolume = ""
    var gpuCount = 1
    /// The limit for the next rental. While a pod runs, `activeBudget` is the one enforced.
    var budget = 10.0
    var idleMinutes = 15 {
        didSet { persist() }
    }

    var pod: RentedPod? {
        didSet { sleepGuard.hold(!demoMode && pod?.isRunning == true) }
    }

    var plan: TrainingPlan?
    var storage: AgentStorageUsage?
    var message = "Refresh available computers to see current prices."
    var isBusy = false
    private(set) var isStopping = false
    var elapsedCost = 0.0
    var trainer = "aitoolkit" {
        didSet {
            if oldValue != trainer {
                baseModel = trainer == "ltx" ? "Lightricks/LTX-2" : "black-forest-labs/FLUX.1-dev"
            }
        }
    }

    var baseModel = "black-forest-labs/FLUX.1-dev"
    var steps = 200
    var rank = 16
    var learningRate = 0.0001
    /// Training resolution in pixels; one of `resolutionChoices`. Shown under Advanced.
    var resolution = 512
    /// Sample images during training. Off by default: sample generation is unverified (POD-SPEC 4.2).
    var samplesEnabled = false
    /// Model repos created for results are private unless the user turns this off.
    var privateResult = true
    var runID = ""
    var seed = 42
    var datasetRevision = ""
    var datasetContainsVideo = false
    var runHistory: [TrainingRun] = []
    var selectedHistoryRunID = ""
    var repeatSourceRunID = ""
    var generations: [GeneratedComparison] = []
    var generation: GeneratedComparison?
    var outputRepo = ""
    var triggerWords = "NORA7"
    var profile = "flux-image"
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
    @ObservationIgnored var hubToken = ""
    @ObservationIgnored var imageName = ""
    @ObservationIgnored var saved: SavedPod?
    @ObservationIgnored var lastActivity = Date()
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
        keepAwake: SleepAssertion? = nil
    ) {
        self.demoMode = demoMode
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
        if let networkVolumeID { selectedVolume = networkVolumeID }
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
            outputRepo = previous.outputRepo
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
            async let offers = provider.offers(count: self.gpuCount, minCudaVersion: Self.minimumCUDA(self.trainer))
            async let volumes = provider.volumes()
            self.offers = try await offers
            self.volumes = try await volumes
            if !self.volumes.contains(where: { $0.id == self.selectedVolume }) {
                self.selectedVolume = self.volumes.first?.id ?? ""
            }
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
                  let volume = self.volumes.first(where: { $0.id == self.selectedVolume }),
                  !self.imageName.isEmpty, self.budget.isFinite, self.budget > 0 else {
                throw StudioError
                    .message(
                        "Choose a computer, storage and a positive budget. "
                            + "Add the training image in Settings if it is missing."
                    )
            }
            let started = Date()
            self.agentToken = try Self.newAgentToken()
            let created = try await provider.create(PodCreation(
                name: PodNaming.name(project: self.projectFolder?.lastPathComponent ?? ""),
                offer: offer, count: self.gpuCount,
                image: self.imageName.replacingOccurrences(of: "{trainer}", with: self.trainer),
                minCudaVersion: Self.minimumCUDA(self.trainer), volume: volume,
                agentToken: self.agentToken, hubToken: self.hubToken
            ))
            self.pod = created
            self.plan = nil
            self.storage = nil
            self.runID = ""
            self.trainingState = "Not started"
            self.points = []
            self.logs = ""
            self.elapsedCost = 0
            self.saved = SavedPod(
                pod: created, started: started, hourlyRate: max(created.cost, self.quotedHourlyRate),
                budget: self.budget, trainer: self.trainer, runID: "", outputRepo: self.outputRepo,
                idleMinutes: self.idleMinutes, volumeID: volume.id
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
        var agentAnswered = false
        do {
            try await enforceLimits()
            guard hasRunningPod else { return }
            pod = try await provider.status(id: current.id)
            persist()
            guard hasRunningPod else { return }
            guard let agent else {
                throw StudioError.message("Open Settings to restore this computer’s saved connection.")
            }
            if plan == nil {
                plan = try await agent.plan()
                storage = try? await agent.storageUsage()
            }
            let services = try await agent.services()
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
            if !isBusy, result == resultBefore { try await settleResult(agent, services: services) }
            if !isBusy { try await settleGeneration(agent, services: services) }
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
        // A failed agent/proxy request must not suppress the provider-level idle stop, but a
        // finished LoRA that is neither pushed nor downloaded keeps the computer up, and so does a
        // run the agent still answers for whose result has not been settled yet.
        if hasRunningPod, !isBusy, !resultNeedsSaving, !(agentAnswered && resultUnsettled),
           Date().timeIntervalSince(lastActivity) >= Double(idleMinutes * 60) {
            await stopEverything()
            if !hasRunningPod { message = "Stopped the idle computer to avoid further GPU charges." }
        }
    }

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
            saved.outputRepo = outputRepo
            saved.idleMinutes = idleMinutes
            saved.points = points
            saved.result = result
            saved.run = runHistory.first(where: { $0.runID == runID })
            saved.generation = generation
            self.saved = saved
            if !demoMode, let data = try? JSONEncoder().encode(saved) {
                preferences.set(data, forKey: Self.activePodKey)
            }
        }
    }

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

    func waitForService(_ name: String, allowStopped: Bool = false) async throws {
        guard let agent else { return }
        while true {
            try Task.checkCancellation()
            let service = try await agent.services().first(where: { $0.name == name })
            if let service, !service.active {
                guard service.state == "exited" || (allowStopped && service.state == "stopped") else {
                    throw StudioError
                        .message("\(name) did not finish. Read its logs and retry after correcting the cause.")
                }
                return
            }
            try await Task.sleep(for: .seconds(demoMode ? 0.1 : 2))
        }
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy, !isStopping else { return }
        isBusy = true
        let work = Task {
            defer { self.isBusy = false }
            do {
                try await action()
            } catch is CancellationError {
                self.message = "Action cancelled. Check the computer status before closing."
            } catch { self.message = error.localizedDescription }
        }
        operationTask = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

// MARK: - Cost guards and stopping

extension GPUWorkspace {
    func enforceLimits(now: Date = Date()) async throws {
        guard let saved, hasRunningPod else { return }
        elapsedCost = max(0, now.timeIntervalSince(saved.started)) / 3600 * saved.hourlyRate
        if elapsedCost >= saved.budget {
            let stranded = resultNeedsSaving
            await stopEverything(discardingPendingResult: true)
            if !hasRunningPod {
                message = "Your spending limit was reached. The GPU is stopped."
                    + (stranded ? " Your model and generated files stay on your network storage; rent a computer "
                        + "on the same storage to retrieve them." : "")
            }
        }
    }

    /// The spending limit enforced on the running pod.
    var activeBudget: Double? {
        hasRunningPod ? saved?.budget : nil
    }

    /// Raises the running pod's limit. The caller confirms with the user first; lowering is refused
    /// because it could stop the pod the moment it is applied.
    @discardableResult
    func raiseBudget(to newBudget: Double) -> Bool {
        guard var saved, hasRunningPod, newBudget.isFinite, newBudget > saved.budget else {
            message = "Enter a spending limit above the current one."
            return false
        }
        saved.budget = newBudget
        self.saved = saved
        budget = newBudget
        persist()
        message = "Spending limit raised to \(StudioMoney.format(newBudget))."
        return true
    }

    /// Stops the pod. Refuses, with a message, while a finished LoRA is unsaved unless
    /// `discardingPendingResult` is set (the budget sets it; the run stays on the volume).
    func stopEverything(discardingPendingResult: Bool = false) async {
        guard !isStopping else { return }
        if !discardingPendingResult, resultNeedsSaving {
            message = "Your trained model or generated outputs are not saved yet. Retrieve them first, or stop "
                + "anyway: they stay on your network storage for retrieval from the next computer on that storage."
            return
        }
        isStopping = true
        defer { isStopping = false }
        operationTask?.cancel()
        await operationTask?.value
        guard let provider, let pod else { return }
        do {
            if let current = try? await provider.status(id: pod.id) {
                self.pod = current
                persist()
                if !current.isRunning {
                    message = "RunPod confirms this computer is stopped. Saved storage remains."
                    trainingState = "stopped"
                    return
                }
            }
            // Provider stop also works when the agent is unreachable; it is the final cost control.
            try await provider.stop(id: pod.id)
            for _ in 0 ..< 20 {
                let updated = try await provider.status(id: pod.id)
                self.pod = updated
                persist()
                if !updated.isRunning {
                    message = "Computer stopped. GPU billing has ended; saved storage remains."
                    trainingState = "stopped"
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            message = "Stop was requested, but RunPod has not confirmed it. Keep this window open and retry Stop."
        } catch {
            message = "Could not confirm the computer is stopped. Retry Stop or stop it in your RunPod account."
        }
    }

    func terminate() async {
        await stopEverything()
        guard !hasRunningPod, let provider, let pod else { return }
        await perform {
            try await provider.terminate(id: pod.id)
            self.pod = nil
            self.saved = nil
            self.agent = nil
            if !self.demoMode {
                self.preferences.removeObject(forKey: Self.activePodKey)
                try self.deleteAgentToken("pod.\(pod.id)")
            }
            self.message = "Computer removed. Your separate network storage remains in RunPod."
        }
    }
}

extension GPUWorkspace {
    static let minimumGPUMemoryGB = 32
    nonisolated static let resolutionChoices = [512, 768, 1024]

    /// Host CUDA floor per trainer image, from pod/images/README.md "CUDA and drivers": the
    /// ai-toolkit image carries cu130 wheels and the LTX image cu132 wheels, both needing an R580+
    /// driver, which RunPod reports as CUDA 13.0. The base image alone (vLLM cu129 on CUDA 12.8.1)
    /// would run on 12.x, but the app only rents trainer images.
    nonisolated static let minimumCUDAByTrainer = ["aitoolkit": "13.0", "ltx": "13.0"]

    nonisolated static func minimumCUDA(_ trainer: String) -> String {
        minimumCUDAByTrainer[trainer] ?? "13.0"
    }

    /// 256 random bits from the system CSPRNG, hex encoded: the pod agent's bearer and vLLM key.
    nonisolated static func newAgentToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StudioError.message("Your Mac could not generate a key for the computer. Try again.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func noteActivity() {
        lastActivity = Date()
    }

    var quotedHourlyRate: Double {
        (availableOffers.first(where: { $0.id == selectedGPU })?.price.secure ?? 0) * Double(gpuCount)
    }

    var availableOffers: [GPUOffer] {
        guard let volume = volumes.first(where: { $0.id == selectedVolume }) else { return [] }
        return offers.filter { $0.memory >= Self.minimumGPUMemoryGB && $0.isAvailable(in: volume.dataCenter) }
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
        return pod?.volumeID ?? selectedVolume
    }

    /// Whether the Mac is being kept awake for the running pod.
    var keepsMacAwake: Bool {
        sleepGuard.isHeld
    }
}
