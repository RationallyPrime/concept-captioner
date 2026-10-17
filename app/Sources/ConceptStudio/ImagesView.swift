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
                importBar
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
        .modifier(PrimaryWhenEmpty(empty: images.isEmpty))
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

    /// A slim row of quiet import buttons above the sheet; the first import is the screen's one primary action.
    private var importBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add training images or clips").font(.system(size: 13.5, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { importButtons }
                VStack(alignment: .leading, spacing: 10) { importButtons }
            }.disabled(session.busy)
        }
    }

    /// The contact sheet: every sample as a print, curation warnings stamped in its margin.
    private var gallery: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                Text(
                    "\(session.project?.images.count ?? 0) included · "
                        + "\(session.project?.excludedImages.count ?? 0) excluded"
                        + (warningCount > 0 ? " · \(warningCount) with warnings" : "")
                )
                .font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                Button("Undo curation") {
                    let replaced = session.project?.curationUndo.last?.replacedIDs ?? []
                    if images.contains(where: { replaced.contains($0.id) && session.hasUnsavedCaption(for: $0) }) {
                        confirmUndo = true
                    } else { session.undoMediaCuration() }
                }
                .disabled(session.busy || session.editing || session.project?.curationUndo.isEmpty != false)
                Spacer()
                Toggle("Show warnings only", isOn: $warningsOnly)
                    .toggleStyle(.checkbox).disabled(warningCount == 0 && !warningsOnly)
            }.font(.callout)
            if visibleImages.isEmpty {
                ContentUnavailableView("No media with warnings to show", systemImage: "photo.on.rectangle")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(visibleImages) { image in curationPrint(image) }
                }
            }
        }
    }

    private func curationPrint(_ image: ProjectImage) -> some View {
        let included = session.project?.isIncluded(image.id) == true
        let warnings = session.analyses[image.id]?.warnings ?? []
        let isVideo = Sources.isVideo(Sources.suffix(of: image.id))
        let locked = session.busy || session.editing
        return VStack(alignment: .leading, spacing: 0) {
            TrainingTargetPreview(url: image.url, fill: true)
                .frame(maxWidth: .infinity).frame(height: 150).clipped()
                .opacity(included ? 1 : 0.55)
                .overlay { if !included { StrikeLine() } }
                .overlay(alignment: .topTrailing) {
                    if isVideo {
                        Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(.white)
                            .padding(5).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6).accessibilityLabel("Clip")
                    }
                }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(image.id).font(.system(size: 13, weight: .semibold)).foregroundStyle(InstantPrint.ink)
                        .lineLimit(1).truncationMode(.middle).help(image.id)
                    Spacer(minLength: 4)
                    Button {
                        editingMedia = image
                    } label: {
                        Image(systemName: isVideo ? "timeline.selection" : "crop")
                    }
                    .buttonStyle(.plain).foregroundStyle(InstantPrint.inkSecondary)
                    .disabled(locked || !included)
                    .help(isVideo ? "Preview and trim clip…" : "Inspect and crop…")
                    .accessibilityLabel(isVideo ? "Preview and trim \(image.id)" : "Inspect and crop \(image.id)")
                }
                Toggle("Include in training", isOn: Binding(
                    get: { included },
                    set: { session.includeMedia(image.id, included: $0) }
                ))
                .toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(InstantPrint.ink)
                .disabled(locked)
                ForEach(warnings, id: \.self) { warning in
                    VStack(alignment: .leading, spacing: 4) {
                        PrintStateChip(state: .attention(nil))
                        Text(warning).font(.system(size: 11.5)).foregroundStyle(InstantPrint.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(InstantPrint.attention.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 8)
        }
        .padding([.horizontal, .top], 6)
        .background(warnings.isEmpty ? InstantPrint.paper : InstantPrint.attentionWash)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1.5)
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if included, !locked { editingMedia = image } }
        .contextMenu {
            Button(isVideo ? "Preview and trim clip…" : "Inspect and crop…") { editingMedia = image }
                .disabled(locked || !included)
            Button(included ? "Exclude from training" : "Include in training") {
                session.includeMedia(image.id, included: !included)
            }.disabled(locked)
        }
    }
}

/// The import button is the screen's primary action only while there is nothing to curate yet.
private struct PrimaryWhenEmpty: ViewModifier {
    let empty: Bool

    func body(content: Content) -> some View {
        if empty {
            content.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
        } else {
            content
        }
    }
}
