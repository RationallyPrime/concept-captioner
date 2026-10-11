import ConceptCore
import Foundation

@MainActor
extension StudioSession {
    func approveCrop(id: String, rectangle: CGRect) {
        guard !editing else { return }
        perform("Saving the approved training crop…") {
            guard let image = self.project?.images.first(where: { $0.id == id }) else { return }
            let data = try await Task.detached {
                try MediaEditor.cropped(Data(contentsOf: image.url), rectangle: rectangle)
            }.value
            try Task.checkCancellation()
            let previous = self.project?.mediaState.selections[id]
            let oldName = previous?.originalName ?? id
            let parentCrop = previous?.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let originalCrop = CGRect(
                x: parentCrop.minX + rectangle.minX * parentCrop.width,
                y: parentCrop.minY + rectangle.minY * parentCrop.height,
                width: rectangle.width * parentCrop.width, height: rectangle.height * parentCrop.height
            )
            try self.project?.approveTarget(
                id: id, data: data, name: Sources.stem(of: id) + ".png",
                selection: MediaSelection(originalName: oldName, crop: originalCrop)
            )
            self.selectedImageID = Sources.stem(of: id) + ".png"
            self.invalidateMediaDraft(id: id)
            self.mediaDidChange()
        }
    }

    func approveVideoSegment(id: String, startFrame: Int, frameCount: Int, longEdge: Int) {
        guard !editing else { return }
        perform("Exporting the approved training segment…") {
            guard let image = self.project?.images.first(where: { $0.id == id }) else { return }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("segment-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let selected = try await MediaEditor.trim(
                url: image.url, startFrame: startFrame, frameCount: frameCount, longEdge: longEdge, output: output
            )
            try Task.checkCancellation()
            let previous = self.project?.mediaState.selections[id]
            let offset = previous?.startSeconds ?? 0
            try self.project?.approveTarget(
                id: id, data: Data(contentsOf: output), name: Sources.stem(of: id) + ".mp4",
                selection: MediaSelection(
                    originalName: previous?.originalName ?? id,
                    startSeconds: offset + selected.range.start.seconds,
                    endSeconds: offset + selected.range.end.seconds,
                    frameCount: frameCount, videoWidth: selected.info.width, videoHeight: selected.info.height
                )
            )
            self.selectedImageID = Sources.stem(of: id) + ".mp4"
            self.invalidateMediaDraft(id: id)
            self.mediaDidChange()
        }
    }

    private func mediaDidChange() {
        PhotoThumbnails.removeAll()
        startImageAnalysis()
        message = "Approved target saved. Confirm its mapping and caption this exact crop or segment. "
            + "Undo restores the previous target."
    }
}
