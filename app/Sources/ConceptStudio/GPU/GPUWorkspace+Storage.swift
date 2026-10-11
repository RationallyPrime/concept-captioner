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
