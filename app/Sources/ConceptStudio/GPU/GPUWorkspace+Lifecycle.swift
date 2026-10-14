import ConceptCore
import Foundation

// MARK: - Cost guards and stopping

extension GPUWorkspace {
    func enforceLimits(now: Date = Date()) async throws {
        guard let saved, hasRunningPod else { return }
        elapsedCost = saved.accruedGPUCostUSD + max(0, now.timeIntervalSince(saved.started)) / 3600 * saved.hourlyRate
        let exceededRun = activeBudgetedRun.flatMap { run in
            run.gpuBudgetUSD.map { currentRunCost(run, podCost: elapsedCost) >= $0 }
        } == true
        if elapsedCost >= saved.budget || exceededRun {
            let stranded = resultNeedsSaving || resultUnsettled
            await stopEverything(discardingPendingResult: true)
            if !hasRunningPod {
                message = (exceededRun ? "This training run's budget was reached."
                    : "Your computer's spending limit was reached.") + " The GPU is stopped."
                    + (stranded ? " " + outputCustodyExplanation : "")
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
                + "anyway. " + outputCustodyExplanation
            return
        }
        isStopping = true
        defer { isStopping = false }
        operationTask?.cancel()
        await operationTask?.value
        guard let provider, let pod else { return }
        do {
            if let current = try? await provider.status(id: pod.id) {
                if !current.isRunning { freezePodCost() }
                self.pod = current
                persist()
                if !current.isRunning {
                    message = "RunPod confirms this computer is stopped. "
                        + "Workspace files remain; storage charges continue."
                    trainingState = "stopped"
                    return
                }
            }
            // Provider stop also works when the agent is unreachable; it is the final cost control.
            try await provider.stop(id: pod.id)
            for _ in 0 ..< 20 {
                let updated = try await provider.status(id: pod.id)
                if !updated.isRunning { freezePodCost() }
                self.pod = updated
                persist()
                if !updated.isRunning {
                    message = "Computer stopped. GPU billing has ended; "
                        + "workspace files remain and storage charges continue."
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

    /// Drops every local trace of `pod`: the record, its agent token and its agent secret.
    private func forgetPod(_ pod: RentedPod) async {
        let agentSecret = saved?.agentSecret ?? ""
        self.pod = nil
        saved = nil
        agent = nil
        if !demoMode {
            preferences.removeObject(forKey: Self.activePodKey)
            try? deleteAgentToken("pod.\(pod.id)")
        }
        // A secret left behind is harmless once the pod is gone; launch pruning removes it.
        if !agentSecret.isEmpty, let provider { try? await provider.deleteSecret(name: agentSecret) }
    }

    /// Removes the computer. Outputs only on its pod disk block removal unless the user has confirmed
    /// `discardingUndeliveredOutputs`, which deletes them with the disk.
    func terminate(discardingUndeliveredOutputs: Bool = false) async {
        let lost = undeliveredPodOutputs
        // A pod removed outside the app (RunPod console, another tool) cannot be stopped or deleted here, and
        // the stale record would keep Rent disabled. A 404 under the current key is not proof of deletion: the
        // key may belong to another account now, so the message says where it may still be.
        if !demoMode, let provider, let pod, await (try? provider.exists(id: pod.id)) == false {
            await forgetPod(pod)
            message = "RunPod has no computer \(pod.id) under the current key, so this app no longer tracks it"
                + (lost.isEmpty ? "" : " (with " + lost.joined(separator: ", ") + ")")
                + ". If you changed RunPod accounts, it may still exist, and bill storage, in the other account."
            return
        }
        guard lost.isEmpty || discardingUndeliveredOutputs else {
            message = "This computer holds outputs that have not been pushed or saved. "
                + "Start this same computer and retrieve them before removing it. " + stoppedPodDiskCostExplanation
            failure = message
            return
        }
        await stopEverything(discardingPendingResult: discardingUndeliveredOutputs)
        guard !hasRunningPod, let provider, let pod else { return }
        await perform {
            try await provider.terminate(id: pod.id)
            await self.forgetPod(pod)
            self.message = lost.isEmpty
                ? "Computer removed. Its pod disk was deleted; separate network storage remains in RunPod."
                : "Computer removed. Its pod disk was deleted with "
                + lost.joined(separator: ", ") + "; separate network storage remains in RunPod."
        }
    }
}
