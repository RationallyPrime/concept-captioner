import ConceptCore
import SwiftUI

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
                        Picker("Captioning provider", selection: $session.endpointKind) {
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
                        }.disabled(session.demoMode)
                    }.formStyle(.columns)
                    if session.endpointKind == "openai" || (session.useCritic && session.criticKind == "openai") {
                        ChatGPTCaptioningControls(session: session)
                    }
                    Text(
                        "The captioning model describes each selected image or clip according to your concept. "
                            + "The caption format is the text structure expected by the diffusion model you will train."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    Toggle("Have a second model check the caption", isOn: $session.useCritic)
                    if session.useCritic {
                        Form {
                            Picker("Reviewer provider", selection: $session.criticKind) {
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
                                + "It reads the same target, can request a revision and check it again, "
                                + "and uses additional account credits."
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
                                Button("Choose skill folder…") {
                                    if let url = ProjectAccess.chooseFolder(prompt: "Choose skill") {
                                        session.chooseSkill(url)
                                    }
                                }
                                if session.project?.job.skill != nil {
                                    Button("Use bundled") { session.useBundledSkill() }
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
                            Stepper("\(session.concurrency) samples at once", value: $session.concurrency, in: 1 ... 16)
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
                StudioSection(title: "Captioning results") {
                    if session.demoMode {
                        Picker("Simulated outcome", selection: $session.scenario) {
                            ForEach(DemoScenario.allCases) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Text(
                            "These are prepared FLUX captions for the three synthetic demo photos. "
                                + "No captioning model is called. Enable the reviewer to simulate rejection, "
                                + "or clear an assignment on Mapping to see a sample held for review."
                        )
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    if session.unmappedCount > 0 {
                        StudioNotice(
                            "\(session.unmappedCount) samples still need concept assignments. "
                                + "They will be skipped until you confirm them.",
                            symbol: "person.crop.rectangle"
                        )
                    }
                    if session.project?.images.isEmpty == true {
                        ContentUnavailableView(
                            "Import images or clips first",
                            systemImage: "photo.on.rectangle",
                            description: Text("Use Images to add the training data for your concept.")
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
        .onChange(of: session.endpointKind) { old, new in session.providerChanged(from: old, to: new) }
        .onChange(of: session.criticKind) { old, new in session.criticProviderChanged(from: old, to: new) }
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
        if session.demoMode { return "Shows prepared captions. No model request or charge." }
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
            "ltx-video": "LTX · video captions",
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
