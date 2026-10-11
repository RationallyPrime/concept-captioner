import SwiftUI

struct PublishView: View {
    @Bindable var session: StudioSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                StudioSection(
                    title: "Prepare the training dataset",
                    subtitle: "Put your photos and saved captions online so your training computer can use them."
                ) {
                    if let project = session.project {
                        LabeledContent("Photos", value: "\(project.images.count)")
                        LabeledContent("Captions", value: "\(project.images.count(where: { !$0.caption.isEmpty }))")
                        LabeledContent("Final captions", value: "\(project.images.filter(\.isFinal).count)")
                        if project.images.contains(where: \.caption.isEmpty) {
                            StudioNotice(
                                "Some photos have no caption yet. Review or caption them before training.",
                                symbol: "exclamationmark.triangle"
                            )
                        } else if !project.images.isEmpty {
                            Label("Every photo has a saved caption", systemImage: "checkmark.circle")
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
                            "The upload includes photos, caption sidecars, response records and the job file "
                                + "in the shared project layout. Reference faces stay on your Mac."
                        )
                        .font(.callout).foregroundStyle(StudioStyle.supportingText).padding(.top, 12)
                    }
                }
                Divider()
                StudioSection(
                    title: "Choose the destination",
                    subtitle: "Use a dataset in your own Hugging Face account."
                ) {
                    TextField("Hugging Face owner/dataset", text: $session.repoID).textFieldStyle(.roundedBorder)
                    Toggle("Private dataset", isOn: $session.privateDataset)
                    Text("Private datasets are visible only to accounts with access. Keep this on for private photos.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    StudioNotice(
                        "Your Hugging Face write token goes in Settings. It is never saved in the project.",
                        symbol: "key"
                    )
                }.disabled(session.busy)
                Divider()
                StudioSection(
                    title: "Publish",
                    subtitle: session.demoMode
                        ? "Offline simulation: no files leave your Mac and no money is spent."
                        : "Uploads to your own account. This action does not rent a computer."
                ) {
                    Button(
                        session.demoMode ? "Try publishing the demo" : "Publish dataset",
                        systemImage: "arrow.up.doc"
                    ) {
                        session.publish()
                    }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Publish the dataset (⌘↩)")
                        .disabled(session.busy || (!session.demoMode && session.repoID.isEmpty))
                    if session.busy { ProgressView(session.message) }
                    Text(
                        "After publishing, continue to GPU pods to choose a training computer and review its price."
                    )
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }.frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
