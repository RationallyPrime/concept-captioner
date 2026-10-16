import SwiftUI

struct CaptionSaveAction {
    let save: () -> Void
    let disabled: Bool
}

private struct CaptionSaveActionKey: FocusedValueKey {
    typealias Value = CaptionSaveAction
}

extension FocusedValues {
    var captionSaveAction: CaptionSaveAction? {
        get { self[CaptionSaveActionKey.self] }
        set { self[CaptionSaveActionKey.self] = newValue }
    }
}

struct ReviewView: View {
    @Bindable var session: StudioSession
    @State private var filter = ReviewFilter.all
    @State private var comparingImage: ProjectImage?
    @State private var inspectedImage: ProjectImage?
    @State private var sideA = ComparisonChoice(kind: "", model: "")
    @State private var sideB = ComparisonChoice(kind: "", model: "")
    @State private var resultA = ""
    @State private var resultB = ""
    @State private var comparing = false

    struct ComparisonChoice: Equatable {
        var kind: String
        var model: String
    }

    enum ReviewFilter: CaseIterable {
        case all, attention, edited, final, excluded

        var title: String {
            switch self {
            case .all: "All"
            case .attention: "Needs attention"
            case .edited: "Edited"
            case .final: "Final"
            case .excluded: "Excluded"
            }
        }
    }

    private var images: [ProjectImage] {
        session.project?.images ?? []
    }

    /// Included samples first, then excluded ones, so the contact sheet keeps the whole set in view.
    private var media: [ProjectImage] {
        images + (session.project?.excludedImages ?? [])
    }

    private var triggers: [String] {
        session.project?.job.concepts.map(\.trigger) ?? []
    }

    /// Native list selection: one print opens in place; ⌘-click selects several to re-caption.
    /// Ids from another project (the selection outlives a project switch) are ignored.
    private var selection: Set<String> {
        session.reviewSelection.intersection(media.map(\.id))
    }

    private var selectedImages: [ProjectImage] {
        images.filter { selection.contains($0.id) }
    }

    func state(of image: ProjectImage) -> PrintState {
        if session.project?.excludedImages.contains(where: { $0.id == image.id }) == true { return .excluded }
        if session.hasUnsavedCaption(for: image) { return .edited }
        if image.isFinal { return .final }
        if let note = image.notes.first { return .attention(note) }
        switch image.captionState {
        case let .outcome(status), let .importedOutcome(status):
            if [.rejected, .unusable, .failed, .needsMapping].contains(status) { return .attention(nil) }
        default: break
        }
        if session.project?.mediaState.editedCaptions.contains(image.id) == true { return .edited }
        return .other(image.captionState.label)
    }

    private func matches(_ image: ProjectImage, _ filter: ReviewFilter) -> Bool {
        let state = state(of: image)
        switch filter {
        case .all: return true
        case .attention: return state.needsAttention
        case .edited: return state == .edited
        case .final: return state == .final
        case .excluded: return state == .excluded
        }
    }

    private var shown: [ProjectImage] {
        media.filter { matches($0, filter) }
    }

    /// The open print: the selected sample when it is shown, otherwise the first one the filter shows.
    private var lead: ProjectImage? {
        if selection.count <= 1, let id = selection.first, let image = shown.first(where: { $0.id == id }) {
            return image
        }
        return shown.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterBar
            GeometryReader { geometry in
                ScrollView {
                    if media.isEmpty {
                        ContentUnavailableView(
                            "No samples to review",
                            systemImage: "photo.on.rectangle",
                            description: Text("Add photos or clips on Images, then write captions on Captioning.")
                        )
                    } else {
                        contactSheet(width: geometry.size.width).padding(.bottom, 12)
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.leading, 12).padding(.trailing, 18).padding(.top, 10)
        .background(InstantPrint.ground)
        .focusedSceneValue(\.captionSaveAction, saveAction)
        .sheet(item: $comparingImage) { image in comparisonSheet(for: image) }
        .sheet(item: $inspectedImage) { image in
            VStack(spacing: 12) {
                TrainingTargetPreview(url: image.url).frame(minWidth: 560, minHeight: 560)
                Text("The whole training target, as the trainer receives it.").font(.callout)
                    .foregroundStyle(StudioStyle.supportingText)
                Button("Done") { inspectedImage = nil }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .onAppear {
            if selection.isEmpty, let id = session.selectedImageID ?? images.first?.id {
                session.reviewSelection = [id]
            }
            if sideA.kind.isEmpty { sideA = ComparisonChoice(kind: session.endpointKind, model: session.modelName) }
            if sideB.kind.isEmpty { sideB = ComparisonChoice(kind: session.endpointKind, model: "") }
        }
        .onChange(of: session.reviewSelection) { _, ids in
            if ids.count == 1, let id = ids.first, images.contains(where: { $0.id == id }) {
                session.selectedImageID = id
            }
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 0) {
            ForEach(ReviewFilter.allCases, id: \.self) { item in
                let count = media.filter { matches($0, item) }.count
                Button { filter = item } label: {
                    HStack(spacing: 8) {
                        Text(item.title).font(.system(size: 14.5))
                        Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(
                                filter == item ? Color.white.opacity(0.16) : InstantPrint.chip,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                    .foregroundStyle(filter == item ? InstantPrint.frameText : InstantPrint.ink)
                    .padding(.horizontal, filter == item ? 34 : 20).frame(height: 32)
                    .background {
                        if filter == item {
                            RoundedRectangle(cornerRadius: 9).fill(InstantPrint.filterSelected)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == item ? .isSelected : [])
                .accessibilityLabel("\(item.title), \(count) samples")
                if item != ReviewFilter.allCases.last {
                    Rectangle().fill(InstantPrint.rule.opacity(filter == item ? 0 : 0.7)).frame(width: 1, height: 20)
                }
            }
        }
        .padding(2)
        .background(InstantPrint.filterTrack, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Contact sheet

    /// The open print takes the top-left corner at twice a print's size; two rows of prints fill the
    /// space beside it, and the rest of the set continues below in a wider grid.
    private func contactSheet(width: CGFloat) -> some View {
        let gap: CGFloat = 12
        let leadWidth = min(425, max(300, width * 0.33))
        let besideWidth = width - leadWidth - gap
        let besideColumns = max(1, Int((besideWidth + gap) / (150 + gap)))
        let besideCard = (besideWidth - CGFloat(besideColumns - 1) * gap) / CGFloat(besideColumns)
        let scale = leadWidth / 425
        let others = shown.filter { $0.id != lead?.id || selection.count > 1 }
        let beside = Array(others.prefix(besideColumns * 2))
        let below = Array(others.dropFirst(besideColumns * 2))
        let belowColumns = max(1, Int((width + 15) / (185 + 15)))
        let belowCard = (width - CGFloat(belowColumns - 1) * 15) / CGFloat(belowColumns)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: gap) {
                Group {
                    if selection.count > 1 {
                        batch
                    } else if let lead {
                        openPrint(lead, width: leadWidth)
                    }
                }
                .frame(width: leadWidth)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(besideCard), spacing: gap), count: besideColumns),
                    alignment: .leading, spacing: 9
                ) {
                    ForEach(beside) { image in print(image, photoHeight: 141 * scale) }
                }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(belowCard), spacing: 15), count: belowColumns),
                alignment: .leading, spacing: 8
            ) {
                ForEach(below) { image in print(image, photoHeight: (belowCard - 12) / 1.78) }
            }
        }
    }

    private func print(_ image: ProjectImage, photoHeight: CGFloat) -> some View {
        PrintCard(
            image: image, state: state(of: image), triggers: triggers, photoHeight: photoHeight,
            selected: selection.count > 1 && selection.contains(image.id)
        )
        .onTapGesture { choose(image) }
        .contextMenu {
            let excluded = state(of: image) == .excluded
            Button(excluded ? "Include in training" : "Exclude from training") {
                session.includeMedia(image.id, included: excluded)
            }
            if !excluded {
                Button("Compare captioning models…") { comparingImage = image }
            }
        }
        .accessibilityAddTraits(.isButton)
    }

    /// Click opens a print; ⌘-click adds it to (or removes it from) a set to re-caption together.
    private func choose(_ image: ProjectImage) {
        if NSEvent.modifierFlags.contains(.command) {
            var ids = selection
            if ids.contains(image.id) { ids.remove(image.id) } else { ids.insert(image.id) }
            session.reviewSelection = ids
        } else {
            session.reviewSelection = [image.id]
        }
        resultA = ""; resultB = ""
    }

    // MARK: The open print

    private func openPrint(_ image: ProjectImage, width: CGFloat) -> some View {
        let state = state(of: image)
        let excluded = state == .excluded
        return VStack(alignment: .leading, spacing: 0) {
            TrainingTargetPreview(url: image.url, fill: true)
                .frame(maxWidth: .infinity).frame(height: width * 0.656).clipped()
                .opacity(excluded ? 0.55 : 1)
                .overlay { if excluded { StrikeLine() } }
                .onTapGesture(count: 2) { inspectedImage = image }
                .help("Double-click to see the whole training target.")
            Text(triggers.joined(separator: ", "))
                .font(InstantPrint.display(size: 38 * width / 425)).tracking(3.5 * width / 425)
                .foregroundStyle(InstantPrint.ink)
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(.top, 1).padding(.bottom, 1).padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            if case let .attention(note?) = state {
                Text(note).font(.system(size: 12.5)).foregroundStyle(InstantPrint.ink)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(InstantPrint.attention, in: RoundedRectangle(cornerRadius: 5))
                    .padding(.bottom, 6)
            }
            TextEditor(text: textBinding(for: image))
                .font(.system(size: 14)).foregroundStyle(InstantPrint.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3).padding(.vertical, 2)
                .frame(height: 77)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(InstantPrint.rule, lineWidth: 1))
                .accessibilityLabel("Caption for \(image.id)")
                .disabled(session.editing || excluded)
            HStack(spacing: 9) {
                Button("Save caption") { save(image) }
                    .buttonStyle(PrintButtonStyle(kind: .secondary))
                    .disabled(session.editing || !session.hasUnsavedCaption(for: image))
                    .help("Save your edit (⌘S)")
                if excluded {
                    Button("Include") { session.includeMedia(image.id, included: true) }
                        .buttonStyle(PrintButtonStyle(kind: .primary))
                } else if image.isFinal, !session.hasUnsavedCaption(for: image) {
                    Button("Unmark final") { save(image, final: false) }
                        .buttonStyle(PrintButtonStyle(kind: .secondary))
                        .disabled(session.editing)
                } else {
                    Button("Mark final") { save(image, final: true) }
                        .buttonStyle(PrintButtonStyle(kind: .primary))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(session.editing || session.captionDraft(for: image).text.isBlank)
                        .help("Save this caption and protect it from model runs (⌘↩)")
                }
                Button("Re-caption") { session.caption(only: [image.id], overwrite: true) }
                    .buttonStyle(PrintButtonStyle(kind: .plain))
                    .disabled(session.busy || excluded || image.isFinal || session.hasUnsavedCaption(for: image))
                    .help("Ask the captioning model for a new caption. Final captions are protected.")
            }
            .padding(.top, 9)
        }
        .padding(8)
        .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(InstantPrint.developer, lineWidth: 2))
        .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
        .contextMenu {
            Button("Compare captioning models…") { comparingImage = image }.disabled(excluded)
            Button("Discard edits") { session.discardCaptionDraft(for: image) }
                .disabled(!session.hasUnsavedCaption(for: image))
        }
    }

    // MARK: Several prints

    private var batch: some View {
        let skipped = selectedImages.filter { $0.isFinal || session.hasUnsavedCaption(for: $0) }
        let eligible = Set(selectedImages.map(\.id)).subtracting(skipped.map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(selection.count) prints selected").font(.system(size: 20, weight: .semibold))
                .foregroundStyle(InstantPrint.ink)
            Text("Re-captioning replaces their model captions with new ones from your Captioning choices.")
                .font(.system(size: 13.5)).foregroundStyle(InstantPrint.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !skipped.isEmpty {
                Text("\(skipped.count) of them are skipped: final captions are protected, and prints with unsaved "
                    + "edits must be saved or discarded first.")
                    .font(.system(size: 13.5)).foregroundStyle(InstantPrint.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Re-caption \(eligible.count) prints") { session.caption(only: eligible, overwrite: true) }
                .buttonStyle(PrintButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.busy || eligible.isEmpty)
                .help("Re-caption the selected prints (⌘↩)")
            Text(session
                .demoMode ? "Prepared offline captions; no provider request." : "Uses your provider account credits.")
                .font(.system(size: 12.5)).foregroundStyle(InstantPrint.inkSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(InstantPrint.developer, lineWidth: 2))
    }

    /// Only while the single-photo editor is on screen; the batch panel has nothing for ⌘S to save.
    private var saveAction: CaptionSaveAction? {
        guard selection.count <= 1, let image = lead, state(of: image) != .excluded else { return nil }
        return CaptionSaveAction(
            save: { save(image) },
            disabled: session.editing || !session.hasUnsavedCaption(for: image)
        )
    }

    private func save(_ image: ProjectImage, final: Bool? = nil) {
        let draft = session.captionDraft(for: image)
        session.saveCaption(id: image.id, text: draft.text, final: final ?? draft.isFinal)
    }

    private func textBinding(for image: ProjectImage) -> Binding<String> {
        Binding(get: { session.captionDraft(for: image).text }, set: { text in
            var draft = session.captionDraft(for: image)
            draft.text = text
            session.setCaptionDraft(draft, for: image.id)
        })
    }
}

extension ReviewView {
    // MARK: Comparison

    private func comparisonSheet(for image: ProjectImage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compare captioning models · \(image.id)").font(.title3.weight(.semibold))
            comparison(for: image)
            HStack {
                Spacer()
                Button("Done") { comparingImage = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(minWidth: 620)
    }

    private func comparison(for image: ProjectImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Each model receives this exact image or clip and the same concept instructions. "
                + "The comparison does not replace the saved caption.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    choiceEditor("Model A", choice: $sideA).frame(minWidth: 260)
                    choiceEditor("Model B", choice: $sideB).frame(minWidth: 260)
                }
                VStack(alignment: .leading, spacing: 14) {
                    choiceEditor("Model A", choice: $sideA)
                    choiceEditor("Model B", choice: $sideB)
                }
            }
            HStack(spacing: 12) {
                Button(comparing ? "Comparing…" : "Compare models") { runComparison(id: image.id) }
                    .disabled(session.busy || comparing || sideA.model.isEmpty || sideB.model.isEmpty)
                Text(session
                    .demoMode ? "Prepared offline results; no provider requests." : "Uses credits from both accounts.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            if !resultA.isEmpty || !resultB.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        result(sideA, text: resultA).frame(minWidth: 260)
                        result(sideB, text: resultB).frame(minWidth: 260)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        result(sideA, text: resultA)
                        result(sideB, text: resultB)
                    }
                }
            }
        }
    }

    private func choiceEditor(_ title: String, choice: Binding<ComparisonChoice>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Form {
                Picker("Account", selection: choice.kind) {
                    ForEach(ProviderChoices.kinds, id: \.self) { Text(ProviderChoices.title($0)).tag($0) }
                }
                if choice.wrappedValue.kind == "openai", session.openAIUsesChatGPT, !session.demoMode {
                    ChatGPTModelPicker(title: "Model", model: choice.model, models: session.chatGPT.availableModels)
                } else {
                    TextField("Model", text: choice.model, prompt: Text("Model identifier"))
                }
            }.formStyle(.columns)
        }
        .onChange(of: choice.wrappedValue.kind) { _, new in
            guard !(new == "openai" && session.openAIUsesChatGPT) else { return }
            choice.wrappedValue.model = ProviderChoices.defaultModel(for: new)
        }
    }

    private func result(_ choice: ComparisonChoice, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(ProviderChoices.title(choice.kind)) · \(choice.model)").font(.headline).lineLimit(2)
            Text(text.isEmpty ? "Waiting…" : text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(text.isEmpty ? StudioStyle.supportingText : .primary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Runs model A, then model B, through the session's compare action; neither touches the saved caption.
    /// Results are written only while the same single photo is still shown; picking another photo mid-run
    /// abandons the comparison instead of labelling the old photo's captions with the new one.
    private func runComparison(id: String) {
        resultA = ""; resultB = ""
        comparing = true
        let sides = [sideA, sideB]
        Task {
            defer { comparing = false }
            for (index, side) in sides.enumerated() {
                session.comparison = ""
                session.compare(id: id, model: side.model, kind: side.kind)
                await session.task?.value
                guard comparingImage?.id == id else { return }
                guard session.errorMessage == nil, !session.comparison.isEmpty else { return }
                if index == 0 { resultA = session.comparison } else { resultB = session.comparison }
            }
            session.message = "Comparison ready. Your saved caption is unchanged."
        }
    }
}
