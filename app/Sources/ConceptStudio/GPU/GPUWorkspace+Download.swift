import Foundation

extension GPUWorkspace {
    /// Downloads one project-owned finished run; the current run and Hub status stay independent.
    func downloadRun(_ selected: TrainingRun) async {
        await perform {
            guard !self.demoMode else {
                throw StudioError.message("The demo has no trained weights. Save a model from a real training run.")
            }
            guard let project = self.projectFolder,
                  let index = self.runHistory.firstIndex(where: { $0.runID == selected.runID }) else {
                throw StudioError.message("Open this training run's original project before saving its model.")
            }
            let run = self.runHistory[index]
            guard run.hasFinishedModel else {
                throw StudioError.message("Finish this training run before saving its trained model.")
            }
            guard let agent = self.agent, self.hasRunningPod, !run.volumeID.isEmpty,
                  run.volumeID == self.currentVolumeID else {
                throw StudioError.message("Connect a computer to this run's saved storage, then save its model.")
            }
            let files = try await RunArtifacts.selection(agent.runFiles(runID: run.runID))
            guard !files.isEmpty else {
                throw StudioError.message("No trained model was found for run \(run.runID).")
            }
            let folder = try self.resultsFolder(for: run.runID)
            for file in files {
                try Task.checkCancellation()
                self.message = "Saving \(file.path) to this Mac…"
                try await self.download(file, runID: run.runID, into: folder, agent: agent)
            }
            try Task.checkCancellation()
            guard self.projectFolder == project,
                  let current = self.runHistory.firstIndex(where: { $0.runID == run.runID }) else {
                throw StudioError.message("Open this run's original project to record its saved model.")
            }
            let previousFolder = self.runHistory[current].localFolder
            self.runHistory[current].localFolder = folder.path
            guard self.saveProjectRecord() else {
                self.runHistory[current].localFolder = previousFolder
                throw StudioError.message(self.message)
            }
            self.message = "The selected run's trained model is saved to \(folder.path)."
        }
    }
}
