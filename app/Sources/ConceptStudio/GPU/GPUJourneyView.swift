import Charts
import SwiftUI

struct GPUJourneyView: View {
    @Bindable var workspace: GPUWorkspace
    let step: StudioStep
    let datasetRepo: String
    @State private var confirmTermination = false
    @State private var monitorTab = "Progress"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(workspace.pod?.status ?? "No rented computer", systemImage: "server.rack")
                        .font(.headline)
                    Text(workspace.message).font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if workspace.isBusy || workspace.isStopping { ProgressView().controlSize(.small) }
                if workspace.hasRunningPod {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("GPU spend: \(workspace.elapsedCost, format: .currency(code: "USD"))")
                            .font(.headline).monospacedDigit()
                        Button(workspace.isStopping ? "Stopping…" : "Stop everything") {
                            Task { await workspace.stopEverything() }
                        }.disabled(workspace.isStopping)
                    }
                }
            }
            if workspace.demoMode {
                StudioNotice(
                    "Demo computer and prices. No computer is rented and there are no charges.",
                    symbol: "leaf"
                )
            }
            switch step {
            case .pods: pods
            case .training: training
            case .monitor: monitor
            default: EmptyView()
            }
        }
        .task { if workspace.offers.isEmpty { await workspace.refreshOffers() } }
        .confirmationDialog("Permanently remove this computer?", isPresented: $confirmTermination) {
            Button("Remove computer", role: .destructive) { Task { await workspace.terminate() } }
        } message: {
            Text(
                "Stopping clears temporary files. Removing deletes the computer. Saved network storage remains."
            )
        }
    }

    private var pods: some View {
        Form {
            Section("Choose a training computer") {
                Picker("Prepare it for", selection: $workspace.trainer) {
                    Text("AI Toolkit · image model").tag("aitoolkit")
                    Text("LTX · image and video model").tag("ltx")
                }
                .disabled(workspace.hasRunningPod || workspace.isBusy)
                Picker("Number of GPUs", selection: $workspace.gpuCount) {
                    Text("1 · caption, then train").tag(1)
                    Text("2 · caption and train together").tag(2)
                    Text("4 · caption and train together").tag(4)
                }
                .disabled(workspace.hasRunningPod || workspace.isBusy)
                .onChange(of: workspace.gpuCount) { _, _ in Task { await workspace.refreshOffers() } }
                Picker("Computer", selection: $workspace.selectedGPU) {
                    ForEach(workspace.availableOffers) { offer in
                        Text(offer.summary)
                            .tag(offer.id)
                    }
                }
                .disabled(workspace.hasRunningPod)
                Text("A GPU is the part that does the training. These have at least "
                    + "\(GPUWorkspace.minimumGPUMemoryGB) GB of memory to fit the included models.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                Button("Refresh prices and availability") { Task { await workspace.refreshOffers() } }
                    .disabled(workspace.isBusy)
            }
            Section("Keep your work") {
                Picker("Saved storage", selection: $workspace.selectedVolume) {
                    ForEach(workspace.volumes) { volume in
                        Text("\(volume.name) · \(volume.size) GB · \(volume.dataCenter)").tag(volume.id)
                    }
                }
                .disabled(workspace.hasRunningPod)
                .onChange(of: workspace.selectedVolume) { _, _ in workspace.selectAvailableOffer() }
                Text(
                    "Network storage keeps checkpoints after stopping. It is billed separately, even when stopped."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                if workspace.volumes.isEmpty, !workspace.demoMode {
                    Link(
                        "Create project storage in RunPod",
                        destination: URL(string: "https://console.runpod.io/storage")!
                    )
                }
            }
            Section("Control your spending") {
                if workspace.quotedHourlyRate > 0 {
                    LabeledContent("Computer price") {
                        Text("\(workspace.quotedHourlyRate, format: .currency(code: "USD")) / hour")
                            .font(.headline).monospacedDigit()
                    }
                } else {
                    Text("Choose an available computer to see its price.").foregroundStyle(StudioStyle.supportingText)
                }
                TextField("Stop at this GPU budget (USD)", value: $workspace.budget, format: .number)
                    .disabled(workspace.hasRunningPod)
                Stepper("Stop after \(workspace.idleMinutes) idle minutes", value: $workspace.idleMinutes, in: 1 ... 60)
                Text(
                    "Keep ConceptStudio open to enforce your budget and idle limit. Stop also works if the agent fails."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                Button(workspace.quotedHourlyRate > 0
                    ? "Rent computer · $\(workspace.quotedHourlyRate, specifier: "%.2f")/hour"
                    : "Choose a computer first") {
                        Task { await workspace.rent() }
                    }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .disabled(workspace.isBusy || workspace.pod != nil || workspace.quotedHourlyRate <= 0)
                if workspace.pod != nil {
                    if !workspace.hasRunningPod {
                        Text("Remove this stopped computer before renting another. Saved network storage remains.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    Button("Remove computer…", role: .destructive) { confirmTermination = true }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var training: some View {
        Form {
            Section("Your training plan") {
                Text(workspace.plan?
                    .explanation ??
                    "Rent a computer first. Its control agent will tell us which GPUs each service can use.")
                Button("Refresh the plan") { Task { await workspace.refresh() } }
                Text("Dataset: \(datasetRepo.isEmpty ? "Publish your images first" : datasetRepo)")
                Picker("Trainer", selection: $workspace.trainer) {
                    Text("AI Toolkit · image model").tag("aitoolkit")
                    Text("LTX · image and video model").tag("ltx")
                }
                .disabled(workspace.hasRunningPod || workspace.isBusy)
                TextField("Starting model", text: $workspace.baseModel)
                    .help("The existing model your photos will teach. Keep the included choice for your first run.")
                Text(
                    "Some models require you to accept their license in your Hugging Face account before training."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                TextField("Save trained model to (your-name/model-name)", text: $workspace.outputRepo)
            }
            Section("Run settings") {
                Stepper("Training steps: \(workspace.steps)", value: $workspace.steps, in: 25 ... 10000, step: 25)
                Text(
                    "More steps give more practice. Start short and review the result before spending more."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                DisclosureGroup("Advanced training controls") {
                    Stepper("LoRA rank: \(workspace.rank)", value: $workspace.rank, in: 1 ... 128)
                        .help("How much detail the small trained add-on can hold. Higher values use more memory.")
                    TextField("Learning rate", value: $workspace.learningRate, format: .number)
                        .help(
                            "How much the model changes at each step. Keep the default for your first run."
                        )
                    TextField("Learning words (triggers)", text: $workspace.triggerWords)
                    TextField("Caption profile", text: $workspace.profile)
                    Toggle("Keep a caption model on GPU 0 while training", isOn: $workspace.keepCaptionServer)
                    if workspace.keepCaptionServer { TextField("Caption model", text: $workspace.captionModel) }
                }
                Button("Start training") { Task { await workspace.train(datasetRepo: datasetRepo) } }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .disabled(workspace.isBusy || workspace.isTraining || !workspace.hasRunningPod || datasetRepo
                        .isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private var monitor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Monitor", selection: $monitorTab) {
                    Text("Progress").tag("Progress")
                    Text("TensorBoard").tag("TensorBoard")
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { monitorActions }
                    VStack(alignment: .leading, spacing: 12) { monitorActions }
                }
                if monitorTab == "TensorBoard" {
                    tensorBoard
                } else {
                    progress
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
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
            Text("TensorBoard shows detailed measurements from your training computer.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            TensorBoardView(url: url, token: workspace.agentToken).frame(minHeight: 360)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Training status", value: workspace.trainingState)
                .font(.headline)
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
                .frame(height: 220)
                Text("Loss measures fit to these examples. A lower curve alone does not prove better pictures.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            StudioSection(title: "Training log", subtitle: "Details from the rented computer as the run progresses.") {
                ScrollView {
                    Text(workspace.logs.isEmpty ? "Training logs will appear here." : workspace.logs)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(minHeight: 100, maxHeight: 160)
                .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Training log")
            }
        }
    }

    @ViewBuilder private var monitorActions: some View {
        Button("Refresh progress") { Task { await workspace.refresh() } }
            .disabled(workspace.isBusy || workspace.isStopping)
        Button("Save trained model to Hugging Face") { Task { await workspace.publishResult() } }
            .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
            .disabled(workspace.isBusy || workspace.runID.isEmpty || workspace.outputRepo.isEmpty)
        if !workspace.outputRepo.isEmpty,
           let url = URL(string: "https://huggingface.co/\(workspace.outputRepo)") {
            Link("Open model repository", destination: url)
        }
    }
}
