import AppKit
import SwiftUI

struct RunHistoryView: View {
    let session: StudioSession
    @Bindable var workspace: GPUWorkspace
    @State private var totalSteps = 400

    var body: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(title: "Saved training runs", subtitle: "Settings and results stay with this project.") {
                if workspace.runHistory.isEmpty {
                    Text("Start a training run to save its dataset revision, settings, checkpoints and result here.")
                        .foregroundStyle(StudioStyle.supportingText)
                } else {
                    Form {
                        Picker("Run", selection: $workspace.selectedHistoryRunID) {
                            ForEach(workspace.runHistory.reversed()) { run in
                                Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.runID)")
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
            LabeledContent("Dataset", value: run.datasetRepo).textSelection(.enabled)
            LabeledContent("Dataset revision", value: run.datasetRevision ?? "Not recorded by this agent")
                .font(.callout).textSelection(.enabled)
            LabeledContent("Training", value: "\(run.targetSteps) total steps · rank \(run.rank) · \(run.trainer)")
            LabeledContent("Result", value: run.result?.summary ?? "Run submitted")
            if let cost = run.estimatedGPUCostUSD {
                LabeledContent("Estimated GPU cost", value: StudioMoney.format(cost))
            }
            if let rate = run.hourlyRateUSD {
                Text(
                    "Last computer rate: \(StudioMoney.perHour(rate)). Estimates exclude separately billed storage."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            HStack {
                Button("Load settings for repeat", systemImage: "arrow.clockwise") {
                    workspace.repeatSettings(from: run)
                    if workspace.repeatSourceRunID == run.runID { session.step = .training }
                }.disabled(workspace.isBusy || workspace.isTraining)
                Button("Refresh checkpoints", systemImage: "arrow.down.circle") {
                    Task { await workspace.refreshRunFiles(run.runID) }
                }.disabled(workspace.isBusy || !workspace.hasRunningPod)
            }
            Text((run.datasetRevision == nil
                    ? "No dataset revision was recorded. Repeat loads these settings using the current remote dataset. "
                    : "Repeat loads these settings and the recorded dataset revision. ")
                +
                "Edit the settings, then start a new run. Resume continues the latest checkpoint on the same storage.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Resume to total steps", value: $totalSteps, format: .number)
            }.formStyle(.columns)
            Button("Resume latest checkpoint", systemImage: "play.circle") {
                Task { await workspace.resumeRun(run, totalSteps: totalSteps) }
            }
            .disabled(workspace.isBusy || workspace.isTraining || !workspace.hasRunningPod
                || run.checkpoints.isEmpty || totalSteps <= run.latestStep)
            .help("Keeps this run's dataset, model, rank and preprocessing. Refresh checkpoints on its storage first.")
            if !run.checkpoints.isEmpty {
                Text("\(run.checkpoints.count) checkpoints available on storage \(run.volumeID).")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
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
            Text("Saving requires a connected computer on this run's storage. "
                + "Its published Hub status is kept alongside the local copy.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
        }
    }
}
