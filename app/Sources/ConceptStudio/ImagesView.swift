import ConceptCore
import PhotosUI
import SwiftUI

struct ImagesView: View {
    @Bindable var session: StudioSession
    @State private var photos: [PhotosPickerItem] = []
    @State private var hubRepo = ""
    @State private var showHub = false
    @State private var warningsOnly = false
    @State private var editingMedia: ProjectImage?
    @State private var confirmUndo = false

    private var images: [ProjectImage] {
        session.project?.allMedia ?? []
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
                    title: "Add training images or clips",
                    subtitle: "Choose the images or clips you want to use for this project."
                ) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { importButtons }
                        VStack(alignment: .leading, spacing: 10) { importButtons }
                    }.disabled(session.busy)
                }
                Divider()
                if images.isEmpty {
                    ContentUnavailableView(
                        "Add your first images or clips",
                        systemImage: "photo.on.rectangle",
                        description: Text(
                            "Import a folder, choose individual images or clips, or use one of the other sources above."
                        )
                    )
                } else {
                    if !duplicateGroups.isEmpty { duplicateSection }
                    gallery
                }
                StudioIntroduction(preferences: session.preferences)
                Divider()
                StudioSection(
                    title: "Before spending on training",
                    subtitle: session.project?.job.concepts.isEmpty == true
                        ? "Get general quality advice now. Add a concept for coverage-specific feedback."
                        : "Ask for advice on the set as a whole."
                ) {
                    Button("Ask for dataset advice", systemImage: "sparkles") { session.datasetCritique() }
                        .disabled(session.busy || images.isEmpty)
                    Text(session.demoMode ? "Prepared demo advice; no model called." :
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
        .sheet(item: $editingMedia) { media in MediaEditorView(session: session, media: media) }
        .confirmationDialog("Undo this target edit and discard its unsaved caption edits?", isPresented: $confirmUndo) {
            Button("Undo target edit and discard edits", role: .destructive) { session.undoMediaCuration() }
            Button("Keep editing", role: .cancel) {}
        }
        .sheet(isPresented: $showHub) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import a Hugging Face dataset").font(.title2.bold())
                Text(
                    "Enter owner/dataset. This app reads imagefolder datasets with images or clips; "
                        + "parquet-only datasets need conversion first."
                )
                .foregroundStyle(StudioStyle.supportingText)
                TextField("owner/dataset", text: $hubRepo)
                HStack {
                    Button("Cancel") { showHub = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Download images or clips") { session.importHub(hubRepo); showHub = false }
                        .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint).disabled(hubRepo.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 490)
        }
    }

    @ViewBuilder private var importButtons: some View {
        Button("Import folder…", systemImage: "folder") {
            if let folder = ProjectAccess
                .chooseFolder(prompt: "Import images or clips") { session.importFolder(folder) }
        }
        .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Import a folder of images or clips (⌘↩)")
        Button("Choose images or clips…") { session.importImages(ProjectAccess.chooseMedia()) }
        PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) { Label(
            "Apple Photos",
            systemImage: "photo"
        ) }
        .disabled(session.demoMode)
        Button("Hugging Face dataset…") { showHub = true }
    }

    private var duplicateGroups: [[ProjectImage]] {
        var groups: [String: [ProjectImage]] = [:]
        for image in images {
            var root = image.id
            var seen: Set<String> = []
            while let previous = session.analyses[root]?.duplicateOf, seen.insert(root).inserted {
                root = previous
            }
            groups[root, default: []].append(image)
        }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0].id < $1[0].id }
    }

    private var duplicateSection: some View {
        StudioSection(
            title: "Duplicate and similar groups",
            subtitle: "Compare these samples and choose which to include."
        ) {
            ForEach(duplicateGroups, id: \.first?.id) { group in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(group) { image in
                            VStack(alignment: .leading, spacing: 8) {
                                PhotoView(url: image.url).frame(width: 150, height: 120)
                                Text(image.id).font(.caption).lineLimit(1)
                                Toggle("Include", isOn: Binding(
                                    get: { session.project?.isIncluded(image.id) == true },
                                    set: { session.includeMedia(image.id, included: $0) }
                                )).toggleStyle(.checkbox).disabled(session.busy || session.editing)
                            }.frame(width: 150)
                        }
                    }
                }
            }
        }
    }

    private var gallery: some View {
        StudioSection(title: "Your training set") {
            HStack(spacing: 18) {
                Text(
                    "\(session.project?.images.count ?? 0) included · "
                        + "\(session.project?.excludedImages.count ?? 0) excluded"
                )
                .fontWeight(.medium)
                Button("Undo curation") {
                    let replaced = session.project?.curationUndo.last?.replacedIDs ?? []
                    if images.contains(where: { replaced.contains($0.id) && session.hasUnsavedCaption(for: $0) }) {
                        confirmUndo = true
                    } else { session.undoMediaCuration() }
                }
                .disabled(session.busy || session.editing || session.project?.curationUndo.isEmpty != false)
                if warningCount > 0 {
                    Label("\(warningCount) with warnings", systemImage: "exclamationmark.triangle")
                }
                Spacer()
                Toggle("Show warnings only", isOn: $warningsOnly)
                    .toggleStyle(.checkbox)
            }.font(.callout)
            if visibleImages.isEmpty {
                ContentUnavailableView("No media with warnings to show", systemImage: "photo.on.rectangle")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200), alignment: .top)],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(visibleImages) { image in
                        VStack(alignment: .leading, spacing: 9) {
                            PhotoView(url: image.url).frame(height: 190)
                                .frame(maxWidth: .infinity)
                                .background(StudioStyle.surface)
                            Toggle("Include in training", isOn: Binding(
                                get: { session.project?.isIncluded(image.id) == true },
                                set: { session.includeMedia(image.id, included: $0) }
                            )).toggleStyle(.checkbox).disabled(session.busy || session.editing)
                            Button(Sources
                                .isVideo(Sources.suffix(of: image.id)) ? "Preview and trim clip…" :
                                "Inspect and crop…") {
                                    editingMedia = image
                                }
                                .disabled(session.busy || session.editing || session.project?
                                    .isIncluded(image.id) != true)
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
