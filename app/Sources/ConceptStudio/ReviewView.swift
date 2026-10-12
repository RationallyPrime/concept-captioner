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
    @State private var sideA = ComparisonChoice(kind: "", model: "")
    @State private var sideB = ComparisonChoice(kind: "", model: "")
    @State private var resultA = ""
    @State private var resultB = ""
    @State private var comparing = false

    struct ComparisonChoice: Equatable {
        var kind: String
        var model: String
    }

    private var images: [ProjectImage] {
        session.project?.images ?? []
    }

    /// Native list selection: one photo opens its editor; ⌘- or ⇧-click selects several to re-caption.
    /// Ids from another project (the selection outlives a project switch) are ignored.
    private var selection: Set<String> {
        session.reviewSelection.intersection(images.map(\.id))
    }

    private var selectedImages: [ProjectImage] {
        images.filter { selection.contains($0.id) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your captions").font(.headline)
                    Text("⌘- or ⇧-click to select several").font(.caption)
                        .foregroundStyle(StudioStyle.supportingText)
                }.padding(.horizontal, 8)
                List(images, selection: $session.reviewSelection) { image in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image.id).lineLimit(2).truncationMode(.middle)
                        if session.hasUnsavedCaption(for: image) {
                            Label("Unsaved edits", systemImage: "pencil").font(.caption)
                        } else if image.isFinal {
                            Label("Final", systemImage: "lock.fill").font(.caption)
                        } else if image.caption.isEmpty {
                            Label("No caption yet", systemImage: "circle").font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(image.id)
                }
            }.frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
            GeometryReader { geometry in
                ScrollView {
                    if selection.count > 1 {
                        batch.padding(.leading, 20)
                    } else if let image = session.selectedImage, selection.contains(image.id) {
                        detail(for: image, availableWidth: max(0, geometry.size.width - 20)).padding(.leading, 20)
                    } else {
                        ContentUnavailableView(
                            "Choose a caption to review",
                            systemImage: "checkmark.bubble",
                            description: Text("Select one sample to edit or compare its caption, "
                                + "or several to re-caption them together.")
                        )
                    }
                }
            }
        }
        .focusedSceneValue(\.captionSaveAction, saveAction)
        .onAppear {
            if selection.isEmpty, let id = session.selectedImageID { session.reviewSelection = [id] }
            if sideA.kind.isEmpty { sideA = ComparisonChoice(kind: session.endpointKind, model: session.modelName) }
            if sideB.kind.isEmpty { sideB = ComparisonChoice(kind: session.endpointKind, model: "") }
        }
        .onChange(of: session.reviewSelection) { _, ids in
            if ids.count == 1, let id = ids.first { session.selectedImageID = id }
            resultA = ""; resultB = ""
        }
        .onChange(of: session.selectedImageID) { _, id in
            if let id, selection.count <= 1, !selection.contains(id) { session.reviewSelection = [id] }
        }
    }

    // MARK: Several photos

    private var batch: some View {
        let skipped = selectedImages.filter { $0.isFinal || session.hasUnsavedCaption(for: $0) }
        let eligible = Set(selectedImages.map(\.id)).subtracting(skipped.map(\.id))
        return StudioSection(
            title: "\(selection.count) samples selected",
            subtitle: "Re-captioning replaces their model captions with new ones from your Captioning choices."
        ) {
            if !skipped.isEmpty {
                StudioNotice(
                    "\(skipped.count) of them are skipped: final captions are protected, and samples with unsaved "
                        + "edits must be saved or discarded first.",
                    symbol: "lock"
                )
            }
            Button("Re-caption \(eligible.count) samples", systemImage: "arrow.clockwise") {
                session.caption(only: eligible, overwrite: true)
            }
            .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Re-caption the selected samples (⌘↩)")
            .disabled(session.busy || eligible.isEmpty)
            Text(session
                .demoMode ? "Prepared offline captions; no provider request." : "Uses your provider account credits.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
        }
    }

    // MARK: One photo

    private func detail(for image: ProjectImage, availableWidth: CGFloat) -> some View {
        let photoWidth: CGFloat = 240
        let captionWidth: CGFloat = 280
        let columnSpacing: CGFloat = 24
        return VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
            StudioSection(
                title: image.id,
                subtitle: "Check the caption against this exact training target. The trigger names the concept; "
                    + "the remaining text should describe the visible details outside it."
            ) {
                if !image.notes.isEmpty {
                    StudioNotice(image.notes.joined(separator: "\n"), symbol: "text.bubble")
                }
                if availableWidth >= photoWidth + columnSpacing + captionWidth {
                    HStack(alignment: .top, spacing: columnSpacing) {
                        TrainingTargetPreview(url: image.url).frame(width: photoWidth, height: 280)
                        captionEditor(for: image).frame(minWidth: captionWidth, maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        TrainingTargetPreview(url: image.url).frame(maxWidth: .infinity).frame(height: 200)
                        captionEditor(for: image)
                    }
                }
            }
            Divider()
            DisclosureGroup("Compare captioning models") {
                comparison(for: image).padding(.top, 12)
            }
        }.frame(width: availableWidth, alignment: .leading)
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
                guard session.reviewSelection == [id], session.selectedImageID == id else { return }
                guard session.errorMessage == nil, !session.comparison.isEmpty else { return }
                if index == 0 { resultA = session.comparison } else { resultB = session.comparison }
            }
            session.message = "Comparison ready. Your saved caption is unchanged."
        }
    }

    private func captionEditor(for image: ProjectImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: textBinding(for: image)).font(.body).frame(minHeight: 150)
                .padding(6).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Caption for \(image.id)")
                .disabled(session.editing)
            Toggle("Final · protect this caption from model runs", isOn: finalBinding(for: image))
                .disabled(session.editing)
            if session.hasUnsavedCaption(for: image) {
                StudioNotice(
                    "Unsaved edits stay here when you change samples or screens. "
                        + "Save to keep them on disk. Closing or switching projects will ask before discarding them.",
                    symbol: "pencil"
                )
            }
            HStack(spacing: 12) {
                Button("Save caption") { save(image) }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                Button("Discard edits") { session.discardCaptionDraft(for: image) }
            }.disabled(session.editing || !session.hasUnsavedCaption(for: image))
            Button("Re-caption this sample") { session.caption(only: [image.id], overwrite: true) }
                .disabled(session.busy || image.isFinal || session.hasUnsavedCaption(for: image))
                .help("Save or discard edits first. Final captions are protected.")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only while the single-photo editor is on screen; the batch panel has nothing for ⌘S to save.
    private var saveAction: CaptionSaveAction? {
        guard selection.count == 1, let image = session.selectedImage, selection.contains(image.id) else {
            return nil
        }
        return CaptionSaveAction(
            save: { save(image) },
            disabled: session.editing || !session.hasUnsavedCaption(for: image)
        )
    }

    private func save(_ image: ProjectImage) {
        let draft = session.captionDraft(for: image)
        session.saveCaption(id: image.id, text: draft.text, final: draft.isFinal)
    }

    private func textBinding(for image: ProjectImage) -> Binding<String> {
        Binding(get: { session.captionDraft(for: image).text }, set: { text in
            var draft = session.captionDraft(for: image)
            draft.text = text
            session.setCaptionDraft(draft, for: image.id)
        })
    }

    private func finalBinding(for image: ProjectImage) -> Binding<Bool> {
        Binding(get: { session.captionDraft(for: image).isFinal }, set: { final in
            var draft = session.captionDraft(for: image)
            draft.isFinal = final
            session.setCaptionDraft(draft, for: image.id)
        })
    }
}
