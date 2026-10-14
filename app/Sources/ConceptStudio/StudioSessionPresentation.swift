import AppKit
import ConceptCore

struct ProviderModelCacheKey: Equatable, Hashable, Sendable {
    let kind: String
    let targetURL: String?
    let usesPodCaptioner: Bool
    let configuredBaseURL: String?
}

extension StudioSession {
    // MARK: Project-only destinations

    /// The dataset repository Publish writes to; remembered per project, blank for a new project.
    var repoID: String {
        get { projectState.dataset.repo }
        set {
            updateProjectState {
                if $0.dataset.repo != newValue { $0.datasetRevision = "" }
                $0.dataset.repo = newValue
            }
        }
    }

    var privateDataset: Bool {
        get { projectState.dataset.isPrivate }
        set { updateProjectState { $0.dataset.isPrivate = newValue } }
    }

    /// Where training uploads the LoRA; remembered per project like the dataset destination.
    var trainingOutputRepo: String {
        get { projectState.trainingOutput.repo }
        set { updateProjectState { $0.trainingOutput.repo = newValue } }
    }

    var trainingOutputPrivate: Bool {
        get { projectState.trainingOutput.isPrivate }
        set { updateProjectState { $0.trainingOutput.isPrivate = newValue } }
    }

    /// Gives a project with no training destination its own default, `<account>/<project>-lora`, when
    /// signed in to Hugging Face. Without an account it stays empty and the result is saved to the project.
    func fillDefaultTrainingOutput() async {
        guard trainingOutputRepo.isEmpty, let directory = project?.directory,
              let suggested = await gpu.suggestedOutputRepo() else { return }
        // The open project, or its destination, may have changed while the account was read.
        guard project?.directory == directory, trainingOutputRepo.isEmpty else { return }
        trainingOutputRepo = suggested
    }

    /// What is still to do before this project can train, in order, each with the step that does it. A dataset
    /// counts as published once this project has recorded a publish. Shown before renting: a rented computer
    /// bills while it waits for these.
    var trainingPrerequisites: [TrainingPrerequisite] {
        guard let project else { return [TrainingPrerequisite(missing: "open a project", step: .images)] }
        var missing: [TrainingPrerequisite] = []
        // Training reads a published dataset (this project's recorded publish, or the one a Repeat recorded)
        // rather than local media. An epoch-counted model still needs an item count: a Repeat that recorded one
        // supplies it, otherwise it comes from the media included here.
        let repeatsPublishedDataset = gpu.publishedRepeatRun != nil
        let projectPublished = !gpu.usesLocalDataset && !repoID.isEmpty && !projectState.datasetRevision.isEmpty
        let countsSteps = gpu.effectiveModelRow.recipe.lengthUnit == .steps
        let publishedMediaSuffices = gpu.publishedRepeatRun.map { $0.itemCount != nil || countsSteps }
            ?? (projectPublished && countsSteps)
        if project.images.isEmpty, !publishedMediaSuffices {
            missing.append(.init(missing: "import images or clips", step: .images))
        }
        if project.job.concepts.isEmpty {
            missing.append(.init(missing: "define a concept and its trigger", step: .concepts))
        }
        // Direct upload sends the saved captions and refuses an included item without one.
        if gpu.usesLocalDataset, project.images.contains(where: \.caption.isBlank) {
            missing.append(.init(missing: "caption every included image or clip", step: .captioning))
        }
        if !gpu.usesLocalDataset, !repeatsPublishedDataset, !projectPublished {
            missing.append(.init(missing: "publish the training dataset", step: .publish))
        }
        return missing
    }

    /// Change the project's app-only settings and save them with the project (not in demo mode).
    func updateProjectState(_ change: (inout ProjectAppState) -> Void) {
        var state = projectState
        change(&state)
        guard state != projectState else { return }
        projectState = state
        guard let project, !demoMode else { return }
        do { try state.save(to: project.directory) } catch { errorMessage = Self.describe(error) }
    }

    // MARK: View state derived from the open project

    var unmappedCount: Int {
        project?.job.unmapped(project?.images.map(\.id) ?? []).count ?? 0
    }

    var keyStore: SessionKeyStore {
        SessionKeyStore(secrets: secrets, vllmBaseURL: customBaseURL.isEmpty ? nil : customBaseURL)
    }

    /// Called when the Hugging Face key changes; the GPU workspace's copy follows wherever the user is.
    func providerCredentialsDidChange() {
        providerCredentialRevision &+= 1
        preparePublishing()
    }

    func providerModelCacheKey(for kind: String) -> ProviderModelCacheKey {
        let usesPod = kind == "vllm" && usingPodCaptioner
        return ProviderModelCacheKey(
            kind: kind,
            targetURL: kind == "vllm" ? vllmTargetURL : nil,
            usesPodCaptioner: usesPod,
            configuredBaseURL: kind == "vllm"
                ? (usesPod ? gpu.captionEndpoint?.absoluteString : customBaseURL.isEmpty ? nil : customBaseURL)
                : nil
        )
    }

    func clearProviderModelChoices(for kind: String) {
        providerModelChoices = providerModelChoices.filter { $0.key.kind != kind }
    }

    var validMappingSuggestionIDs: [String] {
        guard let project else { return [] }
        let locatorTriggers = Set(project.job.concepts.filter(\.targetConcept.requiresLocator).map(\.trigger))
        return project.images.compactMap { image in
            guard project.job.mapping(for: image.id) == nil,
                  let proposal = mappingProposals[image.id], !proposal.isEmpty,
                  Set(proposal.keys).isSubset(of: locatorTriggers),
                  !proposal.values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            return image.id
        }
    }

    var canUndoMappingChange: Bool {
        !mappingUndo.isEmpty
    }
}

struct TrainingPrerequisite: Equatable {
    /// Completes "Before training, …".
    let missing: String
    let step: StudioStep
}
