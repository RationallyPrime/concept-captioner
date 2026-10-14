import SwiftUI

/// The two optional training aids, between "What to train" and "Run settings". Each appears only for a model whose
/// row offers it (docs/model-table.md); a model that offers neither shows nothing here.
struct TrainingAidsView: View {
    let session: StudioSession
    @Bindable var workspace: GPUWorkspace

    var body: some View {
        if workspace.regularizationOffer != nil {
            RegularizationSection(session: session, workspace: workspace)
            Divider()
        }
        if let repa = workspace.repaOffer {
            RepaSection(workspace: workspace, offer: repa)
            Divider()
        }
    }
}

struct RegularizationSection: View {
    let session: StudioSession
    @Bindable var workspace: GPUWorkspace

    private var locked: Bool {
        workspace.isBusy || workspace.isTraining
    }

    private var subjects: String {
        let phrase = workspace.regularizationSubjects
        return phrase.isEmpty ? "the kind of subject you are training" : phrase
    }

    /// What the section says before the person turns anything on.
    var explanation: String {
        "Before training, the computer draws ordinary pictures of \(subjects) with the original model, from your "
            + "captions with the names taken out. Training looks at them alongside your photos so the model does "
            + "not start drawing your subject whenever you ask for \(subjects)."
    }

    var body: some View {
        StudioSection(title: "Regularisation images", subtitle: explanation) {
            Form {
                Toggle("Use regularisation images", isOn: $workspace.regularizationOn).disabled(locked)
                if workspace.regularizationOn {
                    LabeledContent("Images of") { concepts }
                    TextField("Number", value: $workspace.regularizationImages, format: .number.grouping(.never))
                        .disabled(locked)
                        .help("How many ordinary pictures to draw. They are kept on this storage and reused.")
                }
            }.formStyle(.columns)
            if workspace.regularizationOn, let estimate = workspace.regularizationEstimate {
                Text(estimate.sentence + " Reused on this storage when your captions have not changed. "
                    + "Training takes about twice as long: every other step looks at one of these images "
                    + "instead of yours.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StudioTermsHelp(terms: [.regularizationImages, .priorPreservation])
        }
    }

    private var concepts: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(workspace.triggerClassNouns, id: \.trigger) { entry in
                    if let noun = entry.noun {
                        Text("\(ClassNounPhrase.withArticle(noun)) (\(entry.trigger))")
                    } else {
                        Label(
                            "Define a class noun for \(entry.trigger) in Concepts before training with "
                                + "regularisation images.",
                            systemImage: "exclamationmark.triangle"
                        ).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Edit in Concepts") { session.step = .concepts }
        }
    }
}

struct RepaSection: View {
    @Bindable var workspace: GPUWorkspace
    let offer: ModelRow.Repa

    var body: some View {
        StudioSection(title: "Representation alignment (experimental)") {
            Form {
                Toggle("Align with an image-recognition model while training", isOn: $workspace.repaOn)
                    .disabled(workspace.isBusy || workspace.isTraining)
            }.formStyle(.columns)
            Text("Nudges the model's early layers to see your photos the way a strong image-recognition model does. "
                + "It is experimental and may not help. The first run downloads a "
                + "\(String(format: "%.1f", offer.encoderDownloadGB)) GB helper model to this computer's storage; "
                + "training speed is unchanged after a short preparation.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            StudioTermsHelp(terms: [.representationAlignment, .lora])
        }
    }
}
