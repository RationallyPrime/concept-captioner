import AppKit
import ConceptCore
import SwiftUI

struct ChatGPTSettingsSection: View {
    @Bindable var session: StudioSession
    private static let signInMark = Bundle.module.url(forResource: "chatgpt-logo-white", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        StudioSection(
            title: "Log in with ChatGPT",
            subtitle: "Use an eligible ChatGPT plan to write captions with OpenAI models. No API key is needed. "
                + "Requests count toward your plan or credits balance."
        ) {
            if session.demoMode {
                Text("Demo stays offline. Open or create a real project to connect ChatGPT.")
                    .foregroundStyle(StudioStyle.supportingText)
            } else {
                savedAccounts
                HStack {
                    Button {
                        Task { await session.connectChatGPT() }
                    } label: {
                        HStack(spacing: 8) {
                            if let mark = Self.signInMark {
                                Image(nsImage: mark).renderingMode(.original).resizable()
                                    .frame(width: 21, height: 21).accessibilityHidden(true)
                            }
                            Text(session.chatGPT.isBusy ? "Connecting…" : "Continue with ChatGPT")
                        }.foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent).tint(.black)
                    .disabled(session.busy || session.chatGPT.isBusy)
                    .help(session.chatGPT.accounts.isEmpty
                        ? "Sign in securely in your browser."
                        : "Add another ChatGPT account or workspace. Use Sign in again for a saved account.")
                    if session.chatGPT.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { session.chatGPT.cancelSignIn() }
                    }
                    Spacer()
                    ChatGPTUsageLink()
                }
                if let error = session.chatGPT.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else if !session.chatGPT.message.isEmpty {
                    Text(session.chatGPT.message).fixedSize(horizontal: false, vertical: true)
                }
                Text("Your browser handles sign-in. Saved sessions stay in your Mac’s Keychain, outside projects.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
        }
    }

    @ViewBuilder private var savedAccounts: some View {
        if !session.chatGPT.accounts.isEmpty {
            ChatGPTAccountPicker(session: session)
            if let account = session.chatGPT.selectedAccount {
                HStack {
                    Text(account.isSignedIn
                        ? (account.hasPlanPermission ? "Plan access enabled" : "Plan access not enabled")
                        : "Signed out")
                        .foregroundStyle(StudioStyle.supportingText)
                    Spacer()
                    Button(account.isSignedIn && !account.hasPlanPermission ? "Enable plan use" : "Sign in again") {
                        Task { await session.connectChatGPT(accountID: account.id) }
                    }
                    Button("Sign out") { Task { await session.chatGPT.signOut() } }
                        .disabled(!account.isSignedIn)
                }.disabled(session.busy || session.chatGPT.isBusy)
            }
        }
    }
}

struct ChatGPTAccountPicker: View {
    @Bindable var session: StudioSession

    var body: some View {
        Picker("ChatGPT account", selection: $session.chatGPT.selectedAccountID) {
            Text("Choose an account").tag(String?.none)
            ForEach(session.chatGPT.accounts) { account in
                Text(account.label).tag(Optional(account.id))
            }
        }
        .disabled(session.busy || session.chatGPT.isBusy)
    }
}

struct ChatGPTCaptioningControls: View {
    @Bindable var session: StudioSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Use OpenAI with", selection: $session.openAIUsesChatGPT) {
                Text("ChatGPT plan").tag(true)
                Text("OpenAI API credits").tag(false)
            }.disabled(session.busy)
            if session.openAIUsesChatGPT {
                if session.demoMode {
                    Text("Demo uses fake models and stays offline.")
                } else {
                    ChatGPTAccountPicker(session: session)
                    if !session.chatGPTReady {
                        HStack {
                            Text("Connect ChatGPT and allow plan use in Settings.")
                            SettingsLink { Text("Open Settings") }
                        }
                    }
                    HStack {
                        Label(
                            session.chatGPTReady ? "Using ChatGPT plan" : "ChatGPT plan selected",
                            systemImage: "person.crop.circle"
                        )
                        Spacer()
                        ChatGPTUsageLink()
                        Button("Refresh models") { Task { await session.chatGPT.refreshModels() } }
                            .disabled(session.busy || !session.chatGPTReady)
                    }
                    if let error = session.chatGPT.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let issue = session.chatGPTConfigurationIssue {
                        Text(issue).fixedSize(horizontal: false, vertical: true)
                        Button("Use default model settings for ChatGPT") { session.useDefaultChatGPTSettings() }
                            .disabled(session.busy)
                        Text("Clears custom OpenAI settings for this run and selects native structured output. "
                            + "Your thinking-effort choices are kept.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    Text("Applies to every OpenAI request, including caption checks, comparisons and photo advice. "
                        + "ChatGPT’s preview does not accept an output-token cap. Manage your usage limit in ChatGPT.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("OpenAI requests use your saved API key and separately billed API credits.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
        }
    }
}

struct ChatGPTModelPicker: View {
    let title: String
    @Binding var model: String
    let models: [ChatGPTAvailableModel]

    var body: some View {
        Picker(title, selection: $model) {
            if !models.contains(where: { $0.slug == model }) {
                Text(model.isEmpty ? "Choose a model" : "\(model) · refresh or choose another").tag(model)
            }
            ForEach(models) { choice in
                Text(choice.displayName).tag(choice.slug)
            }
        }
    }
}

struct ChatGPTUsageLink: View {
    var body: some View {
        Link("Manage usage", destination: StudioSession.chatGPTUsageURL)
    }
}
