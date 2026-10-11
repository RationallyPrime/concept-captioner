import ConceptCore
import SwiftUI

struct MappingView: View {
    @Bindable var session: StudioSession
    @State private var locators: [String: String] = [:]
    @State private var enabled: Set<String> = []
    @State private var onlyUnmapped = false
    /// The editor holds a model or on-device suggestion rather than a confirmed mapping.
    @State private var fromSuggestion = false
    /// The person changed the editor since it was filled; a late suggestion must not overwrite that.
    @State private var edited = false
    /// Height of the photo detail's scroll area; below `shortDetail` the photo moves beside the subjects.
    @State private var detailHeight: CGFloat = 600
    private let shortDetail: CGFloat = 440

    private var images: [ProjectImage] {
        (session.project?.images ?? []).filter { !onlyUnmapped || session.project?.job.mapping(for: $0.id) == nil }
    }

    private var confirmedCount: Int {
        (session.project?.images.count ?? 0) - session.unmappedCount
    }

    private var selectedImage: ProjectImage? {
        images.first { $0.id == session.selectedImageID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StudioSection(
                title: "Match each photo to your concepts",
                subtitle: "Identify who or what is present. "
                    + "A suggestion becomes part of your project only when you confirm it."
            ) {
                HStack(spacing: 20) {
                    Text("\(confirmedCount) / \(session.project?.images.count ?? 0) confirmed")
                        .fontWeight(.medium)
                    ProgressView(
                        value: Double(confirmedCount),
                        total: Double(max(session.project?.images.count ?? 0, 1))
                    )
                    .frame(maxWidth: 180).accessibilityLabel("Photos confirmed")
                    Spacer()
                    Toggle("Show unconfirmed only", isOn: $onlyUnmapped).toggleStyle(.checkbox)
                }.font(.callout)
                HStack(spacing: 10) {
                    Button("Suggest on this Mac", systemImage: "person.crop.rectangle") {
                        session.proposeMappings(useModel: false)
                    }
                    Button("Ask model using references", systemImage: "sparkles") {
                        session.proposeMappings(useModel: true)
                    }
                }.disabled(session.busy)
                Text(session.demoMode ? "Both actions run offline in the demo." :
                    "Mac suggestions stay on this device. "
                    + "Asking the model uses your selected provider and may use account credits.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            Divider()
            HSplitView {
                List(images, selection: $session.selectedImageID) { image in
                    HStack(spacing: 10) {
                        PhotoView(url: image.url).frame(width: 52, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(image.id).lineLimit(1).help(image.id)
                            rowStatus(image).font(.caption)
                        }
                    }.padding(.vertical, 4).tag(image.id)
                }.listStyle(.inset).frame(minWidth: 190, idealWidth: 225, maxWidth: 280)
                ScrollView {
                    if let image = selectedImage {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(image.id).font(.title3.weight(.semibold)).textSelection(.enabled)
                            if fromSuggestion {
                                StudioNotice(
                                    "Filled in from a suggestion. Check every subject against this photo, "
                                        + "then confirm. Nothing is saved until you do.",
                                    symbol: "person.crop.rectangle.badge.checkmark"
                                )
                            }
                            // In a short window the photo sits beside the subjects, so what a suggestion filled
                            // in is in view above the pinned Confirm bar next to the photo it describes.
                            if detailHeight < shortDetail {
                                HStack(alignment: .top, spacing: 16) {
                                    photo(image).frame(width: 150, height: 150)
                                    presentSubjects
                                }
                            } else {
                                photo(image).frame(height: min(300, detailHeight * 0.4)).frame(maxWidth: .infinity)
                                presentSubjects
                            }
                        }.padding(.leading, 20).padding(.bottom, 12)
                    } else {
                        ContentUnavailableView(
                            onlyUnmapped && images.isEmpty ? "Every photo is confirmed" : "Select a photo",
                            systemImage: onlyUnmapped && images.isEmpty ? "checkmark.circle" : "person.crop.rectangle",
                            description: Text(onlyUnmapped && images
                                .isEmpty ? "Turn off the filter to review your confirmed mappings." :
                                "Choose a photo from the list to identify its subjects.")
                        )
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let image = selectedImage { confirmBar(for: image) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
            }
        }
        .onAppear { selectVisiblePhoto(); load() }
        .onChange(of: images.map(\.id)) { _, _ in selectVisiblePhoto() }
        .onChange(of: session.selectedImageID) { _, _ in load() }
        .onChange(of: session.selectedImageID.flatMap { session.mappingProposals[$0] }) { _, _ in
            // A suggestion that arrives while this photo is open fills it, unless the person already edited it.
            if !edited { load() }
        }
    }

    private func rowStatus(_ image: ProjectImage) -> Label<Text, Image> {
        if session.project?.job.mapping(for: image.id) != nil {
            return Label("Confirmed", systemImage: "checkmark.circle.fill")
        }
        if session.mappingProposals[image.id] != nil {
            return Label("Suggested · check it", systemImage: "sparkles")
        }
        return Label("Unconfirmed", systemImage: "circle")
    }

    private func photo(_ image: ProjectImage) -> some View {
        PhotoView(url: image.url, faces: session.analyses[image.id]?.faces ?? [])
            .background(StudioStyle.surface)
    }

    private var presentSubjects: some View {
        StudioSection(title: "Present in this photo") {
            ForEach(session.project?.job.concepts ?? [], id: \.trigger) { concept in
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "\(concept.trigger) · \(concept.classNoun)",
                        isOn: Binding(get: { enabled.contains(concept.trigger) }, set: { value in
                            edited = true
                            if value {
                                enabled.insert(concept.trigger)
                            } else {
                                enabled.remove(concept.trigger)
                            }
                        })
                    ).toggleStyle(.checkbox).fontWeight(.medium)
                    if enabled.contains(concept.trigger) {
                        TextField(
                            "Where is this subject? e.g. person on the left in a blue top",
                            text: Binding(
                                get: { locators[concept.trigger] ?? "" },
                                set: { edited = true; locators[concept.trigger] = $0 }
                            ),
                            axis: .vertical
                        ).lineLimit(1 ... 3)
                            .accessibilityLabel("\(concept.trigger) location in this photo")
                    }
                }.padding(.vertical, 4)
            }
            Text(
                "Uncheck a learning word if its subject is absent. "
                    + "Confirming with none selected means none of your concepts appears."
            )
            .font(.callout).foregroundStyle(StudioStyle.supportingText)
        }
    }

    /// Pinned below the photo so Confirm stays visible at the minimum window size.
    private func confirmBar(for image: ProjectImage) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button("Confirm and next", systemImage: "checkmark") { confirm(image) }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Confirm this photo and open the next unconfirmed one (⌘↩)")
                    .disabled(enabled.contains { (locators[$0] ?? "").isEmpty })
                Text("⌘↩").font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                if session.project?.job.mapping(for: image.id) != nil {
                    Button("Mark as unconfirmed") { unconfirm(image) }.disabled(session.busy)
                }
            }
            .padding(.leading, 20).padding(.vertical, 10)
        }
        .background(StudioStyle.canvas)
    }

    private func confirm(_ image: ProjectImage) {
        session.confirmMapping(
            id: image.id,
            mapping: Job.Mapping(enabled.sorted().map { ($0, locators[$0] ?? "") })
        )
        let order = images.map(\.id)
        let start = (order.firstIndex(of: image.id) ?? -1) + 1
        let following = order[start...] + order[..<min(start, order.count)]
        if let next = following.first(where: { $0 != image.id && session.project?.job.mapping(for: $0) == nil }) {
            session.selectedImageID = next
        } else {
            load()
        }
    }

    private func unconfirm(_ image: ProjectImage) {
        do {
            try session.project?.job.setMapping(nil, for: image.id)
            session.saveProject()
            load()
        } catch {
            session.errorMessage = StudioSession.describe(error)
        }
    }

    private func selectVisiblePhoto() {
        if !images.contains(where: { $0.id == session.selectedImageID }) {
            session.selectedImageID = images.first?.id
        }
    }

    /// Fills the editor with the confirmed mapping, or else the suggestion for this photo.
    private func load() {
        guard let id = session.selectedImageID else { return }
        let confirmed = session.project?.job.mapping(for: id)
        let suggestion = confirmed == nil ? session.mappingProposals[id] : nil
        locators = Dictionary(uniqueKeysWithValues: (confirmed ?? suggestion ?? [:]).map { ($0.key, $0.value) })
        enabled = Set(locators.keys)
        fromSuggestion = suggestion != nil
        edited = false
    }
}
