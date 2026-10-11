import ConceptCore
import SwiftUI

/// Provider vocabulary and default model ids for every view. Lane app-contract moves this table into
/// StudioEndpointChoices.swift; at integration the views read that table instead.
enum ModelChoices {
    static let providers = ["openrouter", "vercel", "gateway/anthropic", "google", "anthropic", "openai", "vllm"]

    /// The model offered when a provider is chosen and the model field is empty or still holds the
    /// previous provider's default. `nil` for OpenAI with a ChatGPT plan, whose models come from the plan.
    static func defaultModel(for kind: String, chatGPTPlan: Bool = false) -> String? {
        switch kind {
        case "google": "gemini-3.8-flash"
        case "anthropic", "gateway/anthropic": "claude-sonnet-4-6"
        case "openai": chatGPTPlan ? nil : "gpt-5.2"
        case "vllm": "Qwen/Qwen3-VL-8B-Instruct"
        default: "google/gemini-3.8-flash"
        }
    }

    /// The model to show after switching from `old` to `new`: a typed model is never replaced.
    static func model(afterSwitchingFrom old: String, to new: String, current: String, chatGPTPlan: Bool) -> String {
        let replaceable = current.isEmpty || current == defaultModel(for: old, chatGPTPlan: chatGPTPlan)
        guard replaceable, let model = defaultModel(for: new, chatGPTPlan: chatGPTPlan) else { return current }
        return model
    }

    static func title(_ kind: String) -> String {
        [
            "openrouter": "OpenRouter gateway",
            "vercel": "Vercel AI Gateway",
            "gateway/anthropic": "Pydantic AI Gateway",
            "google": "Google Gemini",
            "anthropic": "Anthropic Claude",
            "openai": "OpenAI",
            "vllm": "My pod / custom server",
        ][kind] ?? kind
    }
}

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
                            ForEach(ModelChoices.providers, id: \.self) { Text(ModelChoices.title($0)).tag($0) }
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
                                ForEach(ModelChoices.providers, id: \.self) { Text(ModelChoices.title($0)).tag($0) }
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
        .onChange(of: session.endpointKind) { old, kind in
            if kind == "vllm", session.usingPodCaptioner {
                session.modelName = session.gpu.captionModel
            } else {
                session.modelName = ModelChoices.model(
                    afterSwitchingFrom: old, to: kind, current: session.modelName,
                    chatGPTPlan: session.openAIUsesChatGPT
                )
            }
        }
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
