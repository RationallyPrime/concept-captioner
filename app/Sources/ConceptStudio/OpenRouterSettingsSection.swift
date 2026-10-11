import SwiftUI

struct OpenRouterSettingsSection: View {
    @Bindable var session: StudioSession

    private var connection: OpenRouterConnection {
        session.openRouter
    }

    var body: some View {
        StudioSection(
            title: "OpenRouter browser authorization",
            subtitle: "OpenRouter is a gateway: one account pays for models from several providers. "
                + "Browser approval creates an API key saved in your Mac’s Keychain. "
                + "Captioning uses OpenRouter credits."
        ) {
            if session.demoMode {
                StudioNotice("The offline demo does not open a browser, read saved keys or contact OpenRouter.")
            } else {
                Form {
                    LabeledContent("Connection", value: status)
                    if let info = connection.info {
                        if let user = info.creatorUserID {
                            LabeledContent("Account identifier", value: user).textSelection(.enabled)
                        }
                        LabeledContent("Key usage", value: money(info.usage))
                        if let daily = info.usageDaily { LabeledContent("Used today", value: money(daily)) }
                        if let remaining = info.limitRemaining {
                            LabeledContent("Key allowance remaining", value: money(remaining))
                        }
                        LabeledContent("Key spending limit", value: info.limit.map(money) ?? "No key-specific limit")
                        if let reset = info.limitReset { LabeledContent("Limit resets", value: reset) }
                        LabeledContent("OpenRouter tier", value: info.isFreeTier ? "Free tier" : "Paid credits")
                        if let refreshed = connection.lastRefreshed {
                            LabeledContent(
                                "Last checked",
                                value: refreshed.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }
                }.formStyle(.columns)
                HStack(spacing: 12) {
                    Button(connection.isConnected ? "Reconnect OpenRouter" : "Connect OpenRouter") {
                        Task { await session.connectOpenRouter() }
                    }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .disabled(session.busy || connection.isBusy)
                    .help(
                        "Opens your browser for approval. Replaces the saved OpenRouter key only after success."
                    )
                    if connection.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel authorization or refresh") { connection.cancel() }
                            .help(
                                "Cancels authorization or usage refresh and closes the callback listener."
                            )
                    } else if connection.isConnected {
                        Button("Refresh key usage") {
                            Task { await connection.refresh() }
                        }
                        .disabled(session.busy)
                        .help("Reads usage and limits for the saved key. It does not run a model or buy credits.")
                        Button("Disconnect on this Mac") {
                            Task { await connection.disconnect() }
                        }
                        .disabled(session.busy)
                        .help("Removes the key from this Mac. Use Key settings to revoke it on OpenRouter too.")
                    }
                }
                if !connection.message.isEmpty {
                    Text(connection.message).font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    Link("OpenRouter credits", destination: URL(string: "https://openrouter.ai/settings/credits")!)
                        .help("Opens OpenRouter’s account page to view or purchase credits. This app buys nothing.")
                    Link("Key settings", destination: connection.keySettingsURL)
                        .help("Opens the key’s OpenRouter settings to change its limit or revoke it.")
                    if connection.keyHash != nil {
                        Link("Key request activity", destination: connection.activityURL)
                            .help(
                                "Opens this key’s request log on OpenRouter. Only its signed-in owner can view it."
                            )
                    }
                }
                Text("Usage above is for this API key, not your total wallet balance. "
                    +
                    "Reconnect replaces the saved key; it does not revoke older keys. You can also paste a key below.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("How browser authorization works") {
                Text("PKCE (Proof Key for Code Exchange) binds browser approval to this app’s temporary request. "
                    + "A local callback receives the authorization code. "
                    + "It closes on completion, cancellation or timeout. "
                    + "The browser may label the app with 127.0.0.1 and a port number: this is a loopback address, "
                    + "which points back to this Mac. The resulting API key stays in Keychain, outside the project.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText).padding(.top, 8)
            }
        }
    }

    private var status: String {
        if connection.isBusy { return "Account action in progress" }
        if connection.info != nil { return "Key accepted by OpenRouter" }
        return connection.isConnected ? "Key saved on this Mac; refresh to check usage" : "No accepted key on this Mac"
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }
}
