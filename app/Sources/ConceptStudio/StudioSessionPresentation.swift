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

    func providerCredentialsDidChange() {
        providerCredentialRevision &+= 1
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
