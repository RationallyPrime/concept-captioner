import SwiftUI

struct PublishView: View {
    @Bindable var session: StudioSession

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(
                "Your dataset is the handoff to training. Publishing includes the photos, captions, "
                    + "response records and job file in the same open layout used by the command-line tool."
            )
            TextField("Hugging Face owner/dataset", text: $session.repoID).textFieldStyle(.roundedBorder)
            Toggle("Private dataset", isOn: $session.privateDataset)
            Text(
                "Keep private photos private. Your Hugging Face write token goes in Settings; "
                    + "it is never saved in the project."
            )
            .foregroundStyle(.secondary)
            if let project = session.project {
                LabeledContent("Photos", value: "\(project.images.count)")
                LabeledContent("Captions", value: "\(project.images.count(where: { !$0.caption.isEmpty }))")
                LabeledContent("Final captions", value: "\(project.images.filter(\.isFinal).count)")
                if project.images.contains(where: \.caption.isEmpty) {
                    Label(
                        "Some photos have no caption yet. Review or caption them before training.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Button(session.demoMode ? "Try publishing the demo" : "Publish dataset", systemImage: "arrow.up.doc") {
                session.publish()
            }.buttonStyle(.borderedProminent).disabled(session.busy || (!session.demoMode && session.repoID.isEmpty))
            Text(session
                .demoMode ? "Offline simulation: no files leave your Mac." :
                "Uploads to your own Hugging Face account. This action does not rent a computer.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: 680, alignment: .leading)
    }
}
