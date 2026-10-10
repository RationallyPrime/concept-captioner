import ConceptCore
import SwiftUI

struct MappingView: View {
    @Bindable var session: StudioSession
    @State private var locators: [String: String] = [:]
    @State private var enabled: Set<String> = []
    @State private var onlyUnmapped = false

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
                            Label(
                                session.project?.job.mapping(for: image.id) == nil ? "Unconfirmed" : "Confirmed",
                                systemImage: session.project?.job.mapping(for: image.id) == nil ? "circle" :
                                    "checkmark.circle.fill"
                            ).font(.caption)
                        }
                    }.padding(.vertical, 4).tag(image.id)
                }.listStyle(.inset).frame(minWidth: 190, idealWidth: 225, maxWidth: 280)
                ScrollView {
                    if let image = selectedImage {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(image.id).font(.title3.weight(.semibold)).textSelection(.enabled)
                            PhotoView(url: image.url, faces: session.analyses[image.id]?.faces ?? [])
                                .frame(height: 320).frame(maxWidth: .infinity)
                                .background(StudioStyle.surface)
                            if session.mappingProposals[image.id] != nil {
                                StudioNotice(
                                    "Check every suggested subject against this photo before confirming.",
                                    symbol: "person.crop.rectangle.badge.checkmark"
                                )
                                Button("Fill from suggestion") { load(proposal: true) }
                            }
                            StudioSection(title: "Present in this photo") {
                                ForEach(session.project?.job.concepts ?? [], id: \.trigger) { concept in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Toggle(
                                            "\(concept.trigger) · \(concept.classNoun)",
                                            isOn: Binding(get: { enabled.contains(concept.trigger) }, set: { value in
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
                                                    set: { locators[concept.trigger] = $0 }
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
                            Divider()
                            Button("Confirm this photo") {
                                session.confirmMapping(
                                    id: image.id,
                                    mapping: Job.Mapping(enabled.sorted().map { ($0, locators[$0] ?? "") })
                                )
                                if let next = images
                                    .first(where: { session.project?.job.mapping(for: $0.id) == nil }) {
                                    session.selectedImageID = next.id
                                }
                            }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                                .disabled(session.busy || enabled.contains { (locators[$0] ?? "").isEmpty })
                            Button("Mark as unconfirmed") {
                                do {
                                    try session.project?.job.setMapping(nil, for: image.id)
                                    session.saveProject()
                                } catch {
                                    session.errorMessage = StudioSession.describe(error)
                                }
                            }.disabled(session.busy)
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
            }
        }
        .onAppear { selectVisiblePhoto(); load() }
        .onChange(of: images.map(\.id)) { _, _ in selectVisiblePhoto() }
        .onChange(of: session.selectedImageID) { _, _ in load() }
    }

    private func selectVisiblePhoto() {
        if !images.contains(where: { $0.id == session.selectedImageID }) {
            session.selectedImageID = images.first?.id
        }
    }

    private func load(proposal: Bool = false) {
        guard let id = session.selectedImageID else { return }
        let mapping = proposal ? session.mappingProposals[id] : session.project?.job.mapping(for: id)
        locators = Dictionary(uniqueKeysWithValues: (mapping ?? [:]).map { ($0.key, $0.value) })
        enabled = Set(locators.keys)
    }
}
