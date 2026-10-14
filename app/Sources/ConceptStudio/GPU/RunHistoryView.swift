import AppKit
import SwiftUI

struct RunHistoryView: View {
    let session: StudioSession
    @Bindable var workspace: GPUWorkspace
    @State private var totalSteps = 400
    @State private var higherRunCap: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Saved training runs", subtitle: "Settings and results stay with this project.") {
                if workspace.runHistory.isEmpty {
                    Text("No training runs yet. When you start one, its settings and results are saved here "
                        + "so you can use them again.")
                        .foregroundStyle(StudioStyle.supportingText)
                } else {
                    Form {
                        Picker("Run", selection: $workspace.selectedHistoryRunID) {
                            ForEach(workspace.runHistory.reversed()) { run in
                                Text("Run \((workspace.runHistory.firstIndex { $0.runID == run.runID } ?? 0) + 1) · "
                                    + run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .tag(run.runID)
                            }
                        }
                    }.formStyle(.columns)
                    if let run = workspace.runHistory.first(where: { $0.runID == workspace.selectedHistoryRunID }) {
                        runDetails(run)
                    }
                }
            }
        }
        .onChange(of: workspace.selectedHistoryRunID, initial: true) { _, id in
            if let run = workspace.runHistory.first(where: { $0.runID == id }) {
                totalSteps = max(run.targetSteps, run.latestStep) + 200
            }
        }
    }

    private func runDetails(_ run: TrainingRun) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Starting model", value: run.baseModel).textSelection(.enabled)
            LabeledContent("Dataset", value: run.datasetDescription).textSelection(.enabled)
            LabeledContent("Training length", value: "\(run.targetSteps) steps")
            ForEach(run.trainingAidSummary, id: \.self) { line in
                Text(line).textSelection(.enabled)
            }
            LabeledContent("Result", value: run.resultExplanation)
            if let cost = run.estimatedGPUCostUSD {
                LabeledContent("Run GPU cost including continuations", value: StudioMoney.format(cost))
            }
            savedBudget(run)
            if let rate = run.hourlyRateUSD {
                Text(
                    "Last computer rate: \(StudioMoney.perHour(rate)). Estimates exclude separately billed storage."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            HStack {
                Button("Use these settings for a new run", systemImage: "arrow.clockwise") {
                    workspace.repeatSettings(from: run)
                    if workspace.repeatSourceRunID == run.runID { session.step = .training }
                }.disabled(workspace.isBusy || workspace.isTraining)
                Button("Find saved checkpoints", systemImage: "arrow.down.circle") {
                    Task { await workspace.refreshRunFiles(run.runID) }
                }.disabled(workspace.isBusy || !workspace.hasRunningPod)
            }
            Text(run.newRunExplanation)
                .font(.callout).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Continue this run").font(.headline)
            Text("A checkpoint is a saved version of the model during training. Continuing resumes the latest "
                + "checkpoint on the same saved storage, keeping this run's data and training settings.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            StudioTermsHelp(terms: [.checkpoint, .resume, .datasetRevision, .warmStart, .trainingRecipe])
            if run.localInputDigest != nil {
                Text("For a direct upload, the included media, saved captions and job must still match this run. "
                    + "Changed inputs need a new run instead.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            Form {
                TextField("Continue to total steps", value: $totalSteps, format: .number)
                    .help("The total includes training steps already completed; it is not the number of extra steps.")
            }.formStyle(.columns)
            Button("Continue training this run", systemImage: "play.circle") {
                Task { await workspace.resumeRun(
                    run,
                    totalSteps: totalSteps,
                    captureLocal: session.captureTrainingInputs
                ) }
            }
            .disabled(workspace.isBusy || workspace.isTraining || !workspace.hasRunningPod
                || session.busy || session.editing || run.checkpoints.isEmpty || totalSteps <= run.latestStep)
            .help("Find the checkpoints on this run's storage first. Continuing keeps its original data and settings.")
            if !run.checkpoints.isEmpty {
                Text("\(run.checkpoints.count) saved checkpoints found for this run.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            if !workspace.hasRunningPod || workspace.currentVolumeID != run.volumeID {
                Text("Connect a running computer to this run's saved storage to find checkpoints or continue training.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            exactDetails(run)
            Divider()
            HStack {
                Button("Save trained model to this Mac", systemImage: "arrow.down.doc") {
                    Task { await workspace.downloadRun(run) }
                }
                .disabled(workspace.isBusy || workspace.isStopping || !run.hasFinishedModel)
                .help("Downloads this run's trained model and run files from its saved storage, verifying each file.")
                if let folder = run.localSavedFolder {
                    Button("Reveal saved folder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                    }.help("Shows this run's downloaded model folder in Finder.")
                }
            }
            Text("Saving requires a running computer connected to this run's saved storage.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func savedBudget(_ run: TrainingRun) -> some View {
        if let cap = run.gpuBudgetUSD {
            LabeledContent("This run's budget", value: StudioMoney.format(cap))
            HStack {
                TextField("Raise this run's budget to (USD)", value: $higherRunCap, format: .number)
                Button("Raise run budget…") {
                    Task {
                        guard let target = higherRunCap,
                              await session.ask(.raiseBudget(from: cap, to: target, hourlyRate: run.hourlyRateUSD))
                              == .confirm else { return }
                        if workspace.raiseRunBudget(to: target, runID: run.runID) { higherRunCap = nil }
                    }
                }.disabled((higherRunCap ?? 0) <= cap || workspace.isBusy)
            }
        }
    }

    private func exactDetails(_ run: TrainingRun) -> some View {
        DisclosureGroup("Exact run details") {
            LabeledContent("Run ID", value: run.runID).textSelection(.enabled)
            LabeledContent("Trainer", value: run.trainer)
            LabeledContent("LoRA rank", value: "\(run.rank)")
            LabeledContent(
                run.localInputDigest == nil ? "Dataset revision" : "Local input digest",
                value: run.localInputDigest ?? run.datasetRevision ?? "Not recorded"
            ).textSelection(.enabled)
            LabeledContent("Saved storage ID", value: run.volumeID).textSelection(.enabled)
        }.font(.callout)
    }
}
