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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(
                    "\(confirmedCount) / \(session.project?.images.count ?? 0) confirmed"
                )
                Toggle("Show unconfirmed only", isOn: $onlyUnmapped)
                Spacer()
                Button("Suggest on this Mac") { session.proposeMappings(useModel: false) }
                Button("Ask model using references") { session.proposeMappings(useModel: true) }
            }.disabled(session.busy)
            HSplitView {
                List(images, selection: $session.selectedImageID) { image in
                    Label(
                        image.id,
                        systemImage: session.project?.job.mapping(for: image.id) == nil ? "circle" : "checkmark.circle.fill"
                    )
                    .tag(image.id)
                }.frame(minWidth: 145, idealWidth: 190, maxWidth: 240)
                ScrollView {
                    if let image = session.selectedImage {
                        VStack(alignment: .leading, spacing: 16) {
                            PhotoView(url: image.url, faces: session.analyses[image.id]?.faces ?? []).frame(height: 320)
                            if session.mappingProposals[image.id] != nil {
                                Text("Suggestion only — check each person before confirming.").foregroundStyle(.orange)
                                Button("Fill from suggestion") { load(proposal: true) }
                            }
                            ForEach(session.project?.job.concepts ?? [], id: \.trigger) { concept in
                                HStack {
                                    Toggle(
                                        concept.trigger,
                                        isOn: Binding(get: { enabled.contains(concept.trigger) }, set: { value in
                                            if value {
                                                enabled.insert(concept.trigger)
                                            } else {
                                                enabled.remove(concept.trigger)
                                            }
                                        })
                                    ).frame(width: 110)
                                    TextField(
                                        "Where is this subject? e.g. person on the left in a blue top",
                                        text: Binding(
                                            get: { locators[concept.trigger] ?? "" },
                                            set: { locators[concept.trigger] = $0 }
                                        )
                                    ).disabled(!enabled.contains(concept.trigger))
                                }
                            }
                            Text(
                                "Uncheck a learning word if its subject is absent. "
                                    + "An empty confirmed mapping means none of your concepts appears."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Button("Confirm this photo") {
                                session.confirmMapping(
                                    id: image.id,
                                    mapping: Job.Mapping(enabled.sorted().map { ($0, locators[$0] ?? "") })
                                )
                                if let next = images
                                    .first(where: { session.project?.job.mapping(for: $0.id) == nil }) {
                                    session.selectedImageID = next.id
                                }
                            }.buttonStyle(.borderedProminent)
                                .disabled(session.busy || enabled.contains { (locators[$0] ?? "").isEmpty })
                            Button("Mark as unconfirmed") {
                                do {
                                    try session.project?.job.setMapping(nil, for: image.id)
                                    session.saveProject()
                                } catch {
                                    session.errorMessage = StudioSession.describe(error)
                                }
                            }.disabled(session.busy)
                        }.padding(.leading, 18)
                    } else { ContentUnavailableView("Select a photo", systemImage: "person.crop.rectangle") }
                }
            }
        }
        .onAppear { load() }
        .onChange(of: session.selectedImageID) { _, _ in load() }
    }

    private func load(proposal: Bool = false) {
        guard let id = session.selectedImageID else { return }
        let mapping = proposal ? session.mappingProposals[id] : session.project?.job.mapping(for: id)
        locators = Dictionary(uniqueKeysWithValues: (mapping ?? [:]).map { ($0.key, $0.value) })
        enabled = Set(locators.keys)
    }
}
