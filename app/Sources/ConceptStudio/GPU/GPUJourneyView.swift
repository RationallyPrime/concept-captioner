import Charts
import SwiftUI
import WebKit

struct GPUJourneyView: View {
    @Bindable var workspace: GPUWorkspace
    let step: StudioStep
    let datasetRepo: String
    @State private var confirmTermination = false
    @State private var monitorTab = "Progress"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if workspace.demoMode {
                Label("Demo · simulated computer, simulated prices, no charges", systemImage: "sparkles")
                    .foregroundStyle(.orange)
            }
            HStack {
                Label(workspace.pod?.status ?? "No rented computer", systemImage: "server.rack")
                Spacer()
                if workspace.hasRunningPod {
                    Text("Estimated GPU spend: \(workspace.elapsedCost, format: .currency(code: "USD"))")
                        .monospacedDigit()
                    Button("Stop everything", role: .destructive) { Task { await workspace.stopEverything() } }
                }
            }
            Text(workspace.message).foregroundStyle(.secondary).textSelection(.enabled)
            if workspace.isBusy { ProgressView().controlSize(.small) }
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
                Picker("GPUs", selection: $workspace.gpuCount) {
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
                Text("Showing GPUs with at least \(GPUWorkspace.minimumGPUMemoryGB) GB to fit the included models.")
                    .font(.callout).foregroundStyle(.secondary)
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
                .font(.callout).foregroundStyle(.secondary)
                if workspace.volumes.isEmpty, !workspace.demoMode {
                    Link(
                        "Create project storage in RunPod",
                        destination: URL(string: "https://console.runpod.io/storage")!
                    )
                }
            }
            Section("Control your spending") {
                Text("Computer estimate: \(workspace.quotedHourlyRate, format: .currency(code: "USD")) per hour")
                    .font(.headline)
                TextField("Stop at this GPU budget (USD)", value: $workspace.budget, format: .number)
                    .disabled(workspace.hasRunningPod)
                Stepper("Stop after \(workspace.idleMinutes) idle minutes", value: $workspace.idleMinutes, in: 1 ... 60)
                Text(
                    "Keep ConceptStudio open to enforce your budget and idle limit. Stop also works if the agent fails."
                )
                .font(.callout).foregroundStyle(.secondary)
                Button("Rent computer · $\(workspace.quotedHourlyRate, specifier: "%.2f")/hour") {
                    Task { await workspace.rent() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspace.isBusy || workspace.pod != nil || workspace.quotedHourlyRate <= 0)
                if workspace.pod != nil {
                    if !workspace.hasRunningPod {
                        Text("Remove this stopped computer before renting another. Saved network storage remains.")
                            .font(.callout).foregroundStyle(.secondary)
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
                Text(
                    "Some models require you to accept their license in your Hugging Face account before training."
                )
                .font(.callout).foregroundStyle(.secondary)
                TextField("Save trained model to (your-name/model-name)", text: $workspace.outputRepo)
            }
            Section("Run settings") {
                Stepper("Training steps: \(workspace.steps)", value: $workspace.steps, in: 25 ... 10000, step: 25)
                Text(
                    "More steps give more practice. Start short and review the result before spending more."
                )
                .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Advanced training controls") {
                    Stepper("LoRA rank: \(workspace.rank)", value: $workspace.rank, in: 1 ... 128)
                    TextField("Learning rate", value: $workspace.learningRate, format: .number)
                    TextField("Learning words (triggers)", text: $workspace.triggerWords)
                    TextField("Caption profile", text: $workspace.profile)
                    Toggle("Keep a caption model on GPU 0 while training", isOn: $workspace.keepCaptionServer)
                    if workspace.keepCaptionServer { TextField("Caption model", text: $workspace.captionModel) }
                }
                Button("Start training") { Task { await workspace.train(datasetRepo: datasetRepo) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.isBusy || workspace.isTraining || !workspace.hasRunningPod || datasetRepo
                        .isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private var monitor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Monitor", selection: $monitorTab) {
                Text("Progress").tag("Progress")
                Text("TensorBoard").tag("TensorBoard")
            }.pickerStyle(.segmented)
            if monitorTab == "TensorBoard", let url = workspace.tensorBoardURL, !workspace.demoMode {
                TensorBoardView(url: url, token: workspace.agentToken).frame(minHeight: 380)
            } else {
                LabeledContent("Training", value: workspace.trainingState)
                if workspace.points.isEmpty {
                    ContentUnavailableView(
                        "Your curve will appear here",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Start a run, then watch its learning progress here.")
                    )
                } else {
                    Chart(workspace.points) { point in
                        LineMark(x: .value("Training step", point.step), y: .value("Training loss", point.loss))
                    }
                    .chartXAxisLabel("Training step").chartYAxisLabel("Loss")
                    .frame(height: 230)
                    Text(
                        "Loss measures fit to these examples. A lower curve alone does not prove better pictures."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView { Text(workspace.logs.isEmpty ? "Training logs will appear here." : workspace.logs)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }.frame(minHeight: 100, maxHeight: 180)
            }
            HStack {
                Button("Refresh progress") { Task { await workspace.refresh() } }
                Button("Collect LoRA to Hugging Face") { Task { await workspace.publishResult() } }
                    .disabled(workspace.isBusy || workspace.runID.isEmpty || workspace.outputRepo.isEmpty)
                if !workspace.outputRepo.isEmpty,
                   let url = URL(string: "https://huggingface.co/\(workspace.outputRepo)") {
                    Link("Open model repository", destination: url)
                }
            }
        }
    }
}

private struct TensorBoardView: NSViewRepresentable {
    let url: URL
    let token: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        view.load(request)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
