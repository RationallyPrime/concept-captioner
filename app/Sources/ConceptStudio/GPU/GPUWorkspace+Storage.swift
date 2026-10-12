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
        guard currentVolumeID.hasPrefix("pod:") else { return false }
        let pending: (TrainingResult) -> Bool = {
            $0.volumeID == self.currentVolumeID && [.training, .pending].contains($0.state)
        }
        return result.map(pending) == true || runHistory
            .contains { $0.localSavedFolder == nil && $0.result.map(pending) == true }
            || generation.map { $0.volumeID == currentVolumeID && [.generating, .pending].contains($0.state) } == true
            || generations.contains { $0.volumeID == currentVolumeID && [.generating, .pending].contains($0.state) }
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
            try await provider.start(id: pod.id)
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
