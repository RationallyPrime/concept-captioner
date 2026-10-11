import ConceptCore
import Foundation

extension StudioSession {
    /// Holds both existing project work slots only while the immutable input files are copied.
    /// The GPU operation continues after these slots settle, so captioning can run during training.
    func captureTrainingInputs() async throws -> LocalTrainingDataset {
        guard !busy, !editing, let folder = project?.directory else {
            throw StudioError
                .message("Finish the current project edit or caption run before preparing training inputs.")
        }
        var captured: LocalTrainingDataset?
        let started = perform("Capturing saved training inputs…") {
            guard !self.editing else { throw StudioError.message("A caption edit is still being saved. Try again.") }
            self.editing = true
            self.editTitle = "Capturing saved training inputs"
            defer { self.editing = false }
            captured = try await LocalTrainingDataset.prepare(projectFolder: folder)
        }
        guard started, let work = task else { throw StudioError.message("Training input capture could not start.") }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
        if Task.isCancelled {
            captured?.remove()
            throw CancellationError()
        }
        guard let captured else { throw StudioError.message(errorMessage ?? "Training inputs could not be captured.") }
        return captured
    }

    func preparePublishing() {
        guard !demoMode else { return }
        do { gpu.hubToken = try keyStore.read("huggingface") ?? "" } catch { errorMessage = Self.describe(error) }
    }

    func publish() {
        perform("Preparing your training dataset…") {
            guard let project = self.project, !project.images.isEmpty else {
                throw StudioError.message("Import images or clips before publishing your dataset.")
            }
            try project.save()
            if self.demoMode {
                let operations = try await ProjectPublisher.operations(for: project)
                for index in operations.indices {
                    try await Task.sleep(for: .milliseconds(50))
                    self.completed = index + 1
                }
                self.message = "Demo dataset prepared: photos, captions, response records and job file. "
                    + "No upload or money spent."
            } else if self.gpu.usesLocalDataset {
                let snapshot = try await LocalTrainingDataset.prepare(projectFolder: project.directory)
                defer { snapshot.remove() }
                self.completed = snapshot.files.count
                self.message = "Training data checked. No Hugging Face account is needed. "
                    + "Start training to upload these included targets directly to your rented computer."
            } else {
                let client = try HubClient(token: self.keyStore.read("huggingface"))
                guard client.token?.isEmpty == false else {
                    throw StudioError.message("Save your Hugging Face write token in Settings before publishing.")
                }
                let repo = try RepoID(self.repoID)
                try await client.createRepo(repo, private: self.privateDataset)
                let remotePaths = try await Set(client.listFiles(repo: repo).map(\.path))
                let previousRows = try await remotePaths.contains(ImageFolderMetadata.fileName)
                    ? ImageFolderMetadata.parse(client.download(repo: repo, path: ImageFolderMetadata.fileName)) : []
                let operations = try await ProjectPublisher.operations(
                    for: project, previousRows: previousRows, remotePaths: remotePaths
                )
                let commit = try await client.commit(
                    repo: repo,
                    operations: operations,
                    message: "Publish ConceptStudio project"
                ) { progress in
                    Task { @MainActor in self.message = "\(progress.phase.rawValue): \(progress.path ?? "dataset")" }
                }
                self.message = "Dataset published. " + commit.commitURL
                self.gpu.datasetRevision = commit.commitOID
                self.updateProjectState { $0.datasetRevision = commit.commitOID }
            }
            self.rememberChoices()
        }
    }
}
