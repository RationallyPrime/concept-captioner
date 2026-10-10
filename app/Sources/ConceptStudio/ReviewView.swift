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
    @State private var compareModel = "google/gemini-3.8-flash"
    @State private var compareKind = "openrouter"
    @State private var selected: Set<String> = []

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your captions").font(.headline).padding(.horizontal, 8)
                List(session.project?.images ?? [], selection: $session.selectedImageID) { image in
                    HStack(spacing: 8) {
                        Toggle("Select \(image.id) for re-captioning", isOn: Binding(
                            get: { selected.contains(image.id) },
                            set: { if $0 { selected.insert(image.id) } else { selected.remove(image.id) } }
                        ))
                        .labelsHidden().help("Select this photo for re-captioning")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(image.id).lineLimit(2).truncationMode(.middle)
                            if session.hasUnsavedCaption(for: image) {
                                Label("Unsaved edits", systemImage: "pencil").font(.caption)
                            } else if image.isFinal {
                                Label("Final", systemImage: "lock.fill").font(.caption)
                            }
                        }
                    }.tag(image.id)
                }
                Button("Re-caption selected (\(selected.count))") {
                    session.caption(only: selected, overwrite: true)
                }.disabled(session.busy || selected.isEmpty)
            }.frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
            ScrollView {
                if let image = session.selectedImage {
                    VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                        StudioSection(
                            title: image.id,
                            subtitle: "Describe what can change. Your learning words hold the concept."
                        ) {
                            if !image.notes.isEmpty {
                                StudioNotice(image.notes.joined(separator: "\n"), symbol: "text.bubble")
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 24) {
                                    PhotoView(url: image.url).frame(width: 240, height: 280)
                                    captionEditor(for: image).frame(minWidth: 280)
                                }
                                VStack(alignment: .leading, spacing: 18) {
                                    PhotoView(url: image.url).frame(maxWidth: .infinity).frame(height: 200)
                                    captionEditor(for: image)
                                }
                            }
                        }
                        Divider()
                        DisclosureGroup("Compare another model") {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Account", selection: $compareKind) {
                                    ForEach(ModelChoices.providers, id: \.self) { Text(ModelChoices.title($0)).tag($0) }
                                }
                                TextField("Model", text: $compareModel)
                                Text("A comparison uses your provider credits and leaves the saved caption unchanged.")
                                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                                Button("Compare without replacing saved caption") {
                                    session.compare(id: image.id, model: compareModel, kind: compareKind)
                                }.disabled(session.busy)
                                if !session.comparison.isEmpty {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(alignment: .top, spacing: 20) {
                                            comparison("Saved caption", text: image.caption).frame(minWidth: 260)
                                            comparison("Comparison", text: session.comparison).frame(minWidth: 260)
                                        }
                                        VStack(alignment: .leading, spacing: 20) {
                                            comparison("Saved caption", text: image.caption)
                                            comparison("Comparison", text: session.comparison)
                                        }
                                    }
                                }
                            }.padding(.top, 12)
                        }
                    }.padding(.leading, 20)
                } else {
                    ContentUnavailableView(
                        "Choose a caption to review",
                        systemImage: "checkmark.bubble",
                        description: Text("Select a photo from the list to edit or compare its caption.")
                    )
                }
            }
        }
        .focusedSceneValue(\.captionSaveAction, saveAction)
        .onChange(of: session.selectedImageID) { _, _ in session.comparison = "" }
    }

    private func captionEditor(for image: ProjectImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: textBinding(for: image)).frame(minHeight: 150)
                .padding(6).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Caption for \(image.id)")
                .disabled(session.busy)
            Toggle("Final · protect this caption from model runs", isOn: finalBinding(for: image))
                .disabled(session.busy)
            if session.hasUnsavedCaption(for: image) {
                StudioNotice(
                    "Unsaved edits stay here when you change photos or screens. "
                        + "Save to keep them on disk. Closing or switching projects will ask before discarding them.",
                    symbol: "pencil"
                )
            }
            HStack(spacing: 12) {
                Button("Save caption") { save(image) }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                Button("Discard edits") { session.discardCaptionDraft(for: image) }
            }.disabled(session.busy || !session.hasUnsavedCaption(for: image))
            Button("Re-caption this photo") { session.caption(only: [image.id], overwrite: true) }
                .disabled(session.busy || image.isFinal || session.hasUnsavedCaption(for: image))
                .help("Save or discard edits first. Final captions are protected.")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var saveAction: CaptionSaveAction? {
        guard let image = session.selectedImage else { return nil }
        return CaptionSaveAction(
            save: { save(image) },
            disabled: session.busy || !session.hasUnsavedCaption(for: image)
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

    private func comparison(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
