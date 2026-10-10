import SwiftUI

struct ReviewView: View {
    @Bindable var session: StudioSession
    @State private var text = ""
    @State private var final = false
    @State private var compareModel = "google/gemini-3.8-flash"
    @State private var compareKind = "openrouter"
    @State private var selected: Set<String> = []

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(session.project?.images ?? [], selection: $session.selectedImageID) { image in
                    HStack {
                        Toggle("", isOn: Binding(get: { selected.contains(image.id) }, set: {
                            if $0 { selected.insert(image.id) } else { selected.remove(image.id) }
                        })).labelsHidden().help("Select for re-captioning")
                        Label(image.id, systemImage: image.isFinal ? "lock.fill" : "photo").tag(image.id)
                    }.tag(image.id)
                }
                Button("Re-caption selected (\(selected.count))") { session.caption(only: selected, overwrite: true) }
                    .disabled(session.busy || selected.isEmpty)
            }.frame(minWidth: 170, idealWidth: 210, maxWidth: 260)
            ScrollView {
                if let image = session.selectedImage {
                    VStack(alignment: .leading, spacing: 18) {
                        PhotoView(url: image.url).frame(height: 300)
                        Text(image.notes.joined(separator: "\n")).foregroundStyle(.secondary)
                        TextEditor(text: $text).frame(minHeight: 100).border(.quaternary)
                            .accessibilityLabel("Caption text")
                        Toggle("Final — protect this caption from every model run", isOn: $final)
                        HStack {
                            Button("Save caption") { session.saveCaption(id: image.id, text: text, final: final) }
                                .buttonStyle(.borderedProminent)
                            Button("Re-caption this photo") { session.caption(only: [image.id], overwrite: true) }
                                .disabled(image.isFinal)
                        }.disabled(session.busy)
                        DisclosureGroup("Compare another model") {
                            Picker("Account", selection: $compareKind) {
                                ForEach(ModelChoices.providers, id: \.self) { Text(ModelChoices.title($0)).tag($0) }
                            }
                            TextField("Model", text: $compareModel)
                            Button("Compare without replacing saved caption") { session.compare(
                                id: image.id,
                                model: compareModel,
                                kind: compareKind
                            ) }
                            .disabled(session.busy)
                            if !session.comparison.isEmpty {
                                HStack(alignment: .top, spacing: 20) {
                                    GroupBox("Saved caption") { Text(image.caption).textSelection(.enabled) }
                                    GroupBox("Comparison") { Text(session.comparison).textSelection(.enabled) }
                                }
                            }
                        }
                    }.padding(.leading, 20)
                } else { ContentUnavailableView("Choose a caption to review", systemImage: "checkmark.bubble") }
            }
        }
        .onAppear { load() }
        .onChange(of: session.selectedImageID) { _, _ in load(); session.comparison = "" }
        .onChange(of: session.selectedImage?.caption) { _, _ in load() }
    }

    private func load() {
        text = session.selectedImage?.caption ?? ""; final = session.selectedImage?.isFinal ?? false
    }
}
