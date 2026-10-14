import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TrainingInitializationView: View {
    @Bindable var workspace: GPUWorkspace

    var body: some View {
        ForEach(workspace.modelTable.nativeRecipeRows) { row in
            recipeImport(row)
        }
    }

    private func recipeImport(_ row: ModelRow) -> some View {
        DisclosureGroup("Start a new \(row.shortName) run from existing LoRA weights") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import the native AI Toolkit recipe that trained the LoRA, then its .safetensors file. "
                    + "The new run uses your selected dataset and starts at step zero. To continue a saved "
                    + "ConceptStudio run on its original data, use Continue in Saved runs instead.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                StudioTermsHelp(terms: [.trainingRecipe, .warmStart, .checkpoint, .precision, .baseModel])
                Button("Choose AI Toolkit recipe…") { chooseRecipe(for: row) }
                if let recipe = workspace.nativeRecipeOriginal, workspace.nativeRecipe?.modelID == row.id {
                    Text("Recipe copied: \(recipe.lastPathComponent)").font(.callout)
                    Text(
                        "Imported save cadence, retention, precision, guidance, buckets, optimizer "
                            + "and layer selection are kept. "
                            + "The controls below choose "
                            + "the new run's steps, alpha, learning rate and batch settings. Starting weights require "
                            + "the imported rank."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    Button("Choose starting LoRA weights…") { chooseCheckpoint() }
                    if workspace.initialCheckpoint != nil {
                        Label("Starting weights copied into this project", systemImage: "checkmark.circle")
                        Button("Train from the base model instead") { workspace.initialCheckpoint = nil }
                    }
                }
            }.padding(.top, 8)
        }.disabled(workspace.isBusy || workspace.isTraining)
    }

    private func chooseRecipe(for row: ModelRow) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .json,
            UTType(filenameExtension: "yaml") ?? .text,
            UTType(filenameExtension: "yml") ?? .text,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try workspace.importTrainingRecipe(from: url, row: row)
        } catch { workspace.message = error.localizedDescription }
    }

    private func chooseCheckpoint() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await workspace.importInitialCheckpoint(from: url)
        }
    }
}

struct TrainingBudgetView: View {
    let session: StudioSession
    @Bindable var workspace: GPUWorkspace
    @State private var higherCap: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cap = workspace.activeRunBudget {
                LabeledContent("Current training run budget", value: StudioMoney.format(cap))
                LabeledContent("Current run GPU cost", value: StudioMoney.format(workspace.activeRunCost ?? 0))
                HStack {
                    TextField("Raise this run's budget to (USD)", value: $higherCap, format: .number)
                    Button("Raise run budget…") { raiseBudget(from: cap) }
                        .disabled((higherCap ?? 0) <= cap)
                }
            } else {
                TextField("Budget for the next training run (USD)", value: $workspace.runBudget, format: .number)
                    .disabled(workspace.isBusy)
            }
            Text("The run budget includes input transfer, preparation, regularisation images and continued training. "
                + "Reaching either this cap or the whole-computer cap stops the computer. Estimates exclude "
                + "separately billed storage. Keep this Mac awake with the app open; closing its lid can suspend "
                + "the checks.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            StudioTermsHelp(terms: [.budget, .gpu, .resume])
        }
    }

    private func raiseBudget(from cap: Double) {
        guard let target = higherCap else { return }
        Task {
            guard await session.ask(.raiseBudget(from: cap, to: target, hourlyRate: workspace.pod?.cost)) == .confirm
            else { return }
            if workspace.raiseRunBudget(to: target) { higherCap = nil }
        }
    }
}
