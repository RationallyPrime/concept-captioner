import PhotosUI
import SwiftUI

struct ImagesView: View {
    @Bindable var session: StudioSession
    @State private var photos: [PhotosPickerItem] = []
    @State private var hubRepo = ""
    @State private var showHub = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button("Import folder…", systemImage: "folder") { session.importFolder() }
                    Button("Choose photos…") { session.importImages(ProjectAccess.chooseImages()) }
                    PhotosPicker(selection: $photos, matching: .images) { Label("Apple Photos", systemImage: "photo") }
                        .disabled(session.demoMode)
                    Button("Hugging Face dataset…") { showHub = true }
                }.disabled(session.busy)
                Text(
                    "Choose varied scenes and clothing. Your originals stay where they are; "
                        + "copies go into this project."
                )
                .foregroundStyle(.secondary)
                if session.project?.images.isEmpty == true {
                    ContentUnavailableView(
                        "Add your first photos",
                        systemImage: "photo.on.rectangle",
                        description: Text("Import a folder, pick from Photos, or download an imagefolder dataset.")
                    )
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 18) {
                    ForEach(session.project?.images ?? []) { image in
                        VStack(alignment: .leading, spacing: 8) {
                            PhotoView(url: image.url).frame(height: 175).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(image.id).font(.caption).lineLimit(1)
                            ForEach(session.analyses[image.id]?.warnings ?? [], id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle").font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                Button("Ask for dataset advice", systemImage: "sparkles") { session.datasetCritique() }
                    .disabled(session.busy || session.project?.images.isEmpty != false)
                Text(session
                    .demoMode ? "Offline advice, no account required." :
                    "Uses your selected captioning provider. Set up a gateway key in Settings first.")
                    .font(.caption).foregroundStyle(.secondary)
                if !session.datasetAdvice.isEmpty {
                    GroupBox("Before spending on training") { Text(session.datasetAdvice).frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    ) }
                }
            }
        }
        .onChange(of: photos) { _, items in session.importPhotos(items); photos = [] }
        .sheet(isPresented: $showHub) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import a Hugging Face dataset").font(.title2.bold())
                Text(
                    "Enter owner/dataset. This app reads imagefolder datasets; "
                        + "parquet-only datasets need conversion first."
                )
                TextField("owner/dataset", text: $hubRepo)
                HStack {
                    Button("Cancel") { showHub = false }
                    Button("Download images") { session.importHub(hubRepo); showHub = false }
                        .buttonStyle(.borderedProminent).disabled(hubRepo.isEmpty)
                }
            }.padding(28).frame(width: 490)
        }
    }
}

struct PhotoView: View {
    let url: URL
    var faces: [CGRect] = []

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                            RoundedRectangle(cornerRadius: 5).stroke(.mint, lineWidth: 2)
                                .overlay(alignment: .topLeading) {
                                    Text("\(index + 1)").font(.caption.bold()).padding(3).background(.mint)
                                }
                                .frame(
                                    width: face.width * geometry.size.width,
                                    height: face.height * geometry.size.height
                                )
                                .position(x: face.midX * geometry.size.width, y: (1 - face.midY) * geometry.size.height)
                        }
                    }
                }
                .accessibilityLabel(url.lastPathComponent)
        } else {
            ContentUnavailableView("Cannot read this photo", systemImage: "photo")
        }
    }
}
