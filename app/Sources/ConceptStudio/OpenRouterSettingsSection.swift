import SwiftUI

struct OpenRouterSettingsSection: View {
    @Bindable var session: StudioSession

    private var connection: OpenRouterConnection {
        session.openRouter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.demoMode {
                StudioNotice("Demo stays offline and does not connect to OpenRouter.")
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
                    .help("Approves access in your browser; the resulting key stays in this Mac’s Keychain.")
                    if connection.isBusy {
                        ProgressView().controlSize(.small)
                        Button("Cancel authorization or refresh") { connection.cancel() }
                            .help("Cancels the current account request and closes any callback listener.")
                    } else if connection.isConnected {
                        Button("Refresh key usage") {
                            Task { await connection.refresh() }
                        }
                        .disabled(session.busy)
                        .help("Reads usage and limits for the saved key; it does not run a model or buy credits.")
                        Button("Disconnect on this Mac") {
                            Task { await connection.disconnect() }
                        }
                        .disabled(session.busy)
                        .help("Removes the key from this Mac; revoke it in OpenRouter to disable it there.")
                    }
                }
                if let error = connection.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else if !connection.message.isEmpty {
                    Text(connection.message).font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    Link("OpenRouter credits", destination: URL(string: "https://openrouter.ai/settings/credits")!)
                        .help("Opens the OpenRouter credits page; this app buys nothing.")
                    Link("Key settings", destination: connection.keySettingsURL)
                        .help("Opens this key’s settings to change its limit or revoke it.")
                    if connection.keyHash != nil {
                        Link("Key request activity", destination: connection.activityURL)
                            .help("Opens the request log for this key in OpenRouter.")
                    }
                }
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
