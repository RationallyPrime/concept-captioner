import Foundation

@MainActor
extension StudioSession {
    func connectOpenRouter() async {
        guard !demoMode, !busy else { return }
        let generation = chatGPTWorkGeneration
        guard await openRouter.connect() else { return }
        guard generation == chatGPTWorkGeneration, !demoMode, !busy, !Task.isCancelled else { return }
        let changedProvider = endpointKind != "openrouter"
        endpointKind = "openrouter"
        if changedProvider || modelName.isEmpty { modelName = ProviderChoices.defaultModel(for: "openrouter") }
        usingPodCaptioner = false
        rememberChoices()
        await openRouter.refresh()
        guard generation == chatGPTWorkGeneration, !demoMode, !busy, !Task.isCancelled else { return }
        _ = try? await refreshProviderModels(for: "openrouter")
        guard generation == chatGPTWorkGeneration, !demoMode, !busy, !Task.isCancelled else { return }
        message = openRouter.errorMessage == nil ? "OpenRouter connected. Select a captioning model in Captions." : ""
    }
}
