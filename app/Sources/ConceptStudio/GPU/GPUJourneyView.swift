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
    @State private var confirmDiscardingTermination = false
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
                "Removing deletes this computer and its pod disk. Separate network storage remains. "
                    + workspace.outputCustodyExplanation
            )
        }
        .confirmationDialog(
            "Remove this computer and delete its unsaved outputs?",
            isPresented: $confirmDiscardingTermination
        ) {
            Button("Remove and delete outputs", role: .destructive) {
                Task { await workspace.terminate(discardingUndeliveredOutputs: true) }
            }
        } message: {
            Text("These are only on this computer's pod disk and cannot be recovered after removal: "
                + workspace.undeliveredPodOutputs.joined(separator: ", ") + ".")
        }
    }

    // MARK: GPU pods

    private var pods: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(
                title: "Choose a training computer",
                subtitle: workspace.computerSubtitle
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
                title: "Training storage",
                subtitle: "Choose reusable network storage or a disk that stays with this computer. "
                    + "Storage is billed separately, including while stopped."
            ) {
                Form {
                    Picker("Saved storage", selection: Binding(
                        get: { workspace.selectedVolume },
                        set: { workspace.chooseStorage($0) }
                    )) {
                        Text("No saved storage · use this computer’s disk").tag("")
                        ForEach(workspace.volumes) { volume in
                            Text("\(volume.name) · \(volume.size) GB · \(volume.dataCenter)").tag(volume.id)
                        }
                    }
                    .disabled(workspace.hasRunningPod)
                    .onChange(of: workspace.selectedVolume) { _, _ in workspace.selectAvailableOffer() }
                }.formStyle(.columns)
                if workspace.selectedVolume.isEmpty, !workspace.hasRunningPod {
                    Text("A 300 GB disk stays with this computer. Stopping keeps your training files; "
                        + "removing the computer deletes them. The result is pushed "
                        + "when training finishes if a Hugging Face destination is available, or saved to your Mac. "
                        + "Temporary system files are cleared when the computer restarts.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let volume = workspace.volumes.first(where: { $0.id == workspace.selectedVolume }) {
                    Text("Computer availability is limited to \(volume.dataCenter), where this storage lives.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                if workspace.volumes.isEmpty, !workspace.demoMode,
                   let url = URL(string: "https://console.runpod.io/storage") {
                    Link("Create project storage in RunPod", destination: url)
                }
                if workspace.hasRunningPod {
                    if let storage = workspace.storage {
                        LabeledContent("Workspace used", value: bytes(storage.usedBytes))
                        LabeledContent("Workspace free", value: bytes(storage.freeBytes))
                        LabeledContent("Workspace total", value: bytes(storage.totalBytes))
                        LabeledContent("Dataset copies", value: bytes(storage.datasetsBytes))
                        LabeledContent("Eligible dataset cleanup", value: bytes(storage.reclaimableDatasetBytes))
                    }
                    HStack {
                        Button("Refresh storage usage") { Task { await workspace.refreshStorage() } }
                        Button("Clean completed dataset copies") { Task { await workspace.cleanupDatasets() } }
                    }.disabled(workspace.isBusy || workspace.isStopping)
                    Text("Cleanup keeps active inputs and the last three resumable datasets. "
                        + "Checkpoints, models, generated results and unknown or failed runs stay on storage.")
                        .font(.caption).foregroundStyle(StudioStyle.supportingText)
                }
            }
            Divider()
            spending
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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
                        Text(StudioMoney.perHour(workspace.hasRunningPod
                                ? workspace.pod?.cost ?? workspace.quotedHourlyRate
                                : workspace.saved?.hourlyRate ?? workspace.quotedHourlyRate))
                            .font(.headline).monospacedDigit()
                    }
                }
                if workspace.hasRunningPod {
                    LabeledContent("Whole-computer spending limit") {
                        Text(StudioMoney.format(workspace.activeBudget ?? workspace.budget)).monospacedDigit()
                    }
                    TextField("Raise the limit to (USD)", value: $newBudget, format: .number)
                } else {
                    TextField("Whole-computer GPU budget (USD)", value: $workspace.budget, format: .number)
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
                    Button("Start this stopped computer · last rate "
                        + StudioMoney.perHour(workspace.saved?.hourlyRate ?? 0)) {
                            Task { await workspace.startStoppedComputer() }
                        }.disabled(workspace.isBusy)
                    Text(workspace.outputCustodyExplanation)
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                if workspace.hasUndeliveredPodOutputs, !workspace.hasRunningPod {
                    Text("Unsaved outputs keep this computer from being removed. "
                        + workspace.stoppedPodDiskCostExplanation)
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    Button("Remove anyway and delete these outputs…", role: .destructive) {
                        confirmDiscardingTermination = true
                    }
                    .disabled(workspace.isBusy)
                    .help("Deletes the pod disk with the outputs that were never pushed or saved.")
                } else {
                    Button("Remove computer…", role: .destructive) { confirmTermination = true }
                        .disabled(workspace.hasUndeliveredPodOutputs)
                        .help("Push or save outputs from a pod disk before removing its computer.")
                }
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

    /// The picker and, for a model whose licence notice is on, the notice, a link to the licence and the size of the
    /// first download. All are direct children of the surrounding form, so a model without a notice lays out as a
    /// bare picker.
    @ViewBuilder private var trainerPicker: some View {
        Picker("Training model", selection: Binding(
            get: { workspace.baseModel },
            set: { workspace.chooseTrainingModel($0) }
        )) {
            ForEach(workspace.trainingModelOptions, id: \.tag) { option in
                Text(option.label).tag(option.tag)
            }
        }
        .disabled(workspace.isBusy || workspace.isTraining)
        if let disclosure = workspace.trainingModelDisclosure {
            Text(disclosure.notice).font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            if let link = URL(string: disclosure.licenseURL) {
                Link(disclosure.licenseName, destination: link).font(.callout)
            }
            Text(disclosure.download).font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let note = workspace.exactModelRow?.usageNote {
            Text(note).font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Training

    private var training: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Your training plan") {
                Text(session.trainingPlanExplanation)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(
                    workspace.usesLocalDataset ? "Training inputs" : "Published dataset",
                    value: workspace.usesLocalDataset ? "Included media and saved captions in this project"
                        : trainingDatasetRepo.isEmpty
                        ? "Publish your training media first" : trainingDatasetRepo
                )
                LabeledContent(
                    workspace.usesLocalDataset ? "Transfer" : "Published revision",
                    value: workspace.usesLocalDataset ? "Direct authenticated upload when training starts"
                        : trainingDatasetRevision ?? "Latest revision on first download"
                )
                .font(.callout).textSelection(.enabled)
                Text(workspace.usesLocalDataset
                    ? "Training uploads the included media, selected segments and saved captions "
                    + "directly from this project."
                    : "Training downloads this published dataset. Publish again after changing included media, crops, "
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
                        .disabled(workspace.isBusy || workspace.isTraining)
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
            TrainingInitializationView(workspace: workspace)
            Divider()
            TrainingAidsView(session: session, workspace: workspace)
            StudioSection(title: "Run settings", subtitle: workspace.trainingLengthSubtitle) {
                Form {
                    TextField(workspace.trainingLengthLabel, value: $workspace.steps, format: .number.grouping(.never))
                        .help(workspace.trainingLengthHelp)
                        .disabled(workspace.isBusy || workspace.isTraining)
                }.formStyle(.columns)
                TrainingBudgetView(session: session, workspace: workspace)
                DisclosureGroup("Advanced training controls") {
                    AdvancedTrainingControls(workspace: workspace).padding(.top, 12)
                        .disabled(workspace.isBusy || workspace.isTraining)
                }
                Button("Start training", systemImage: "play.fill") {
                    Task { await workspace.train(datasetRepo: datasetRepo, captureLocal: session.captureTrainingInputs)
                    }
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start training (⌘↩)")
                .disabled(workspace.isBusy || workspace.isTraining || !workspace
                    .hasRunningPod || session.busy || session
                    .editing || (!workspace.usesLocalDataset && datasetRepo.isEmpty))
            }
            if !workspace.repeatSourceRunID.isEmpty {
                StudioNotice(workspace.usesLocalDataset
                    ? "Saved settings are loaded. Training captures the current included media and saved captions."
                    : repeatedRun?.datasetRevision == nil
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
}

extension GPUJourneyView {
    private var progress: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Learning curve") {
                if workspace.runID.isEmpty, let run = workspace.monitoredRun {
                    Text("Most recent saved run · " + run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                if workspace.curveDisplay != .available {
                    ContentUnavailableView(
                        workspace.curveDisplay.title,
                        systemImage: "chart.xyaxis.line",
                        description: Text(workspace.curveDisplay.explanation)
                    )
                    if workspace.curveDisplay == .noRun {
                        Button("Go to Training") { session.step = .training }
                    } else if workspace.curveDisplay == .waiting {
                        if let drawing = workspace.regularizationProgress {
                            ProgressView(value: Double(drawing.ready), total: Double(drawing.planned)) {
                                Text(drawing.text)
                            }.controlSize(.small)
                        } else {
                            ProgressView("Waiting for a training measurement").controlSize(.small)
                        }
                    }
                } else {
                    Chart(workspace.monitoredPoints) { point in
                        LineMark(x: .value("Training step", point.step), y: .value("Training loss", point.loss))
                            .foregroundStyle(StudioStyle.accent)
                    }
                    .chartXAxisLabel("Training step").chartYAxisLabel("Loss")
                    .frame(minHeight: 200, idealHeight: 260)
                    Text(workspace.curveDisplay.explanation)
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }
            Divider()
            TrainingResultSection(state: workspace.monitoredResultState, busy: workspace.isBusy) {
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

extension GPUJourneyView {
    /// Inline status: progress and recoverable states. Blocking failures go to the window alert.
    private var status: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Computer", value: workspace.computerStatus).font(.headline)
                if step == .training || step == .monitor {
                    LabeledContent("Training", value: workspace.trainingStatus)
                }
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
}
