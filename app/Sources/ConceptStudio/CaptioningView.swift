import ConceptCore
import SwiftUI

private struct ProviderModelRefreshIdentity: Equatable {
    let cacheKey: ProviderModelCacheKey
    let usesChatGPT: Bool
}

struct CaptioningView: View {
    @Bindable var session: StudioSession
    @State private var overwrite = false
    @State private var refreshingModels = false
    @State private var catalogRequestGeneration = 0
    @State private var modelCatalogStatus: String?
    @State private var testingConnection = false
    @State private var connectionTestStatus: String?

    var captionFormatSelection: Binding<String> {
        Binding(
            get: { session.project?.job.profile ?? ModelTable.shared.defaultRow.captions.imageProfile },
            set: { profile in
                guard !session.demoMode else { return }
                session.project?.job.profile = profile
                session.saveProject()
            }
        )
    }

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
                            ProviderModelPicker(
                                title: "Model",
                                providerKind: session.endpointKind,
                                model: $session.modelName,
                                choices: availableModels,
                                isRefreshing: refreshingModels,
                                refresh: { Task { await refreshModels(force: true) } }
                            ).disabled(session.busy)
                        }
                        Picker("Caption format", selection: captionFormatSelection) {
                            ForEach(profiles, id: \.self) { Text(Self.profileTitle($0)).tag($0) }
                        }.disabled(session.demoMode)
                    }.formStyle(.columns).disabled(session.busy)
                    if !session.demoMode && !(session.endpointKind == "openai" && session.openAIUsesChatGPT) {
                        if let modelCatalogStatus {
                            Text(modelCatalogStatus)
                                .font(.callout)
                                .foregroundStyle(StudioStyle.supportingText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 12) {
                        Button(testingConnection ? "Testing connection…" : "Test captioning connection") {
                            testConnection()
                        }
                        .disabled(session.busy || session.editing || refreshingModels)
                        .help(
                            "Sends a small request with the selected account and model. It uses that account’s credits "
                                + "or ChatGPT allowance, but saves no project captions."
                        )
                        if testingConnection {
                            ProgressView().controlSize(.small)
                            Button("Cancel test") { session.cancel() }
                                .help("Cancels the request. The test never writes project captions.")
                        } else if let connectionTestStatus {
                            Label(
                                connectionTestStatus,
                                systemImage: connectionTestStatus == "Connection succeeded."
                                    ? "checkmark.circle"
                                    : "exclamationmark.triangle"
                            )
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if session.demoMode {
                        Text("The demo uses prepared FLUX captions, so its format stays fixed. "
                            + "In a real project, choose the format your training model expects.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.endpointKind == "openai" || (session.useCritic && session.criticKind == "openai") {
                        ChatGPTCaptioningControls(session: session)
                    }
                    Text(
                        "The captioning model describes each selected image or clip according to your concept. "
                            + "The caption format is the text structure expected by the diffusion model you will train."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    Toggle("Have a second model check the caption", isOn: $session.useCritic)
                        .disabled(session.busy)
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
                        }.formStyle(.columns).disabled(session.busy)
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
                    }.disabled(session.busy)
                    if !session.advancedUser {
                        let overrides = session.advancedCaptionOverrides
                            + (overwrite ? ["Re-caption existing model captions"] : [])
                        if !overrides.isEmpty {
                            StudioNotice("Advanced settings still in force: " + overrides.joined(separator: "; ")
                                + ". Turn on Advanced user to edit them.")
                        }
                    }
                    if session.advancedUser {
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
                                Stepper(
                                    "\(session.concurrency) samples at once",
                                    value: $session.concurrency,
                                    in: 1 ... 16
                                )
                                if session.endpointKind == "vllm" {
                                    TextField(
                                        "Server URL for this project (blank uses Settings)",
                                        text: $session.requestBaseURL
                                    )
                                }
                                Toggle("Re-caption existing model captions", isOn: $overwrite)
                                Text(
                                    "Final captions are always protected. "
                                        + "Turn this on to replace earlier model captions."
                                )
                                .font(.caption).foregroundStyle(StudioStyle.supportingText)
                            }.formStyle(.columns).padding(.top, 12)
                        }.disabled(session.busy)
                    }
                }
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
                                + "or choose Failed or Unusable to inspect those outcomes."
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
                    if session.unprotectedImportedCount > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(
                                "\(session.unprotectedImportedCount) imported captions can be replaced "
                                    + "when overwrite is on."
                            )
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                            .fixedSize(horizontal: false, vertical: true)
                            Button("Protect imported captions", systemImage: "lock") {
                                session.protectImportedCaptions()
                            }
                            .disabled(session.busy || session.editing || session.demoMode)
                            .help("Mark all imported captions as final so captioning runs skip them.")
                        }
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
                            HStack(alignment: .top, spacing: 14) {
                                PhotoView(url: image.url).frame(width: 72, height: 64)
                                    .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(image.id).font(.headline).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Label(
                                        image.captionState.label,
                                        systemImage: image.captionState.symbol
                                    )
                                    .font(.callout)
                                    if let partial = session.partialCaptions[image.id], !partial.isEmpty {
                                        Text("Writing — not saved yet").font(.caption)
                                            .foregroundStyle(StudioStyle.supportingText)
                                        Text(partial).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .accessibilityLabel("Caption in progress. Not saved yet. \(partial)")
                                    }
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
        .onChange(of: session
            .providerModelChoices[session.providerModelCacheKey(for: session.endpointKind)]) { _, models in
                modelCatalogStatus = models.map { "\($0.count) models listed." }
        }
        .onChange(of: modelCatalogTaskID) { _, _ in
            catalogRequestGeneration &+= 1
            refreshingModels = false
            modelCatalogStatus = nil
        }
        .task(id: modelCatalogTaskID) { await refreshModels() }
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
        if session.project?.images.isEmpty != false {
            return "No images or clips are included. Include at least one on Images before captioning."
        }
        if session.demoMode { return "Shows prepared captions. No model request or charge." }
        if session.usesChatGPTForThisRun {
            return "OpenAI requests use your ChatGPT plan. Any other provider uses its own account credits."
        }
        return "Uses your provider account credits. Hosted captioning needs no rented GPU."
    }

    private var availableModels: [ProviderModelChoice] {
        ProviderModelCatalog.forCaptioning(
            session.providerModelChoices[session.providerModelCacheKey(for: session.endpointKind)] ?? [],
            includesVideo: session.project?.images.contains {
                Sources.isVideo(Sources.suffix(of: $0.id))
            } == true
        )
    }

    private var profiles: [String] {
        (try? session.selectedSkill().profiles())
            ?? [session.project?.job.profile ?? ModelTable.shared.defaultRow.captions.imageProfile]
    }

    /// The title the table gives a profile, "Plain prose" for the one profile no model owns, else the profile.
    static func profileTitle(_ profile: String) -> String {
        if profile == "plain" { return "Plain prose" }
        return ModelTable.shared.captionTitles[profile] ?? profile
    }
}

private extension CaptioningView {
    var modelCatalogTaskID: ProviderModelRefreshIdentity {
        ProviderModelRefreshIdentity(
            cacheKey: session.providerModelCacheKey(for: session.endpointKind),
            usesChatGPT: session.openAIUsesChatGPT
        )
    }

    @MainActor
    func refreshModels(force: Bool = false) async {
        guard !session.demoMode, !(session.endpointKind == "openai" && session.openAIUsesChatGPT) else { return }
        let kind = session.endpointKind
        let cacheKey = session.providerModelCacheKey(for: kind)
        let requestID = modelCatalogTaskID
        if !force, let models = session.providerModelChoices[cacheKey] {
            modelCatalogStatus = "\(models.count) models listed."
            return
        }
        modelCatalogStatus = nil
        catalogRequestGeneration &+= 1
        let generation = catalogRequestGeneration
        refreshingModels = true
        defer {
            if generation == catalogRequestGeneration { refreshingModels = false }
        }
        do {
            let models = try await session.refreshProviderModels(for: kind)
            try Task.checkCancellation()
            guard requestID == modelCatalogTaskID else { return }
            modelCatalogStatus = "\(models.count) models listed."
        } catch is CancellationError {
            // A provider switch cancels the previous catalog request.
        } catch {
            if requestID == modelCatalogTaskID { modelCatalogStatus = error.localizedDescription }
        }
    }

    @MainActor
    func testConnection() {
        connectionTestStatus = nil
        testingConnection = true
        let generation = session.chatGPTWorkGeneration
        let started = session.perform("Testing captioning connection…") {
            defer { testingConnection = false }
            do {
                if session.demoMode {
                    connectionTestStatus = "Demo connection works locally; no key or network used."
                    return
                }
                if session.endpointKind == "openai", session.openAIUsesChatGPT {
                    await session.prepareChatGPTModels(duringConnectionTest: true)
                    try Task.checkCancellation()
                    guard generation == session.chatGPTWorkGeneration, !session.demoMode else {
                        throw CancellationError()
                    }
                    if session.chatGPT.availableModels.isEmpty, let issue = session.chatGPT.errorMessage {
                        throw StudioError.message(issue)
                    }
                }
                let endpoint = try session.endpoint()
                _ = try await endpoint.client.request(
                    instructions: "Return a Caption object with caption set to connected.",
                    messages: [.user("Test connection")],
                    output: OutputRequest(
                        name: Caption.schemaName,
                        schema: Caption.jsonSchema,
                        mode: endpoint.outputMode
                    ),
                    settings: endpoint.settings
                )
                connectionTestStatus = "Connection succeeded."
                session.message = "Captioning connection succeeded."
            } catch is CancellationError {
                connectionTestStatus = "Test cancelled. No project captions were written."
            } catch {
                connectionTestStatus = StudioSession.describe(error)
                session.message = "Captioning connection test failed."
            }
        }
        if !started { testingConnection = false }
    }
}
