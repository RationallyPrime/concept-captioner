import SwiftUI

struct PublishView: View {
    @Bindable var session: StudioSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                if let project = session.project { datasetSummary(project) }
                if session.unsavedCaptionCount > 0 {
                    HStack(spacing: 12) {
                        StudioNotice(
                            "\(session.unsavedCaptionCount) caption edits are not saved. "
                                + "Publishing uses saved captions, so return to Review to save those edits.",
                            symbol: "pencil"
                        )
                        Button("Review unsaved edits") { session.step = .review }
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
            }.frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { session.preparePublishing() }
        .onChange(of: session.providerCredentialRevision) { _, _ in session.preparePublishing() }
    }

    /// The included prints squared up like a stack for the box, beside the three counts that matter.
    private func datasetSummary(_ project: StudioProject) -> some View {
        let captioned = project.images.count(where: { !$0.caption.isEmpty })
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 36) {
                printStack(project.images)
                HStack(alignment: .top, spacing: 30) {
                    PrintFigure(value: "\(project.images.count)", label: "samples")
                    PrintFigure(value: "\(captioned)", label: "captions")
                    PrintFigure(value: "\(project.images.filter(\.isFinal).count)", label: "final")
                }
                Spacer(minLength: 0)
            }
            if project.images.contains(where: \.caption.isEmpty) {
                StudioNotice(
                    "Some samples have no caption yet. Review or caption them before training.",
                    symbol: "exclamationmark.triangle"
                )
            } else if !project.images.isEmpty {
                Label("Every included sample has a saved caption", systemImage: "checkmark.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            DisclosureGroup("What gets uploaded") {
                Text(
                    "The upload contains your included training images or selected video segments, their saved "
                        + "captions and the project configuration. Approved crops replace the full images. "
                        + "Excluded samples, editing originals and mapping references are omitted."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText).padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Up to eight prints, each a little further along, so the stack reads as the whole set.
    private func printStack(_ images: [ProjectImage]) -> some View {
        let shown = Array(images.prefix(8))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, image in
                VStack(spacing: 0) {
                    TrainingTargetPreview(url: image.url, fill: true).frame(width: 96, height: 96).clipped()
                    Color.clear.frame(width: 96, height: 22)
                }
                .padding([.horizontal, .top], 5)
                .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.14), radius: 2, x: 0, y: 1)
                .offset(x: CGFloat(shown.count - 1 - index) * 14)
                .zIndex(Double(index))
            }
        }
        .frame(width: 106 + CGFloat(max(shown.count - 1, 0)) * 14, height: 128, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        .accessibilityElement().accessibilityLabel("\(images.count) included samples")
    }
}
