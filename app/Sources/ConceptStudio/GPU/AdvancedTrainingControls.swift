import SwiftUI

struct AdvancedTrainingControls: View {
    @Bindable var workspace: GPUWorkspace

    var body: some View {
        let row = workspace.effectiveModelRow
        Form {
            if row.resolution.multiple {
                LabeledContent("Image resolution buckets") {
                    HStack {
                        ForEach(workspace.resolutionChoices, id: \.self) { resolution in
                            Toggle("\(resolution) px", isOn: Binding(
                                get: { workspace.trainingResolutions.contains(resolution) },
                                set: { selected in
                                    workspace.trainingResolutions.removeAll { $0 == resolution }
                                    if selected { workspace.trainingResolutions.append(resolution) }
                                    workspace.trainingResolutions.sort()
                                }
                            ))
                        }
                    }
                }.help("Choose one or more image sizes. Video dimensions come from approved clips.")
            } else {
                Picker("Training resolution", selection: $workspace.resolution) {
                    ForEach(workspace.resolutionChoices, id: \.self) { Text("\($0) px").tag($0) }
                }
                .help("Sets photo training and generated-output resolution. Video dimensions come from approved clips.")
            }
            if row.recipe.checkpoints.editable { checkpointControls }
            if workspace.nativeRecipeHook != nil { guidanceControls }
            if row.recipe.checkpoints.editable {
                Text("Checkpoint precision changes saved weights; it does not change the model's training precision. "
                    + "Choose at least one image bucket and positive step and checkpoint values.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            TextField("LoRA rank", value: $workspace.rank, format: .number.grouping(.never))
                .help("How much detail the small trained add-on can hold. Higher values use more memory.")
            TextField("LoRA alpha", value: $workspace.alpha, format: .number.grouping(.never))
            TextField("Batch size", value: $workspace.batchSize, format: .number.grouping(.never))
            TextField("Gradient accumulation", value: $workspace.accumulation, format: .number.grouping(.never))
            TextField("Learning rate", value: $workspace.learningRate, format: .number)
                .help("How much the model changes at each step. Keep the default for your first run.")
            if workspace.usesRegularization { regularizationControls }
            TextField("Triggers", text: $workspace.triggerWords)
            TextField("Caption profile", text: $workspace.profile)
            TextField("Training seed", value: $workspace.seed, format: .number)
            if workspace.trainingDatasetContainsVideo, row.video != nil {
                Text(
                    "Video training uses every frame at the dimensions and rate approved in Images. To change a "
                        + "clip's dimensions or length, approve its segment again, then caption and publish it. "
                        + "The trainer refuses hidden cropping or truncation."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            Toggle("Keep a caption model on GPU 0 while training", isOn: $workspace.keepCaptionServer)
            if workspace.keepCaptionServer { TextField("Caption model", text: $workspace.captionModel) }
            StudioTermsHelp(terms: [
                .trainingSteps,
                .checkpoint,
                .precision,
                .guidancePreservation,
                .rank,
                .alpha,
                .learningRate,
                .batchSize,
                .gradientAccumulation,
                .resolution,
                .seed,
                .trigger,
            ])
        }.formStyle(.columns)
    }

    /// Shown only while the regularisation toggle is on.
    @ViewBuilder private var regularizationControls: some View {
        let standard = workspace.regularizationOffer.map { String(format: "%g", $0.weight) } ?? "1"
        TextField("Regularisation strength", value: $workspace.regularizationWeight, format: .number)
            .help("How much each regularisation image counts compared with one of yours. "
                + "\(standard) is the default for this model.")
    }

    @ViewBuilder private var checkpointControls: some View {
        TextField(
            "Save checkpoint every (steps)",
            value: $workspace.checkpointEvery,
            format: .number.grouping(.never)
        )
        TextField(
            "Keep last checkpoints",
            value: $workspace.checkpointRetention,
            format: .number.grouping(.never)
        )
        .help("Zero keeps all checkpoints. More checkpoints use more storage.")
        Picker("Saved checkpoint precision", selection: $workspace.checkpointPrecision) {
            Text("Float32 · full precision").tag("float32")
            Text("Float16 · smaller files").tag("float16")
            Text("BFloat16").tag("bfloat16")
            if ["fp16", "fp32", "bf16"].contains(workspace.checkpointPrecision) {
                Text("Imported: " + workspace.checkpointPrecision).tag(workspace.checkpointPrecision)
            }
        }
    }

    /// The `native_recipe` hook's guidance rules.
    @ViewBuilder private var guidanceControls: some View {
        if workspace.h3UsesTrainingAdapter {
            LabeledContent("Guidance preservation loss", value: "Off required · Circlestone adapter")
            Text("The included Circlestone adapter requires ordinary training with guidance preservation "
                + "loss off. Import a native recipe without this adapter to edit guidance settings.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Toggle("Guidance preservation loss", isOn: $workspace.guidanceLoss)
                .help("Adds guidance-preservation training work when no training adapter is used.")
            TextField("Guidance loss target", text: $workspace.guidanceTargetText)
                .help("A number from 0 to 20, such as 3.5. Imported two-value ranges are also preserved.")
        }
    }
}
