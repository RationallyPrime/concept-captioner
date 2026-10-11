import ConceptCore
import Foundation

@MainActor
extension StudioSession {
    static let chatGPTUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    var usesChatGPTForThisRun: Bool {
        openAIUsesChatGPT && (endpointKind == "openai" || (useCritic && criticKind == "openai"))
    }

    var chatGPTReady: Bool {
        guard let account = chatGPT.selectedAccount else { return false }
        return account.isSignedIn && account.hasPlanPermission && !chatGPT.isBusy
    }

    var chatGPTConfigurationIssue: String? {
        guard usesChatGPTForThisRun, !demoMode else { return nil }
        do {
            if endpointKind == "openai" {
                try ChatGPTModelClient.validate(
                    settings: RequestSettings(
                        settings: project?.job.endpoints?.captioner.settings ?? [:], thinking: modelThinking
                    ), outputMode: outputMode
                )
            }
            if useCritic, criticKind == "openai" {
                try ChatGPTModelClient.validate(
                    settings: RequestSettings(
                        settings: project?.job.endpoints?.critic?.settings ?? [:], thinking: criticThinking
                    ), outputMode: outputMode
                )
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func useDefaultChatGPTSettings() {
        guard !busy, !demoMode else { return }
        if endpointKind == "openai" { project?.job.endpoints?.captioner.settings = [:] }
        if useCritic, criticKind == "openai" { project?.job.endpoints?.critic?.settings = [:] }
        outputMode = .native
        do {
            let job = try jobForCaptioning()
            project?.job = job
            saveProject()
        } catch { errorMessage = Self.describe(error) }
    }

    func connectChatGPT(accountID: String? = nil) async {
        guard !demoMode, !busy else { return }
        let generation = chatGPTWorkGeneration
        let account = chatGPT.accounts.first { $0.id == accountID }
        let enablePlan = account?.isSignedIn == true && account?.hasPlanPermission == false
        guard await chatGPT.signIn(accountID: accountID, enablePlanUsage: enablePlan) else { return }
        guard generation == chatGPTWorkGeneration, !demoMode, !busy, !Task.isCancelled,
              chatGPT.errorMessage == nil, chatGPT.selectedAccount?.hasPlanPermission == true,
              chatGPT.selectedAccount?.isSignedIn == true else { return }
        openAIUsesChatGPT = true
        endpointKind = "openai"
        await chatGPT.refreshModels()
        guard generation == chatGPTWorkGeneration, !demoMode, !busy, !Task.isCancelled else { return }
        if !chatGPT.availableModels.contains(where: { $0.slug == modelName }) {
            modelName = chatGPT.availableModels.first?.slug ?? ""
        }
        rememberChoices()
        showChatGPTPlanNotice = !preferences.bool(forKey: "chatGPTUsageAcknowledged")
    }

    func acknowledgeChatGPTPlan() {
        preferences.set(true, forKey: "chatGPTUsageAcknowledged")
        showChatGPTPlanNotice = false
    }

    func stopForChatGPTUsageLimit(_ error: ChatGPTInferenceError) {
        chatGPTUsageLimitReached = true
        errorMessage = error.localizedDescription
        cancel()
    }

    func prepareChatGPTModels(duringConnectionTest: Bool = false) async {
        guard !demoMode, !busy || duringConnectionTest, !Task.isCancelled, usesChatGPTForThisRun else { return }
        let generation = chatGPTWorkGeneration
        await chatGPT.load()
        guard generation == chatGPTWorkGeneration, !demoMode, !busy || duringConnectionTest,
              !Task.isCancelled, usesChatGPTForThisRun else { return }
        if chatGPTReady, chatGPT.availableModels.isEmpty {
            await chatGPT.refreshModels()
        }
    }
}
