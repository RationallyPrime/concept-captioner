import ConceptCore
import SwiftUI

struct MappingView: View {
    @Bindable var session: StudioSession
    @State private var locators: [String: String] = [:]
    @State private var enabled: Set<String> = []
    @State private var onlyUnmapped = false
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

    private var locatorConcepts: [Concept] {
        (session.project?.job.concepts ?? []).filter(\.targetConcept.requiresLocator)
    }

    var body: some View {
        mappingEditor
    }

    private var mappingEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            StudioSection(
                title: "Locate the concept in each image or clip",
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
                    .frame(maxWidth: 180).accessibilityLabel("Samples confirmed")
                    Spacer()
                    Toggle("Show unconfirmed only", isOn: $onlyUnmapped).toggleStyle(.checkbox)
                }.font(.callout)
                HStack(spacing: 10) {
                    if !locatorConcepts.isEmpty, locatorConcepts.allSatisfy(\.targetConcept.isPersonIdentity) {
                        Button("Compare reference faces on this Mac", systemImage: "person.crop.rectangle") {
                            session.proposeMappings(useModel: false)
                        }
                    }
                    Button("Request assignments from model", systemImage: "sparkles") {
                        session.proposeMappings(useModel: true)
                    }
                }.disabled(session.busy)
                Text(session.demoMode ? "The demo model uses prepared assignments. "
                    + "Reference-face comparison runs on this Mac." :
                    "Mac suggestions stay on this device. "
                    + "Asking the model uses your selected provider and may use account credits.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                if session.project?.images.contains(where: { Sources.isVideo(Sources.suffix(of: $0.id)) }) == true {
                    Text("Reference-face comparison uses still images. For clips, request assignments "
                        + "from the model or enter locations yourself.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
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
                            suggestionResult(for: image)
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
                            onlyUnmapped && images.isEmpty ? "Every sample is confirmed" : "Select an image or clip",
                            systemImage: onlyUnmapped && images.isEmpty ? "checkmark.circle" : "person.crop.rectangle",
                            description: Text(onlyUnmapped && images
                                .isEmpty ? "Turn off the filter to review your confirmed mappings." :
                                "Choose an image or clip from the list to identify the concept.")
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
        if let result = suggestionConclusion(for: image.id) {
            return Label(result.rowTitle, systemImage: result.symbol)
        }
        if session.project?.job.mapping(for: image.id) != nil {
            return Label("Confirmed", systemImage: "checkmark.circle.fill")
        }
        return Label("Unconfirmed", systemImage: "circle")
    }

    private func suggestionConclusion(for id: String) -> MappingSuggestionConclusion? {
        MappingSuggestionConclusion.compare(
            proposal: session.mappingProposals[id], confirmed: session.project?.job.mapping(for: id),
            locatorTriggers: Set(locatorConcepts.map(\.trigger))
        )
    }

    @ViewBuilder
    private func suggestionResult(for image: ProjectImage) -> some View {
        if let result = suggestionConclusion(for: image.id), let proposal = session.mappingProposals[image.id] {
            VStack(alignment: .leading, spacing: 8) {
                StudioNotice(result.message, symbol: result.symbol)
                ForEach(locatorConcepts.filter { proposal[$0.trigger] != nil }, id: \.trigger) { concept in
                    Text("Suggested location for \(concept.trigger): \(proposal[concept.trigger] ?? "")")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText).textSelection(.enabled)
                }
            }
        }
    }

    private func photo(_ image: ProjectImage) -> some View {
        TrainingTargetPreview(
            url: image.url,
            faces: session.project?.job.concepts.contains { $0.targetConcept.isPersonIdentity } == true
                ? session.analyses[image.id]?.faces ?? [] : []
        )
        .background(StudioStyle.surface)
    }

    private var presentSubjects: some View {
        StudioSection(title: "Concept assignment") {
            ForEach(locatorConcepts, id: \.trigger) { concept in
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
                            concept.targetConcept.locatorHint,
                            text: Binding(
                                get: { locators[concept.trigger] ?? "" },
                                set: { edited = true; locators[concept.trigger] = $0 }
                            ),
                            axis: .vertical
                        ).lineLimit(1 ... 3)
                            .accessibilityLabel("\(concept.trigger) location in this sample")
                    }
                }.padding(.vertical, 4)
            }
            if let job = session.project?.job, !job.wholeTargetMapping.isEmpty {
                ForEach(job.concepts.filter { !$0.targetConcept.requiresLocator }, id: \.trigger) { concept in
                    Label("\(concept.trigger) · assigned to the whole target", systemImage: "checkmark.circle")
                        .font(.callout)
                }
                Text("Style and motion are assigned automatically. Select only the locator concepts present "
                    + "in this sample, then confirm the combined assignment.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            } else {
                Text("Select only concepts visible in this sample. If none appears, exclude the sample on Images; "
                    + "it cannot be captioned for this LoRA.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            Text("Check each selected concept against this exact training target.")
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
                    .help("Confirm this sample and open the next unconfirmed one (⌘↩)")
                    .disabled((enabled.isEmpty && session.project?.job.wholeTargetMapping.isEmpty != false)
                        || enabled.contains { (locators[$0] ?? "").isBlank } || session.busy)
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
        enabled = Set(locators.keys).intersection(locatorConcepts.map(\.trigger))
        edited = false
    }
}

/// Compares concept presence, not arbitrary locator prose or a calibrated identity score.
enum MappingSuggestionConclusion: Equatable {
    case agrees, differs, confirmedNoMatch, suggested, noMatch

    static func compare(
        proposal: Job.Mapping?, confirmed: Job.Mapping?, locatorTriggers: Set<String>
    ) -> Self? {
        guard let proposal else { return nil }
        let proposed = Set(proposal.keys).intersection(locatorTriggers)
        if proposed.isEmpty { return confirmed == nil ? .noMatch : .confirmedNoMatch }
        guard let confirmed else { return .suggested }
        return proposed == Set(confirmed.keys).intersection(locatorTriggers) ? .agrees : .differs
    }

    var rowTitle: String {
        switch self {
        case .agrees: "Confirmed · suggestion agrees"
        case .differs: "Confirmed · suggestion differs"
        case .confirmedNoMatch: "Confirmed · no confident suggestion"
        case .suggested: "Suggested · check it"
        case .noMatch: "No confident suggestion"
        }
    }

    var symbol: String {
        switch self {
        case .agrees: "checkmark.circle"
        case .differs: "arrow.triangle.branch"
        case .confirmedNoMatch, .noMatch: "person.crop.rectangle"
        case .suggested: "sparkles"
        }
    }

    var message: String {
        switch self {
        case .agrees:
            "The suggestion agrees with your confirmation about which concepts are present. "
                + "Check the suggested locations below; your confirmed locations are unchanged."
        case .differs:
            "The suggestion differs from your confirmed concepts. Your confirmed locations are kept. "
                + "Review this sample before changing them."
        case .confirmedNoMatch:
            "No confident assignment was suggested. Your confirmed locations are kept."
        case .suggested:
            "Review the suggested locations against this sample, then confirm the assignments you choose."
        case .noMatch:
            "No confident assignment was suggested. Enter the visible concepts and their locations, then confirm."
        }
    }
}
