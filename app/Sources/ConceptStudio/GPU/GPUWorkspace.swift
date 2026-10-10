import ConceptCore
import Foundation
import Observation

struct SavedPod: Codable {
    var pod: RentedPod
    let started: Date
    let hourlyRate: Double
    let budget: Double
    var trainer: String
    var runID: String
    var outputRepo: String
}

@MainActor @Observable
final class GPUWorkspace {
    let demoMode: Bool
    var offers: [GPUOffer] = []
    var volumes: [GPUVolume] = []
    var selectedGPU = ""
    var selectedVolume = ""
    var gpuCount = 1
    var budget = 10.0
    var idleMinutes = 15
    var pod: RentedPod?
    var plan: TrainingPlan?
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
    var runID = ""
    var outputRepo = ""
    var triggerWords = "NORA7"
    var profile = "flux-image"
    var keepCaptionServer = false
    var captionModel = "Qwen/Qwen3-VL-8B-Instruct"
    var points: [TrainingPoint] = []
    var logs = ""
    var trainingState = "Not started"
    private(set) var agentToken = ""

    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let saveAgentToken: (String, String) throws -> Void
    @ObservationIgnored private let readAgentToken: (String) throws -> String?
    @ObservationIgnored private var provider: (any GPUProvider)?
    @ObservationIgnored private var agent: (any PodAgent)?
    @ObservationIgnored private var hubToken = ""
    @ObservationIgnored private var imageName = ""
    @ObservationIgnored private var saved: SavedPod?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        demoMode: Bool,
        transport: any HTTPTransport = URLSessionTransport(timeout: 45),
        preferences: UserDefaults = .standard,
        readAgentToken: @escaping (String) throws -> String? = { try KeychainStore().read($0) },
        saveAgentToken: @escaping (String, String) throws -> Void = { token, account in
            try KeychainStore().save(token, account: account)
        }
    ) {
        self.demoMode = demoMode
        self.transport = transport
        self.preferences = preferences
        self.saveAgentToken = saveAgentToken
        self.readAgentToken = readAgentToken
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
        if pod == nil, let data = preferences.data(forKey: "ConceptStudio.activePod"),
           let previous = try? JSONDecoder().decode(SavedPod.self, from: data) {
            saved = previous
            pod = previous.pod
            budget = previous.budget
            trainer = previous.trainer
            runID = previous.runID
            outputRepo = previous.outputRepo
            watch()
        }
        if let pod, agent == nil {
            agentToken = try readAgentToken("pod.\(pod.id)") ?? ""
            connectAgent(pod)
        }
    }

    func refreshOffers() async {
        await perform {
            guard let provider = self.provider else {
                throw StudioError.message("Add your RunPod key in Settings, then refresh available computers.")
            }
            async let offers = provider.offers(count: self.gpuCount)
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
            self.agentToken = UUID().uuidString + UUID().uuidString
            let created = try await provider.create(PodCreation(
                offer: offer, count: self.gpuCount,
                image: self.imageName.replacingOccurrences(of: "{trainer}", with: self.trainer), volume: volume,
                agentToken: self.agentToken, hubToken: self.hubToken
            ))
            self.pod = created
            self.plan = nil
            self.runID = ""
            self.trainingState = "Not started"
            self.points = []
            self.logs = ""
            self.elapsedCost = 0
            self.saved = SavedPod(
                pod: created,
                started: started,
                hourlyRate: max(created.cost, self.quotedHourlyRate),
                budget: self.budget,
                trainer: self.trainer, runID: "", outputRepo: self.outputRepo
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
            self.message = "Your computer is starting. Its cost is visible below; you can stop it at any time."
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
        do {
            try await enforceLimits()
            guard hasRunningPod else { return }
            pod = try await provider.status(id: current.id)
            persist()
            guard hasRunningPod else { return }
            guard let agent else {
                throw StudioError.message("Open Settings to restore this computer’s saved connection.")
            }
            if plan == nil { plan = try await agent.plan() }
            let services = try await agent.services()
            let active = services.contains { $0.active && !["tensorboard", "vllm"].contains($0.name) }
            if active { lastActivity = Date() }
            if let state = services.first(where: { $0.name.hasPrefix("trainer-") && $0.active })
                ?? services.first(where: { $0.name == "trainer-\(trainer)" }) {
                if state.active { trainer = String(state.name.dropFirst("trainer-".count)) }
                if let id = state.runID { runID = id }
                trainingState = state.state
                if !runID.isEmpty {
                    if let point = try await agent.latest(runID: runID),
                       !points.contains(where: { $0.step == point.step }) {
                        points.append(point)
                    }
                    logs = try await agent.logs("trainer-\(trainer)")
                }
            }
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
        // A failed agent/proxy request must not suppress the provider-level idle stop.
        if hasRunningPod, !isBusy, Date().timeIntervalSince(lastActivity) >= Double(idleMinutes * 60) {
            await stopEverything()
            if !hasRunningPod { message = "Stopped the idle computer to avoid further GPU charges." }
        }
    }

    func enforceLimits(now: Date = Date()) async throws {
        guard let saved, hasRunningPod else { return }
        elapsedCost = max(0, now.timeIntervalSince(saved.started)) / 3600 * saved.hourlyRate
        if elapsedCost >= saved.budget {
            await stopEverything()
            if !hasRunningPod { message = "Your spending limit was reached. The GPU is stopped." }
        }
    }

    func noteActivity() {
        lastActivity = Date()
    }

    func train(datasetRepo: String) async {
        await perform {
            guard let agent = self.agent, self.hasRunningPod else {
                throw StudioError.message("Rent a training computer first, then return here.")
            }
            guard !datasetRepo.isEmpty, self.steps > 0, self.rank > 0, !self.baseModel.isEmpty else {
                throw StudioError
                    .message("Publish your dataset first and choose a model with positive training steps and rank.")
            }
            let servicesBeforeStart = try await agent.services()
            guard !servicesBeforeStart.contains(where: { $0.name.hasPrefix("trainer-") && $0.active }) else {
                throw StudioError.message("A training run is active. Stop it before starting another.")
            }
            let plan = try await agent.plan()
            self.plan = plan
            let dataset = "conceptstudio"
            try await agent.start("pull-dataset", gpus: [], params: [
                "repo_id": .string(datasetRepo), "name": .string(dataset),
            ])
            self.message = "Downloading your published photos and captions."
            try await self.waitForService("pull-dataset")
            if plan.mode == "sequential" {
                let services = try await agent.services()
                if services.contains(where: { $0.name == "vllm" && $0.active }) {
                    try await agent.stop("vllm")
                    try await self.waitForService("vllm", allowStopped: true)
                }
            } else if self.keepCaptionServer {
                let services = try await agent.services()
                if !services.contains(where: { $0.name == "vllm" && $0.active }) {
                    try await agent.start("vllm", gpus: plan.caption?.gpus ?? [], params: self.captionStartParams)
                }
            }
            self.runID = "concept-" + UUID().uuidString.prefix(12).lowercased()
            self.points = []
            let words = self.triggerWords.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            var params: JSONObject = [
                "run_id": .string(self.runID),
                "dataset": .object(["path": .string("/workspace/datasets/\(dataset)")]),
                "triggers": .array(words.map(JSONValue.string)), "profile": .string(self.profile),
                "base_model": .string(self.baseModel), "steps": .int(self.steps), "rank": .int(self.rank),
                "learning_rate": .double(self.learningRate), "resolution": .int(512),
                "save_every": .int(min(250, self.steps)), "sample_every": .int(0),
            ]
            if !self.outputRepo.isEmpty {
                params["hub"] = .object([
                    "repo_id": .string(self.outputRepo),
                    "private": .bool(true),
                    "push_on_finish": .bool(false),
                ])
            }
            try await agent.start("trainer-\(self.trainer)", gpus: plan.train?.gpus ?? [], params: params)
            self.persist()
            let services = try await agent.services()
            if !services.contains(where: { $0.name == "tensorboard" && $0.active }) {
                try await agent.start("tensorboard", gpus: [], params: ["logdir": .string("/workspace/runs")])
            }
            self.trainingState = "running"
            self.lastActivity = Date()
            self.message = "Training started. Open Monitor to watch progress."
        }
    }

    func publishResult() async {
        await perform {
            guard let agent = self.agent, !self.outputRepo.isEmpty, !self.runID.isEmpty else {
                throw StudioError.message("Enter a destination model repository and finish a training run first.")
            }
            try await agent.start("push-lora", gpus: [], params: [
                "run_id": .string(self.runID), "repo_id": .string(self.outputRepo), "private": .bool(true),
            ])
            try await self.waitForService("push-lora")
            self.message = "Your LoRA was uploaded to your model repository. You can now stop the computer."
        }
    }

    func stopEverything() async {
        guard !isStopping else { return }
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
            if !self.demoMode {
                self.preferences.removeObject(forKey: "ConceptStudio.activePod")
                try self.saveAgentToken("", "pod.\(pod.id)")
            }
            self.message = "Computer removed. Your separate network storage remains in RunPod."
        }
    }

    private func connectAgent(_ pod: RentedPod) {
        agent = demoMode ? DemoPodAgent(count: pod.gpu.count)
            : PodAgentClient(baseURL: pod.agentURL, token: agentToken, transport: transport)
    }

    private func persist() {
        guard !demoMode, var saved, let pod else { return }
        saved.pod = pod
        saved.trainer = trainer
        saved.runID = runID
        saved.outputRepo = outputRepo
        self.saved = saved
        if let data = try? JSONEncoder().encode(saved) {
            preferences.set(data, forKey: "ConceptStudio.activePod")
        }
    }

    private func watch() {
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

    private func waitForService(_ name: String, allowStopped: Bool = false) async throws {
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

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
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

extension GPUWorkspace {
    var quotedHourlyRate: Double {
        (availableOffers.first(where: { $0.id == selectedGPU })?.price.secure ?? 0) * Double(gpuCount)
    }

    var availableOffers: [GPUOffer] {
        guard let volume = volumes.first(where: { $0.id == selectedVolume }) else { return [] }
        return offers.filter { $0.isAvailable(in: volume.dataCenter) }
    }

    func selectAvailableOffer() {
        if !availableOffers.contains(where: { $0.id == selectedGPU }) {
            selectedGPU = availableOffers.first?.id ?? ""
        }
    }

    var tensorBoardURL: URL? {
        pod?.agentURL.appendingPathComponent("tensorboard/")
    }

    var hasRunningPod: Bool {
        pod?.isRunning == true
    }

    var isTraining: Bool {
        ["running", "stuck"].contains(trainingState)
    }

    var captionEndpoint: URL? {
        guard let pod, pod.isRunning else { return nil }
        return URL(string: "https://\(pod.id)-8000.proxy.runpod.net/v1")
    }

    private var captionStartParams: JSONObject {
        [
            "model": .string(captionModel), "max_model_len": .int(16384), "max_num_seqs": .int(2),
            "gpu_memory_utilization": .double(0.85),
            "extra_args": .array([.string("--enforce-eager"), .string("--max-num-batched-tokens=4096")]),
        ]
    }

    func startCaptioning() async -> Bool {
        var ready = false
        await perform {
            guard let agent = self.agent, self.hasRunningPod else {
                throw StudioError.message("Rent a computer before starting its caption model.")
            }
            let plan = try await agent.plan()
            self.plan = plan
            let services = try await agent.services()
            if plan.mode == "sequential",
               services.contains(where: { $0.name.hasPrefix("trainer-") && $0.active }) {
                throw StudioError.message("Finish training before captioning on this single-GPU computer.")
            }
            if !services.contains(where: { $0.name == "vllm" && $0.active }) {
                try await agent.start("vllm", gpus: plan.caption?.gpus ?? [], params: self.captionStartParams)
            }
            self.lastActivity = Date()
            self.message = "The caption model is starting. Large models can take several minutes to download."
            if !self.demoMode {
                try await self.waitForCaptionModel()
            }
            ready = true
            self.message = "The caption model is ready. You can now caption with this computer."
        }
        return ready
    }

    private func waitForCaptionModel() async throws {
        guard let endpoint = captionEndpoint else {
            throw StudioError.message("Your captioning computer is stopped. Rent or start one first.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(600))
        while clock.now < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint.appendingPathComponent("models"), timeoutInterval: 15)
            request.setValue("Bearer \(agentToken)", forHTTPHeaderField: "Authorization")
            do {
                let response = try await transport.send(request)
                if response.status == 200,
                   let models = try JSONValue(parsing: response.body).objectValue?["data"]?.arrayValue,
                   models.contains(where: { $0.objectValue?["id"]?.stringValue == captionModel }) {
                    return
                }
                if [401, 403].contains(response.status) {
                    throw StudioError.message("This computer rejected its captioning key. Stop it and rent a new one.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as StudioError {
                throw error
            } catch {
                // The inference server may not yet be listening while model weights download.
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw StudioError
            .message("The caption model is still not ready. Check the computer’s logs or stop it before retrying.")
    }
}
