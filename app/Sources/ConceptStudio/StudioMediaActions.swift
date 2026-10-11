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

    func approveVideoSegment(
        id: String, startFrame: Int, frameCount: Int, longEdge: Int, format: VideoTrainingFormat
    ) {
        guard !editing else { return }
        let profileAtApproval = project?.job.profile
        perform("Exporting the approved training segment…") {
            guard let image = self.project?.images.first(where: { $0.id == id }) else { return }
            _ = try self.selectedSkill().profile(format.rawValue)
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("segment-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let selected = try await MediaEditor.trim(
                url: image.url, startFrame: startFrame, frameCount: frameCount, longEdge: longEdge, output: output,
                format: format
            )
            try Task.checkCancellation()
            guard self.project?.job.profile == profileAtApproval else {
                throw StudioError.message("The project's caption format changed while this segment was exporting. "
                    + "Review the selected training model and approve again; no target was replaced.")
            }
            let previous = self.project?.mediaState.selections[id]
            let offset = previous?.startSeconds ?? 0
            let previousProfile = self.project?.job.profile
            try self.project?.approveTarget(
                id: id, sourceFile: output, name: Sources.stem(of: id) + ".mp4",
                selection: MediaSelection(
                    originalName: previous?.originalName ?? id,
                    startSeconds: offset + selected.range.start.seconds,
                    endSeconds: offset + selected.range.end.seconds,
                    frameCount: frameCount, videoWidth: selected.info.width, videoHeight: selected.info.height
                ), profile: format.rawValue
            )
            self.selectedImageID = Sources.stem(of: id) + ".mp4"
            self.invalidateMediaDraft(id: id)
            self.updateTrainingProjectDefaults()
            self.mediaDidChange()
            if previousProfile != format.rawValue {
                let otherCaptions = self.project?.images
                    .count { $0.id != self.selectedImageID && !$0.caption.isEmpty } ?? 0
                self.message += " The project now uses \(format.title) video captions."
                if otherCaptions > 0 {
                    self.message += " \(otherCaptions) other saved captions keep their text; "
                        + "review or re-caption them for the new format."
                }
            }
        }
    }

    private func mediaDidChange() {
        PhotoThumbnails.removeAll()
        startImageAnalysis()
        message = "Approved target saved. "
            + (project?.job.requiresLocatorMapping == true ? "Confirm its mapping, then caption " : "Caption ")
            + "this exact crop or segment. Undo restores the previous target."
    }
}
