import PhotosUI
import SwiftUI

struct ImagesView: View {
    @Bindable var session: StudioSession
    @State private var photos: [PhotosPickerItem] = []
    @State private var hubRepo = ""
    @State private var showHub = false
    @State private var warningsOnly = false

    private var images: [ProjectImage] {
        session.project?.images ?? []
    }

    private var warningCount: Int {
        images.count { !(session.analyses[$0.id]?.warnings ?? []).isEmpty }
    }

    private var visibleImages: [ProjectImage] {
        images.filter { !warningsOnly || !(session.analyses[$0.id]?.warnings ?? []).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                StudioSection(
                    title: "Bring in your photos",
                    subtitle: "Choose varied scenes and clothing. Originals stay where they are; "
                        + "copies go into this project."
                ) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { importButtons }
                        VStack(alignment: .leading, spacing: 10) { importButtons }
                    }.disabled(session.busy)
                }
                Divider()
                if images.isEmpty {
                    ContentUnavailableView(
                        "Add your first photos",
                        systemImage: "photo.on.rectangle",
                        description: Text(
                            "Import a folder, choose individual photos, or use one of the other sources above."
                        )
                    )
                } else {
                    gallery
                }
                Divider()
                StudioSection(title: "Before spending on training", subtitle: "Ask for advice on the set as a whole.") {
                    Button("Ask for dataset advice", systemImage: "sparkles") { session.datasetCritique() }
                        .disabled(session.busy || images.isEmpty)
                    Text(session.demoMode ? "Offline advice, no account required." :
                        "Uses your selected captioning provider and may use account credits. "
                        + "Set up a gateway key in Settings first.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    if !session.datasetAdvice.isEmpty {
                        Text(session.datasetAdvice).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 740, alignment: .leading)
                    }
                }
            }
        }
        .onChange(of: photos) { _, items in session.importPhotos(items); photos = [] }
        .sheet(isPresented: $showHub) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import a Hugging Face dataset").font(.title2.bold())
                Text(
                    "Enter owner/dataset. This app reads imagefolder datasets; "
                        + "parquet-only datasets need conversion first."
                )
                .foregroundStyle(StudioStyle.supportingText)
                TextField("owner/dataset", text: $hubRepo)
                HStack {
                    Button("Cancel") { showHub = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Download images") { session.importHub(hubRepo); showHub = false }
                        .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint).disabled(hubRepo.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 490)
        }
    }

    @ViewBuilder private var importButtons: some View {
        Button("Import folder…", systemImage: "folder") { session.importFolder() }
            .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Import a folder of photos (⌘↩)")
        Button("Choose photos…") { session.importImages(ProjectAccess.chooseImages()) }
        PhotosPicker(selection: $photos, matching: .images) { Label("Apple Photos", systemImage: "photo") }
            .disabled(session.demoMode)
        Button("Hugging Face dataset…") { showHub = true }
    }

    private var gallery: some View {
        StudioSection(title: "Your photo set") {
            HStack(spacing: 18) {
                Text("\(images.count) photos").fontWeight(.medium)
                if warningCount > 0 {
                    Label("\(warningCount) with warnings", systemImage: "exclamationmark.triangle")
                }
                Spacer()
                Toggle("Show warnings only", isOn: $warningsOnly)
                    .toggleStyle(.checkbox)
            }.font(.callout)
            if visibleImages.isEmpty {
                ContentUnavailableView("No photos with warnings to show", systemImage: "photo.on.rectangle")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], alignment: .leading, spacing: 24) {
                    ForEach(visibleImages) { image in
                        VStack(alignment: .leading, spacing: 9) {
                            PhotoView(url: image.url).frame(height: 190)
                                .frame(maxWidth: .infinity)
                                .background(StudioStyle.surface)
                            Divider()
                            Text(image.id).font(.callout.weight(.medium)).lineLimit(1).help(image.id)
                            ForEach(session.analyses[image.id]?.warnings ?? [], id: \.self) { warning in
                                Label {
                                    Text(warning).fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                }.font(.callout).foregroundStyle(StudioStyle.supportingText)
                            }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }
}
