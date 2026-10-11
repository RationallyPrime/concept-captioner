import ConceptCore
import SwiftUI

// MARK: - Integration seam for lane app-contract (DELETE at integration)

/// Mirrors lane app-contract's `ProviderChoices` (StudioEndpointChoices.swift on fix/app-contract): provider
/// vocabulary and default models in one table. After both lanes merge the duplicate declaration fails to
/// compile and this copy is deleted; the views already call the shared names.
enum ProviderChoices {
    struct Provider: Equatable, Identifiable {
        let kind: String
        let title: String
        let defaultModel: String
        var id: String {
            kind
        }
    }

    static let all: [Provider] = [
        Provider(kind: "openrouter", title: "OpenRouter gateway", defaultModel: "google/gemini-3.8-flash"),
        Provider(kind: "vercel", title: "Vercel AI Gateway", defaultModel: "google/gemini-3.8-flash"),
        Provider(kind: "gateway/anthropic", title: "Pydantic AI Gateway", defaultModel: "claude-sonnet-4-6"),
        Provider(kind: "google", title: "Google Gemini", defaultModel: "gemini-3.8-flash"),
        Provider(kind: "anthropic", title: "Anthropic Claude", defaultModel: "claude-sonnet-4-6"),
        Provider(kind: "openai", title: "OpenAI", defaultModel: "gpt-5.2"),
        Provider(kind: "vllm", title: "My pod / custom server", defaultModel: "Qwen/Qwen3-VL-8B-Instruct"),
    ]

    static let defaultKind = "openrouter"

    static var kinds: [String] {
        all.map(\.kind)
    }

    static func title(_ kind: String) -> String {
        all.first { $0.kind == kind }?.title ?? kind
    }

    static func defaultModel(for kind: String) -> String {
        all.first { $0.kind == kind }?.defaultModel ?? ""
    }

    static func model(
        afterSwitchingFrom old: String,
        to new: String,
        current: String,
        previousDefault: String? = nil,
        newDefault: String? = nil
    ) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let untouched = trimmed.isEmpty || trimmed == (previousDefault ?? defaultModel(for: old))
        return untouched ? (newDefault ?? defaultModel(for: new)) : current
    }
}

// MARK: - End seam

struct CaptioningView: View {
    @Bindable var session: StudioSession
    @State private var overwrite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                StudioSection(
                    title: "How captions are written",
                    subtitle: "Choose a model and the format your training model needs."
                ) {
                    Form {
                        Picker("Account", selection: $session.endpointKind) {
                            ForEach(ProviderChoices.kinds, id: \.self) { Text(ProviderChoices.title($0)).tag($0) }
                        }.disabled(session.busy)
                        if session.endpointKind == "openai", session.openAIUsesChatGPT, !session.demoMode {
                            ChatGPTModelPicker(
                                title: "Model", model: $session.modelName, models: session.chatGPT.availableModels
                            ).disabled(session.busy)
                        } else {
                            TextField("Model", text: $session.modelName)
                                .help(
                                    "Use the model identifier from your provider. "
                                        + "A gateway can use many models with one key."
                                )
                        }
                        Picker("Caption format", selection: Binding(
                            get: { session.project?.job.profile ?? "flux-image" },
                            set: { session.project?.job.profile = $0; session.saveProject() }
                        )) {
                            ForEach(profiles, id: \.self) { Text(profileTitle($0)).tag($0) }
                        }
                    }.formStyle(.columns)
                    if session.endpointKind == "openai" || (session.useCritic && session.criticKind == "openai") {
                        ChatGPTCaptioningControls(session: session)
                    }
                    Text(
                        "Your concept boundaries guide every caption. "
                            + "The format controls how that description is written."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    Toggle("Have a second model check the caption", isOn: $session.useCritic)
                    if session.useCritic {
                        Form {
                            Picker("Reviewer account", selection: $session.criticKind) {
                                ForEach(ProviderChoices.kinds, id: \.self) { Text(ProviderChoices.title($0)).tag($0) }
                            }.disabled(session.busy)
                            if session.criticKind == "openai", session.openAIUsesChatGPT, !session.demoMode {
                                ChatGPTModelPicker(
                                    title: "Reviewer model", model: $session.criticModel,
                                    models: session.chatGPT.availableModels
                                ).disabled(session.busy)
                            } else {
                                TextField("Reviewer model", text: $session.criticModel)
                            }
                            if session.criticKind == "vllm" {
                                TextField(
                                    "Reviewer server URL (blank uses Settings)",
                                    text: $session.criticRequestBaseURL
                                )
                            }
                        }.formStyle(.columns)
                        Text(
                            "The reviewer can reject a caption with notes. "
                                + "This adds a second provider request per photo."
                        )
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    DisclosureGroup("Caption instructions and custom skills") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(session.project?.job.skill == nil
                                ? "Using the bundled concept-boundary instructions."
                                : "Using your selected instruction folder:")
                            if let path = session.project?.job.skill {
                                Text(path).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                Button("Choose skill folder…") { session.chooseSkill() }
                                if session.project?.job.skill != nil {
                                    Button("Use bundled") { session.project?.job.skill = nil; session.saveProject() }
                                }
                            }
                            Text("A skill folder supplies the caption-writing instructions and its available formats.")
                                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        }.padding(.top, 12)
                    }
                    DisclosureGroup("Advanced model and batch controls") {
                        Form {
                            Picker("Thinking effort", selection: $session.modelThinking) {
                                ForEach(ThinkingLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            if session.useCritic {
                                Picker("Reviewer thinking effort", selection: $session.criticThinking) {
                                    ForEach(ThinkingLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                            }
                            Picker("Structured response mode", selection: $session.outputMode) {
                                ForEach(OutputMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Stepper("\(session.concurrency) photos at once", value: $session.concurrency, in: 1 ... 16)
                            if session.endpointKind == "vllm" {
                                TextField(
                                    "Server URL for this project (blank uses Settings)",
                                    text: $session.requestBaseURL
                                )
                            }
                            Toggle("Re-caption existing model captions", isOn: $overwrite)
                            Text("Final captions are always protected. Turn this on to replace earlier model captions.")
                                .font(.caption).foregroundStyle(StudioStyle.supportingText)
                        }.formStyle(.columns).padding(.top, 12)
                    }
                }.disabled(session.busy)
                Divider()
                DisclosureGroup("Optional: caption on a rented computer") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Hosted captioning needs no rented GPU. To use a local model, rent a computer, "
                            + "caption on GPU 0, then review and publish before training.")
                            .foregroundStyle(StudioStyle.supportingText)
                        Button("Rent or choose a captioning computer") { session.step = .pods }
                        Button("Start caption server and use this computer") { session.usePodCaptionServer() }
                            .disabled(session.busy || !session.gpu.hasRunningPod)
                        if session.usingPodCaptioner {
                            StudioNotice("Using your authenticated computer’s caption server.", symbol: "server.rack")
                            Button("Use my Settings server instead") {
                                session.usingPodCaptioner = false
                                session.requestBaseURL = ""
                            }
                        }
                    }.padding(.top, 12)
                }.disabled(session.busy)
                Divider()
                StudioSection(title: "Write and watch") {
                    if session.demoMode {
                        Picker("Demo outcome to try", selection: $session.scenario) {
                            ForEach(DemoScenario.allCases) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Text(
                            "Enable the reviewer to try Rejected. Clear a mapping on Mapping to try Needs mapping."
                        )
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    if session.unmappedCount > 0 {
                        StudioNotice(
                            "\(session.unmappedCount) photos still need mapping. "
                                + "They will be skipped until you confirm them.",
                            symbol: "person.crop.rectangle"
                        )
                    }
                    if session.project?.images.isEmpty == true {
                        ContentUnavailableView(
                            "Add photos first",
                            systemImage: "photo.on.rectangle",
                            description: Text("Import your image set on Images, then return here.")
                        )
                    }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.project?.images ?? []) { image in
                            let status = captionStatus(for: image)
                            HStack(alignment: .top, spacing: 14) {
                                PhotoView(url: image.url).frame(width: 72, height: 64)
                                    .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(image.id).font(.headline).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Label(
                                        status.title,
                                        systemImage: status.symbol
                                    )
                                    .font(.callout)
                                    if !image.notes.isEmpty {
                                        Text(image.notes.joined(separator: "; "))
                                            .foregroundStyle(StudioStyle.supportingText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }.padding(.top, 8)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { captionAction }
        .task(id: session.usesChatGPTForThisRun) { await session.prepareChatGPTModels() }
        .onChange(of: session.chatGPT.selectedAccountID) { _, _ in
            Task { await session.prepareChatGPTModels() }
        }
        .onChange(of: session.openAIUsesChatGPT) { _, _ in session.rememberChoices() }
        .onChange(of: session.endpointKind) { old, new in
            session.modelName = model(afterSwitchingFrom: old, to: new, current: session.modelName)
        }
        .onChange(of: session.criticKind) { old, new in
            session.criticModel = model(afterSwitchingFrom: old, to: new, current: session.criticModel)
        }
    }

    /// A typed model is kept; a provider default is offered only for an empty or untouched field. OpenAI on a
    /// ChatGPT plan takes its models from the plan. (Lane app-contract's `providerChanged(from:to:)`.)
    private func model(afterSwitchingFrom old: String, to new: String, current: String) -> String {
        guard !(new == "openai" && session.openAIUsesChatGPT) else { return current }
        let podModel = { (kind: String) in
            kind == "vllm" && session.usingPodCaptioner ? session.gpu.captionModel : ProviderChoices
                .defaultModel(for: kind)
        }
        return ProviderChoices.model(
            afterSwitchingFrom: old, to: new, current: current,
            previousDefault: podModel(old), newDefault: podModel(new)
        )
    }

    private var captionAction: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 16) {
                Button("Start captioning", systemImage: "play.fill") { session.caption(overwrite: overwrite) }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint).fixedSize()
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Start captioning (⌘↩)")
                    .disabled(session.busy || session.project?.images.isEmpty != false
                        || (!session.demoMode && session.usesChatGPTForThisRun && !session.chatGPTReady))
                    .disabled(session.chatGPTConfigurationIssue != nil)
                Text(captionCost)
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 10)
        }.background(StudioStyle.canvas)
    }

    private var captionCost: String {
        if session.demoMode { return "Demo captioning costs $0 and stays offline." }
        if session.usesChatGPTForThisRun {
            return "OpenAI requests use your ChatGPT plan. Any other provider uses its own account credits."
        }
        return "Uses your provider account credits. Hosted captioning needs no rented GPU."
    }

    private var profiles: [String] {
        (try? session.selectedSkill().profiles()) ?? [session.project?.job.profile ?? "flux-image"]
    }

    private func profileTitle(_ profile: String) -> String {
        [
            "flux-image": "FLUX · image captions",
            "ltx-image": "LTX · image captions",
            "h3-still": "H3 · still-image captions",
            "plain": "Plain prose",
        ][profile] ?? profile
    }

    private func captionStatus(for image: ProjectImage) -> (title: String, symbol: String) {
        if image.isFinal { return ("Final · protected", "lock.fill") }
        switch image.status {
        case .written: return ("Written", "checkmark.circle")
        case .skipped: return ("Skipped", "arrow.right.circle")
        case .needsMapping: return ("Needs mapping", "person.crop.rectangle")
        case .unusable: return ("Unusable", "exclamationmark.triangle")
        case .rejected: return ("Rejected", "hand.raised")
        case .failed: return ("Failed", "exclamationmark.circle")
        case nil: return ("Ready", "circle")
        }
    }
}
