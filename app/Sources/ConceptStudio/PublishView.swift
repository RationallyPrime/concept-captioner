import SwiftUI

struct PublishView: View {
    @Bindable var session: StudioSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                StudioSection(
                    title: "Prepare the training dataset",
                    subtitle: "Upload the included images or clips and their saved captions "
                        + "so the training computer can use them."
                ) {
                    if let project = session.project {
                        LabeledContent("Included samples", value: "\(project.images.count)")
                        LabeledContent("Captions", value: "\(project.images.count(where: { !$0.caption.isEmpty }))")
                        LabeledContent("Final captions", value: "\(project.images.filter(\.isFinal).count)")
                        if project.images.contains(where: \.caption.isEmpty) {
                            StudioNotice(
                                "Some samples have no caption yet. Review or caption them before training.",
                                symbol: "exclamationmark.triangle"
                            )
                        } else if !project.images.isEmpty {
                            Label("Every included sample has a saved caption", systemImage: "checkmark.circle")
                                .foregroundStyle(StudioStyle.accent)
                        }
                    }
                    if session.unsavedCaptionCount > 0 {
                        StudioNotice(
                            "\(session.unsavedCaptionCount) caption edits are not saved. "
                                + "Publishing uses saved captions, so return to Review to save those edits.",
                            symbol: "pencil"
                        )
                        Button("Review unsaved edits") { session.step = .review }
                    }
                    DisclosureGroup("What gets uploaded") {
                        Text(
                            "The upload contains your included training images or selected video segments, their saved "
                                + "captions and the project configuration. Approved crops replace the full images. "
                                + "Excluded samples, editing originals and mapping references are omitted."
                        )
                        .font(.callout).foregroundStyle(StudioStyle.supportingText).padding(.top, 12)
                    }
                }
                Divider()
                if session.gpu.usesLocalDataset {
                    StudioSection(title: "Upload directly to your training computer") {
                        Text("No Hugging Face token is configured. Check your saved training data here, then rent a "
                            + "computer and start training. The app uploads your included targets directly over its "
                            + "authenticated connection. No dataset account is required.")
                        Text("Up to 2 GiB per file and 20 GiB per dataset. "
                            + "Some starting models still require their own account or license access.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                } else {
                    StudioSection(
                        title: "Choose the destination",
                        subtitle: "Use a dataset in your own Hugging Face account."
                    ) {
                        TextField("Hugging Face owner/dataset", text: $session.repoID).textFieldStyle(.roundedBorder)
                        Toggle("Private dataset", isOn: $session.privateDataset)
                        Text("Private datasets are visible only to accounts with access. "
                            + "Keep this on for private images and clips.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        StudioNotice(
                            "Your Hugging Face write token goes in Settings. It is never saved in the project.",
                            symbol: "key"
                        )
                    }.disabled(session.busy)
                }
                Divider()
                StudioSection(
                    title: session.gpu.usesLocalDataset ? "Check training data" : "Publish",
                    subtitle: session.demoMode
                        ? "Offline simulation: no files leave your Mac and no money is spent."
                        : session.gpu.usesLocalDataset ? "Checks the included targets and saved captions on your Mac."
                        : "Uploads to your own account. This action does not rent a computer."
                ) {
                    Button(
                        session.demoMode ? "Simulate dataset upload"
                            : session.gpu.usesLocalDataset ? "Check training data" : "Publish dataset",
                        systemImage: "arrow.up.doc"
                    ) {
                        session.publish()
                    }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(session.gpu.usesLocalDataset
                            ? "Check saved training data (⌘↩)" : "Publish the dataset (⌘↩)")
                        .disabled(session
                            .busy || (!session.demoMode && !session.gpu.usesLocalDataset && session.repoID.isEmpty))
                    if session.busy { ProgressView(session.message) }
                    Text(
                        "Continue to GPU pods to choose a training computer and review its price. "
                            + "Training uses your saved captions and included media."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }.frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { session.preparePublishing() }
    }
}
