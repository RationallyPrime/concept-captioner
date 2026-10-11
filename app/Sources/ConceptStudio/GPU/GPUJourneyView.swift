import AppKit
import Charts
import SwiftUI

enum MonitorTab: String, CaseIterable, Identifiable {
    case progress = "Progress"
    case tensorBoard = "TensorBoard"
    case log = "Training log"
    case results = "Generated results"
    case runs = "Saved runs"

    var id: Self {
        self
    }
}

struct GPUJourneyView: View {
    let session: StudioSession
    @Bindable var workspace: GPUWorkspace
    let step: StudioStep
    /// The journey footer already shows spend and Stop everything; the Welcome sheet does not.
    var showsSpendControls = true
    @State private var confirmTermination = false
    @State private var newBudget: Double?

    init(session: StudioSession, step: StudioStep, showsSpendControls: Bool = true) {
        self.session = session
        workspace = session.gpu
        self.step = step
        self.showsSpendControls = showsSpendControls
    }

    private var datasetRepo: String {
        session.repoID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            status
            if workspace.demoMode {
                StudioNotice(
                    "Demo computer and prices. No computer is rented and there are no charges.",
                    symbol: "leaf"
                )
            }
            switch step {
            case .pods: ScrollView { pods.padding(.bottom, 12) }
            case .training: ScrollView { training.padding(.bottom, 12) }
            case .monitor: monitor
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if workspace.offers.isEmpty { await workspace.refreshOffers() } }
        .confirmationDialog("Permanently remove this computer?", isPresented: $confirmTermination) {
            Button("Remove computer", role: .destructive) { Task { await workspace.terminate() } }
        } message: {
            Text(
                "Stopping clears temporary files. Removing deletes the computer. Saved network storage remains."
            )
        }
    }

    /// Inline status: progress and recoverable states. Blocking failures go to the window alert.
    private var status: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(workspace.pod?.status.capitalized ?? "No rented computer", systemImage: "server.rack")
                    .font(.headline)
                Text(workspace.message).font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if workspace.isBusy || workspace.isStopping { ProgressView().controlSize(.small) }
            if showsSpendControls, workspace.hasRunningPod {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("GPU spend · \(StudioMoney.format(workspace.elapsedCost))")
                        .font(.headline).monospacedDigit()
                    Button(workspace.isStopping ? "Stopping…" : "Stop everything", systemImage: "stop.circle") {
                        session.requestStopEverything()
                    }.disabled(workspace.isStopping)
                }
            }
        }
    }

    // MARK: GPU pods

    private var pods: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(
                title: "Choose a training computer",
                subtitle: "A GPU is the part that does the training. These have at least "
                    + "\(GPUWorkspace.minimumGPUMemoryGB) GB of memory to fit the included models."
            ) {
                Form {
                    trainerPicker
                    Picker("Number of GPUs", selection: $workspace.gpuCount) {
                        Text("1 · caption, then train").tag(1)
                        Text("2 · caption and train together").tag(2)
                        Text("4 · caption and train together").tag(4)
                    }
                    .disabled(workspace.hasRunningPod || workspace.isBusy)
                    .onChange(of: workspace.gpuCount) { _, _ in Task { await workspace.refreshOffers() } }
                    Picker("Computer", selection: $workspace.selectedGPU) {
                        ForEach(workspace.availableOffers) { offer in
                            Text(offer.summary).tag(offer.id)
                        }
                    }
                    .disabled(workspace.hasRunningPod)
                }.formStyle(.columns)
                Button("Refresh prices and availability") { Task { await workspace.refreshOffers() } }
                    .disabled(workspace.isBusy)
            }
            Divider()
            StudioSection(
                title: "Persistent storage",
                subtitle: "Network storage keeps checkpoints after stopping. "
                    + "It is billed separately, even when stopped."
            ) {
                Form {
                    Picker("Saved storage", selection: $workspace.selectedVolume) {
                        ForEach(workspace.volumes) { volume in
                            Text("\(volume.name) · \(volume.size) GB · \(volume.dataCenter)").tag(volume.id)
                        }
                    }
                    .disabled(workspace.hasRunningPod)
                    .onChange(of: workspace.selectedVolume) { _, _ in workspace.selectAvailableOffer() }
                }.formStyle(.columns)
                if workspace.volumes.isEmpty, !workspace.demoMode,
                   let url = URL(string: "https://console.runpod.io/storage") {
                    Link("Create project storage in RunPod", destination: url)
                }
            }
            Divider()
            spending
        }
    }

    private var spending: some View {
        StudioSection(
            title: "Control your spending",
            subtitle: "ConceptStudio keeps your Mac awake and enforces the spending limit and idle stop while a "
                + "computer runs. Stop also works if the agent fails."
        ) {
            Form {
                if workspace.quotedHourlyRate > 0 || workspace.hasRunningPod {
                    LabeledContent("Computer price") {
                        Text(StudioMoney.perHour(workspace.pod?.cost ?? workspace.quotedHourlyRate))
                            .font(.headline).monospacedDigit()
                    }
                }
                if workspace.hasRunningPod {
                    LabeledContent("Spending limit") {
                        Text(StudioMoney.format(workspace.activeBudget ?? workspace.budget)).monospacedDigit()
                    }
                    TextField("Raise the limit to (USD)", value: $newBudget, format: .number)
                } else {
                    TextField("Stop at this GPU budget (USD)", value: $workspace.budget, format: .number)
                }
                Stepper("Stop after \(workspace.idleMinutes) idle minutes", value: $workspace.idleMinutes, in: 1 ... 60)
            }.formStyle(.columns)
            if workspace.hasRunningPod {
                Button("Raise spending limit…") { raiseBudget() }
                    .disabled((newBudget ?? 0) <= (workspace.activeBudget ?? workspace.budget))
                    .help("The limit can only go up while the computer runs. You confirm the new amount first.")
            } else if workspace.quotedHourlyRate <= 0 {
                Text("Choose an available computer to see its price.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            Button(workspace.quotedHourlyRate > 0
                ? "Rent computer · \(StudioMoney.perHour(workspace.quotedHourlyRate))"
                : "Choose a computer first") {
                    Task { await workspace.rent() }
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .disabled(workspace.isBusy || workspace.pod != nil || workspace.quotedHourlyRate <= 0)
                .help("Renting starts GPU billing, so it has no keyboard shortcut.")
            if workspace.pod != nil {
                if !workspace.hasRunningPod {
                    Text("Remove this stopped computer before renting another. Saved network storage remains.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                Button("Remove computer…", role: .destructive) { confirmTermination = true }
            }
        }
    }

    private func raiseBudget() {
        let current = workspace.activeBudget ?? workspace.budget
        guard let target = newBudget, target > current else { return }
        Task {
            let rate = workspace.pod.map(\.cost).flatMap { $0 > 0 ? $0 : nil }
            guard await session.ask(.raiseBudget(from: current, to: target, hourlyRate: rate)) == .confirm
            else { return }
            if workspace.raiseBudget(to: target) { newBudget = nil }
        }
    }

    private var trainerPicker: some View {
        Picker("Prepare it for", selection: $workspace.trainer) {
            Text("AI Toolkit · image model").tag("aitoolkit")
            Text("LTX · image and video model").tag("ltx")
        }
        .disabled(workspace.hasRunningPod || workspace.isBusy)
    }

    // MARK: Training

    private var training: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Your training plan") {
                Text(workspace.plan?.explanation
                    ?? "Rent a computer first. Its control agent will tell us which GPUs each service can use.")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(
                    "Published dataset",
                    value: trainingDatasetRepo.isEmpty
                        ? "Publish your training media first" : trainingDatasetRepo
                )
                LabeledContent(
                    "Published revision",
                    value: trainingDatasetRevision ?? "Latest revision on first download"
                )
                .font(.callout).textSelection(.enabled)
                Text("Training downloads this published dataset. Publish again after changing included media, crops, "
                    + "segments or captions on this Mac.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                Button("Refresh the plan") { Task { await workspace.refresh() } }
            }
            Divider()
            StudioSection(
                title: "What to train",
                subtitle: "Some models require you to accept their license in your Hugging Face account first."
            ) {
                Form {
                    trainerPicker
                    TextField("Starting model", text: $workspace.baseModel)
                        .help("Base diffusion model to train. Choose a compatible model for these images or clips.")
                    TextField(
                        "Save trained model to",
                        text: $workspace.outputRepo,
                        prompt: Text("your-name/model-name")
                    )
                    Toggle("Keep the trained model private", isOn: $workspace.privateResult)
                }.formStyle(.columns)
                Text("With a Hugging Face token in Settings, the trained model is uploaded to this repository when "
                    + "training finishes. Without one, it is saved in this project's results folder on your Mac.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            StudioSection(
                title: "Run settings",
                subtitle: "A training step updates the model using a batch of your examples. More steps take longer; "
                    + "compare saved checkpoints to find the best result."
            ) {
                Form {
                    Stepper("Training steps: \(workspace.steps)", value: $workspace.steps, in: 25 ... 10000, step: 25)
                }.formStyle(.columns)
                DisclosureGroup("Advanced training controls") { advancedTraining.padding(.top, 12) }
                Button("Start training", systemImage: "play.fill") {
                    Task { await workspace.train(datasetRepo: datasetRepo) }
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start training (⌘↩)")
                .disabled(workspace.isBusy || workspace.isTraining || !workspace.hasRunningPod || datasetRepo.isEmpty)
            }
            if !workspace.repeatSourceRunID.isEmpty {
                StudioNotice(repeatedRun?.datasetRevision == nil
                    ? "Saved settings are loaded. This run did not record a dataset revision; "
                    + "the current remote dataset will be used."
                    : "The next run repeats a saved dataset revision. Settings above remain editable.")
                Button("Use this project's current dataset instead") {
                    session.useCurrentTrainingDataset()
                }
            }
            Divider()
            RunHistoryView(session: session, workspace: workspace)
        }
    }

    private var advancedTraining: some View {
        Form {
            Picker("Training resolution", selection: $workspace.resolution) {
                ForEach(GPUWorkspace.resolutionChoices, id: \.self) { Text("\($0) px").tag($0) }
            }
            .help("Sets photo training and generated-output resolution. Video dimensions come from approved clips.")
            Stepper("LoRA rank: \(workspace.rank)", value: $workspace.rank, in: 1 ... 128)
                .help("How much detail the small trained add-on can hold. Higher values use more memory.")
            TextField("Learning rate", value: $workspace.learningRate, format: .number)
                .help("How much the model changes at each step. Keep the default for your first run.")
            TextField("Triggers", text: $workspace.triggerWords)
            TextField("Caption profile", text: $workspace.profile)
            TextField("Training seed", value: $workspace.seed, format: .number)
            if workspace.datasetContainsVideo, workspace.trainer == "ltx" {
                Text(
                    "Video training uses every frame at the dimensions and rate approved in Images. To change a "
                        + "clip's dimensions or length, approve its segment again, then caption and publish it. "
                        + "The trainer refuses hidden cropping or truncation."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            Toggle("Keep a caption model on GPU 0 while training", isOn: $workspace.keepCaptionServer)
            if workspace.keepCaptionServer { TextField("Caption model", text: $workspace.captionModel) }
        }.formStyle(.columns)
    }

    private var repeatedRun: TrainingRun? {
        workspace.runHistory.first { $0.runID == workspace.repeatSourceRunID }
    }

    private var trainingDatasetRepo: String {
        repeatedRun?.datasetRepo ?? datasetRepo
    }

    private var trainingDatasetRevision: String? {
        if let repeatedRun { return repeatedRun.datasetRevision }
        return workspace.datasetRevision.isEmpty ? nil : workspace.datasetRevision
    }

    // MARK: Monitor

    /// Each tab gets the full height below the picker; nothing scrolls inside another scroll view.
    private var monitor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    monitorPicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                    monitorPicker.pickerStyle(.menu).frame(maxWidth: 240)
                }
                Spacer(minLength: 0)
                Button("Refresh progress", systemImage: "arrow.clockwise") { Task { await workspace.refresh() } }
                    .disabled(workspace.isBusy || workspace.isStopping)
                    .keyboardShortcut("r", modifiers: .command)
            }
            switch session.monitorTab {
            case .progress: ScrollView { progress.padding(.bottom, 12) }
            case .tensorBoard: tensorBoard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .log: log
            case .results: ScrollView { GenerationView(workspace: workspace).padding(.bottom, 12) }
            case .runs: ScrollView { RunHistoryView(session: session, workspace: workspace).padding(.bottom, 12) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var monitorPicker: some View {
        Picker("Monitor", selection: Bindable(session).monitorTab) {
            ForEach(MonitorTab.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    @ViewBuilder private var tensorBoard: some View {
        if workspace.demoMode {
            ContentUnavailableView(
                "TensorBoard connects to a real training run",
                systemImage: "chart.xyaxis.line",
                description: Text("The offline demo uses the Progress tab. No training server is contacted.")
            )
        } else if !workspace.hasRunningPod || workspace.tensorBoardURL == nil {
            ContentUnavailableView(
                "No running training computer",
                systemImage: "server.rack",
                description: Text("Rent a computer and start training to view its detailed TensorBoard charts.")
            )
        } else if let url = workspace.tensorBoardURL {
            TensorBoardView(url: url, token: workspace.agentToken)
        }
    }

    private var log: some View {
        ScrollView {
            Text(workspace.logs.isEmpty ? "Training logs will appear here as the run progresses." : workspace.logs)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Training log")
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Training") {
                LabeledContent("Status", value: workspace.trainingState.capitalized).font(.headline)
                if workspace.points.isEmpty {
                    ContentUnavailableView(
                        "Your learning curve will appear here",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Start a run from Training, then return here to see its progress.")
                    )
                } else {
                    Chart(workspace.points) { point in
                        LineMark(x: .value("Training step", point.step), y: .value("Training loss", point.loss))
                            .foregroundStyle(StudioStyle.accent)
                    }
                    .chartXAxisLabel("Training step").chartYAxisLabel("Loss")
                    .frame(minHeight: 200, idealHeight: 260)
                    Text("Loss measures fit to these examples. A lower curve alone does not prove better pictures.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }
            Divider()
            TrainingResultSection(state: workspace.result?.state, busy: workspace.isBusy) {
                Task { await workspace.retrieveResult() }
            }
        }
    }
}

struct TrainingResultSection: View {
    let state: TrainingResult.State?
    let busy: Bool
    let retrieve: () -> Void

    var body: some View {
        StudioSection(title: "Your trained model") {
            switch state {
            case nil, .training?:
                Text("When training finishes, the model is uploaded to your Hugging Face repository, or saved in "
                    + "this project's results folder if you have no Hugging Face token.")
                    .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            case .pending?:
                StudioNotice(
                    "The trained model is still only on the rented computer's storage. Retrieve it before you "
                        + "stop the computer.",
                    symbol: "exclamationmark.triangle"
                )
                HStack(spacing: 12) {
                    Button("Retrieve now", systemImage: "arrow.down.circle", action: retrieve)
                        .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Retrieve the trained model (⌘↩)")
                        .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            case let .pushed(repo)?:
                Label("Pushed to \(repo)", systemImage: "checkmark.circle").font(.headline)
                if let url = URL(string: "https://huggingface.co/\(repo)") {
                    Link("Open on Hugging Face", destination: url)
                }
            case let .saved(folder)?:
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                Label("Saved to \(url.lastPathComponent)", systemImage: "checkmark.circle").font(.headline)
                    .help(folder)
                Text(folder).font(.callout).foregroundStyle(StudioStyle.supportingText).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .failed?:
                Label(
                    "The run ended without a trained model. Read the training log for the cause.",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}

extension StudioSession {
    /// Stop everything, warning first when a trained model has been neither pushed nor saved.
    func requestStopEverything() {
        Task {
            var discardingPendingResult = false
            if gpu.resultNeedsSaving {
                switch await ask(.stopWithPendingResult) {
                case .confirm:
                    await gpu.retrieveResult()
                    guard !gpu.resultNeedsSaving else { return }
                case .alternate: discardingPendingResult = true
                case .cancel: return
                }
            }
            await leaveComputerRunning()
            await gpu.stopEverything(discardingPendingResult: discardingPendingResult)
        }
    }
}
