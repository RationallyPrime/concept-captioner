import ConceptCore
import Foundation

extension GPUWorkspace {
    func refreshStorage() async {
        await perform {
            guard let agent = self.agent, self.hasRunningPod else {
                throw StudioError.message("Connect a computer to read its workspace storage usage.")
            }
            self.storage = try await agent.storageUsage()
        }
    }

    func cleanupDatasets() async {
        await perform {
            guard let agent = self.agent, self.hasRunningPod else {
                throw StudioError.message("Connect a computer to clean completed dataset copies on its storage.")
            }
            self.message = "Removing eligible completed dataset copies. Models and results are kept."
            try await agent.start("cleanup-datasets", gpus: [], params: [:])
            try await self.waitForService("cleanup-datasets")
            self.storage = try await agent.storageUsage()
            self.message = "Dataset cleanup finished. Active inputs, the last three resumable datasets, "
                + "models and results are kept."
        }
    }
}

extension GPUWorkspace {
    /// A stopped pod disk still holds its outputs, but deletion would destroy them.
    var hasUndeliveredPodOutputs: Bool {
        !undeliveredPodOutputs.isEmpty
    }

    /// The training runs and comparisons on this computer's pod disk that are neither pushed nor saved.
    var undeliveredPodOutputs: [String] {
        guard currentVolumeID.hasPrefix("pod:") else { return [] }
        let pending: (TrainingResult) -> Bool = {
            $0.volumeID == self.currentVolumeID && [.training, .pending].contains($0.state)
        }
        let pendingComparison: (GeneratedComparison) -> Bool = {
            $0.volumeID == self.currentVolumeID && [.generating, .pending].contains($0.state)
        }
        let runs = ([result].compactMap(\.self).filter(pending).map(\.runID)
            + runHistory.filter { $0.localSavedFolder == nil && $0.result.map(pending) == true }.map(\.runID))
            .map { "training run \($0)" }
        let comparisons = ([generation].compactMap(\.self) + generations).filter(pendingComparison)
            .map { "comparison \($0.runID)" }
        var seen: Set<String> = []
        return (runs + comparisons).filter { seen.insert($0).inserted }
    }

    /// RunPod keeps billing a stopped pod's disk. Its API reports no storage price, so this is an
    /// estimate at RunPod's published stopped-pod volume rate of $0.20 per GB per month.
    nonisolated static let stoppedPodDiskUSDPerGBMonth = 0.20

    /// What keeping this stopped computer's pod disk costs, stated as an estimate.
    var stoppedPodDiskCostExplanation: String {
        let monthly = Double(RunPodProvider.podDiskGB) * Self.stoppedPodDiskUSDPerGBMonth
        return "While stopped, its \(RunPodProvider.podDiskGB) GB pod disk costs about "
            + "\(StudioMoney.format(monthly)) a month (estimated)."
    }

    /// RunPod's refusal to start a stopped pod whose host machine has no GPU free for it.
    nonisolated static func hostHasNoFreeGPU(_ error: any Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return ["not enough free gpu", "no free gpu", "no longer any instances available", "not enough gpus"]
            .contains { text.contains($0) }
    }

    /// What removing this computer to rent another would cost on its disk.
    var removalLossExplanation: String {
        guard currentVolumeID.hasPrefix("pod:") else {
            return "Its files are on network storage, which stays; rent the new computer on that storage."
        }
        let lost = undeliveredPodOutputs
        return "Removing it deletes its pod disk: the uploaded dataset copies, downloaded models and checkpoints"
            + (lost.isEmpty ? "." : ", including " + lost.joined(separator: ", ") + ", which were never saved.")
    }

    var outputCustodyExplanation: String {
        currentVolumeID.hasPrefix("pod:")
            ? "Your files stay on this computer's pod disk while stopped. Start this same computer to retrieve "
            + "them; removing it deletes that disk. Storage charges continue while stopped."
            : "Your files stay on network storage. Rent a computer on the same storage to retrieve them."
    }

    func freezePodCost() {
        guard hasRunningPod, var saved else { return }
        saved.accruedGPUCostUSD = estimatedPodCost
        saved.started = Date()
        self.saved = saved
        elapsedCost = saved.accruedGPUCostUSD
    }

    func updateHourlyRate(_ pod: RentedPod) {
        guard pod.isRunning, pod.cost > 0 else { return }
        saved?.hourlyRate = pod.cost
    }

    func startStoppedComputer() async {
        await perform {
            guard let provider = self.provider, let pod = self.pod, !pod.isRunning,
                  var saved = self.saved else {
                throw StudioError.message("Choose the stopped computer before starting it.")
            }
            guard self.budget.isFinite, self.budget > saved.accruedGPUCostUSD else {
                throw StudioError.message("Set a whole-computer budget above its GPU cost so far before starting it.")
            }
            do {
                try await provider.start(id: pod.id)
            } catch {
                guard Self.hostHasNoFreeGPU(error) else { throw error }
                self.restartBlockedByHost = true
                throw StudioError.message("This computer's host has no free GPU, so it cannot start now. "
                    + "Try again later, or remove it and rent a new one.")
            }
            self.restartBlockedByHost = false
            saved.started = Date()
            saved.budget = self.budget
            self.saved = saved
            self.pod = RentedPod(
                id: pod.id,
                status: "STARTING",
                cost: saved.hourlyRate,
                gpu: pod.gpu,
                name: pod.name,
                mounts: pod.mounts
            )
            self.persist()
            self.watch()
            let current = try await provider.status(id: pod.id)
            self.updateHourlyRate(current)
            self.pod = current
            self.connectAgent(current)
            self.lastActivity = Date()
            self.persist()
            self.watch()
            self.message = "Computer start requested. GPU billing resumes; its original workspace files are kept."
        }
    }
}
