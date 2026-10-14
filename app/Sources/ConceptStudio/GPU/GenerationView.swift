import AppKit
import AVKit
import SwiftUI

struct GenerationView: View {
    @Bindable var workspace: GPUWorkspace
    @State private var checkpointPath = ""
    @State private var prompts = ""
    @State private var seedText = "42"
    @State private var inferenceSteps = 20
    @State private var videoFrames = 49

    private var selectedRun: TrainingRun? {
        workspace.runHistory.first { $0.runID == workspace.selectedHistoryRunID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(
                title: "Generate with your trained model",
                subtitle:
                "Compare the starting model with one saved LoRA checkpoint using the same prompts and seeds."
            ) {
                if workspace.demoMode {
                    StudioNotice("The demo simulates training settings and loss. It creates no real trained weights "
                        + "or generated comparisons. Open your own project to generate with a collected model.")
                } else if workspace.runHistory.isEmpty {
                    Text(
                        "Train and collect a model first. Generated pictures and videos appear here after a real run."
                    )
                    .foregroundStyle(StudioStyle.supportingText)
                } else {
                    controls
                }
            }
            Divider()
            StudioSection(title: "Saved comparisons") {
                if workspace.generations.isEmpty {
                    Text(
                        "No generated comparison yet. Its files will be downloaded into this project's results folder."
                    )
                    .foregroundStyle(StudioStyle.supportingText)
                }
                ForEach(workspace.generations.reversed()) { comparison in
                    comparisonResult(comparison)
                    Divider()
                }
            }
        }
        .onChange(of: workspace.selectedHistoryRunID, initial: true) { _, _ in chooseCheckpoint() }
        .onChange(of: selectedRun?.checkpoints) { _, _ in chooseCheckpoint() }
        .onAppear { if prompts.isEmpty { prompts = workspace.triggerWords } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Training run", selection: $workspace.selectedHistoryRunID) {
                    ForEach(workspace.runHistory.reversed()) { Text($0.runID).tag($0.runID) }
                }
                Picker("LoRA checkpoint", selection: $checkpointPath) {
                    Text("Refresh checkpoints to choose").tag("")
                    ForEach(selectedRun?.checkpoints ?? [], id: \.path) { Text($0.path).tag($0.path) }
                }
                TextField("Seeds (comma separated)", text: $seedText)
                Stepper("Generation steps: \(inferenceSteps)", value: $inferenceSteps, in: 1 ... 100)
                if let run = selectedRun, run.generatesVideo {
                    let rate = run.generationFrameRate
                    Picker("Generated output at \(rate) fps", selection: $videoFrames) {
                        ForEach(run.generationFrameChoices, id: \.self) { frames in
                            if frames == 1 { Text("Still image").tag(frames) } else {
                                Text("\(frames) frames · \(Double(frames) / Double(rate), specifier: "%.1f") seconds")
                                    .tag(frames)
                            }
                        }
                    }
                }
            }.formStyle(.columns)
            if let run = selectedRun {
                Button("Refresh checkpoints on saved storage", systemImage: "arrow.clockwise") {
                    Task { await workspace.refreshRunFiles(run.runID) }
                }.disabled(workspace.isBusy || !workspace.hasRunningPod)
                if !run.supportsGeneration {
                    StudioNotice(
                        "Generation supports \(workspace.modelTable.generationModelList). "
                            + "This run uses \(run.baseModel)."
                    )
                }
                if run.generatesVideo {
                    Text("Both outputs use the selected frame count at \(run.generationFrameRate) fps "
                        + "and the same resolution and settings. "
                        + "H3 can generate still images or videos even when its LoRA was trained on still images.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }
            Text("Prompts · one per line").font(.headline)
            TextEditor(text: $prompts).frame(minHeight: 90, idealHeight: 120)
                .border(Color(nsColor: .separatorColor)).accessibilityLabel("Generation prompts, one per line")
            Text("Use the concept trigger in your prompt. Enter up to six prompts and four seeds. "
                + "Generation uses the rented GPU; the app's spending limit and Stop controls remain active.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            StudioTermsHelp(terms: [.prompt, .seed, .checkpoint, .fps, .resolution, .lora])
            Button("Generate base and LoRA comparison", systemImage: "photo.on.rectangle.angled") {
                generate()
            }
            .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
            .disabled(workspace.isBusy || workspace.isTraining || !workspace.hasRunningPod
                || selectedRun?.supportsGeneration != true || checkpointPath.isEmpty || workspace.demoMode)
            if let generation = workspace.generation, generation.state != .saved {
                Text(generation.summary).font(.callout).foregroundStyle(StudioStyle.supportingText)
                if generation.state == .pending {
                    Button("Download generated outputs") { Task { await workspace.retrieveResult() } }
                        .disabled(workspace.isBusy)
                }
            }
        }
    }

    private func chooseCheckpoint() {
        checkpointPath = RunArtifacts.newest(selectedRun?.checkpoints ?? [])?.path ?? ""
        if let run = selectedRun, run.generatesVideo, !run.generationFrameChoices.contains(videoFrames) {
            videoFrames = run.defaultGenerationFrames
        }
    }

    private func generate() {
        guard let run = selectedRun, let checkpoint = run.checkpoints.first(where: { $0.path == checkpointPath }) else {
            return
        }
        let parts = seedText.split(separator: ",", omittingEmptySubsequences: false)
        let seeds = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard seeds.count == parts.count else {
            workspace.message = "Enter whole-number seeds separated by commas."
            return
        }
        let promptLines = prompts.split(separator: "\n").map(String.init)
        Task { await workspace.generateComparison(
            run: run,
            checkpoint: checkpoint,
            prompts: promptLines,
            seeds: seeds,
            inferenceSteps: inferenceSteps,
            videoFrames: videoFrames
        ) }
    }

    @ViewBuilder private func comparisonResult(_ comparison: GeneratedComparison) -> some View {
        Text("\(comparison.sourceRunID) · \(comparison.checkpoint)").font(.headline).textSelection(.enabled)
        Text(comparison.summary).font(.callout).foregroundStyle(StudioStyle.supportingText)
        Button("Read generation log", systemImage: "doc.text") {
            Task {
                await workspace.perform {
                    guard let agent = workspace.agent, workspace.hasRunningPod,
                          comparison.volumeID == workspace.currentVolumeID else {
                        throw StudioError.message("Connect this comparison's saved storage to read its log.")
                    }
                    workspace.logs = try await agent.runLog(runID: comparison.runID)
                    workspace.message = "Generation log loaded into the Log tab."
                }
            }
        }.disabled(workspace.isBusy || !workspace.hasRunningPod)
        if let manifest = workspace.comparisonManifest(comparison) {
            ForEach(manifest.pairs) { pair in
                VStack(alignment: .leading, spacing: 8) {
                    Text(pair.prompt).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("Seed \(pair.seed)").font(.caption).monospacedDigit()
                    HStack(alignment: .top, spacing: 16) {
                        generatedMedia(pair.basePath, comparison: comparison, label: "Base model")
                        generatedMedia(pair.loraPath, comparison: comparison, label: "With LoRA")
                    }
                }.padding(.vertical, 8)
            }
        }
        if let folder = comparison.folder {
            Button("Reveal downloaded files", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            }
        }
    }

    private func generatedMedia(_ path: String, comparison: GeneratedComparison, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.bold())
            if let url = workspace.comparisonFile(path, in: comparison) {
                if url.pathExtension == "mp4" {
                    GeneratedVideo(url: url).frame(height: 220)
                } else {
                    PhotoView(url: url).frame(height: 220)
                }
            } else {
                Text("This output is not downloaded.").foregroundStyle(StudioStyle.supportingText).frame(height: 120)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneratedVideo: View {
    @State private var player: AVPlayer
    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player).onDisappear { player.pause() }
    }
}
