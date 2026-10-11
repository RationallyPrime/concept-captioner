import AppKit
import ConceptCore
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension StudioSession {
    func usePodCaptionServer() {
        perform("Starting your computer's caption server…") {
            guard await self.gpu.startCaptioning(), let url = self.gpu.captionEndpoint else {
                throw StudioError.message(self.gpu.message)
            }
            self.requestBaseURL = url.absoluteString
            self.usingPodCaptioner = true
            self.endpointKind = "vllm"
            self.modelName = self.gpu.captionModel
            self.step = .captioning
            self.message = "Caption server ready. Caption first; training will free the same GPU when you start it."
        }
    }

    var references: [String: URL] {
        guard let project else { return [:] }
        return Dictionary(uniqueKeysWithValues: project.job.concepts.compactMap { concept in
            let url = project.referenceURL(for: concept.trigger)
            return FileManager.default.fileExists(atPath: url.path) ? (concept.trigger, url) : nil
        })
    }

    /// Save `source` (chosen by the view, e.g. with `ProjectAccess.chooseImages`) as the reference face.
    func chooseReference(trigger: String, from source: URL) {
        guard let project else { return }
        do {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(
                      using: .png,
                      properties: [:]
                  )
            else { throw StudioError.message("Choose a clear photo containing the reference face.") }
            let target = project.referenceURL(for: trigger)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFile.write(data, to: target)
            message = "Reference saved. Suggestions always need your confirmation."
        } catch { errorMessage = Self.describe(error) }
    }

    /// Import photos picked with the permission-free PhotosPicker. Files get readable, stable names
    /// (see `PhotoImportName`); formats the pipeline cannot read (HEIC, TIFF, ...) become JPEG.
    func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        perform("Importing selected photos…") {
            var added = 0
            var already = 0
            for item in items {
                try Task.checkCancellation()
                guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else { continue }
                let (data, suffix) = try PhotoImportName.readable(picked.data)
                let name = PhotoImportName.make(
                    suggested: picked.suggestedName,
                    captured: PhotoImportName.captureDate(data),
                    data: data,
                    suffix: suffix
                )
                if self.project?.images.contains(where: { $0.id == name }) == true {
                    already += 1
                } else {
                    _ = try self.project?.importData(data, name: name)
                    added += 1
                }
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            self.startImageAnalysis()
            self.message = "\(added) photos imported. Originals in Photos are unchanged."
                + (already > 0 ? " \(already) were already in this project and were skipped." : "")
        }
    }

    func importHub(_ id: String) {
        perform("Downloading dataset photos…") {
            guard !self.demoMode else {
                self.message = "Demo dataset imported locally. No Hub connection was used."
                return
            }
            let client = try HubClient(token: self.keyStore.read("huggingface"))
            let source = try await HubFolderSource.open(client: client, repo: RepoID(id))
            for try await sample in source.samples() {
                try Task.checkCancellation()
                guard let name = try self.project?.importData(sample.data, name: sample.sampleID),
                      let project = self.project else { return }
                if let row = source.rows.first(where: { $0.fileName == sample.sampleID }),
                   row.record != nil || row.caption != nil {
                    // A caption without its own record is kept as a model caption marked as imported;
                    // Review offers to protect imported captions as final.
                    var record = row.record ?? ResponseRecord(
                        sampleID: name,
                        status: .written,
                        skill: project.skillName,
                        profile: project.job.profile,
                        captioner: ModelNames(requested: ProjectImage.importedCaptioner),
                        critic: nil
                    )
                    record.sampleID = name
                    try await SidecarSink(directory: project.imagesDirectory)
                        .write(name, caption: row.caption, record: record)
                    if let index = self.project?.images.firstIndex(where: { $0.id == name }) {
                        self.project?.images[index].caption = row.caption ?? ""
                        self.project?.images[index].isFinal = record.isHumanFinal
                        self.project?.images[index].isImported = ProjectImage.isImported(record)
                    }
                }
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            self.startImageAnalysis()
            self.message = "Dataset downloaded. Confirm its subject mapping before captioning."
                + (self.unprotectedImportedCount > 0
                    ? " Imported captions are not protected yet; protect them on Review to keep them." : "")
        }
    }

    /// Imported captions that a re-caption with overwrite could still replace.
    var unprotectedImportedCount: Int {
        project?.images.count(where: { $0.isImported && !$0.isFinal && !$0.caption.isBlank }) ?? 0
    }

    /// Mark every imported caption final (`source: human`), the same flag Review's Final toggle sets.
    func protectImportedCaptions() {
        guard let project else { return }
        let targets = project.images.filter { image in
            image.isImported && !image.isFinal && !image.caption.isBlank && !runPendingIDs.contains(image.id)
        }
        guard !targets.isEmpty else {
            message = runPendingIDs.isEmpty
                ? "Every imported caption is already protected."
                : "The remaining imported captions are part of the current run. Try again when it finishes."
            return
        }
        perform("Protecting imported captions…", gate: .edit) {
            for image in targets {
                try Task.checkCancellation()
                try await StudioProject.writeCaption(
                    id: image.id, text: image.caption, final: true, imagesDirectory: project.imagesDirectory,
                    skill: project.skillName, profile: project.job.profile
                )
                self.project?.applySavedCaption(id: image.id, text: image.caption, final: true)
            }
            self.message = "\(targets.count) imported captions are now final. Model runs will skip them."
        }
    }

    func datasetCritique() {
        perform("Reviewing your image set…") {
            guard let project = self.project else { return }
            let assistant = try StudioAssistant(endpoint: self.endpoint(), demo: self.demoMode)
            self.datasetAdvice = try await assistant.critique(project, warnings: self.analyses) { done, total in
                self.message = "Reviewing your image set… \(done) of \(total) photos"
            }
            self.message = "Dataset advice ready. Review it before spending on training."
        }
    }

    func draftBoundary(description: String, apply: @escaping (BoundaryDraft) -> Void) {
        perform("Drafting your learning boundary…") {
            let assistant = try StudioAssistant(endpoint: self.endpoint(), demo: self.demoMode)
            try await apply(assistant.draftBoundary(description))
            self.message = "Draft ready. Check what should be learned, then save your decision."
        }
    }

    func saveConcept(_ concept: Concept, replacing oldTrigger: String?) throws {
        guard var project else { return }
        if let oldTrigger, let index = project.job.concepts.firstIndex(where: { $0.trigger == oldTrigger }) {
            project.job.concepts[index] = concept
            if oldTrigger != concept.trigger {
                for (id, oldMapping) in project.job.samples {
                    guard var mapping = oldMapping else { continue }
                    if let locator = mapping[oldTrigger] {
                        mapping[oldTrigger] = nil; mapping[concept.trigger] = locator
                    }
                    try project.job.setMapping(mapping, for: id)
                }
                let oldReference = project.referenceURL(for: oldTrigger)
                if FileManager.default.fileExists(atPath: oldReference.path) {
                    try FileManager.default.moveItem(at: oldReference, to: project.referenceURL(for: concept.trigger))
                }
            }
        } else { project.job.concepts.append(concept) }
        project.job = try Job(json: project.job.jsonValue)
        try project.save()
        self.project = project
        message = "Concept saved. The learning word holds only the traits you chose."
    }

    func confirmMapping(id: String, mapping: Job.Mapping) {
        do {
            try project?.job.setMapping(mapping, for: id)
            try project?.save()
            mappingProposals[id] = nil
            message = "Mapping confirmed and saved."
        } catch { errorMessage = Self.describe(error) }
    }

    func proposeMappings(useModel: Bool) {
        perform(useModel ? "Asking for reference-based mapping proposals…" : "Comparing faces on your Mac…") {
            guard let project = self.project else { return }
            var references = self.references
            if self.demoMode, references.isEmpty, let first = project.images.first {
                references = [project.job.concepts[0].trigger: first.url]
            }
            guard !references.isEmpty else {
                throw StudioError.message("Add a reference face in Concepts, then ask for suggestions.")
            }
            if useModel {
                let assistant = try StudioAssistant(endpoint: self.endpoint(), demo: self.demoMode)
                for image in project.images {
                    try Task.checkCancellation()
                    self.mappingProposals[image.id] = try await assistant.proposeMapping(
                        image: image.url,
                        references: references
                    )
                    self.completed += 1
                }
            } else {
                self.mappingProposals = try await self.inspector.proposals(
                    images: project.images.map(\.url),
                    references: references
                )
            }
            self.message = "Suggestions ready. Check each photo and confirm; no mapping was changed automatically."
        }
    }

    func caption(only: Set<String>? = nil, overwrite: Bool = false) {
        perform("Writing captions…") {
            guard var project = self.project else { return }
            try project.update(job: self.jobForCaptioning())
            self.project = project
            self.rememberChoices()
            let resolved = try self.endpoint()
            self.gpu.noteActivity()
            let critic = self.useCritic ? try self.endpoint(
                model: self.criticModel,
                kind: self.criticKind,
                settings: project.job.endpoints?.critic?.settings ?? [:],
                thinking: self.criticThinking,
                baseURL: self.criticTargetURL
            ) : nil
            let runner = try Runner(
                job: project.job,
                captioner: resolved,
                critic: critic,
                skill: self.selectedSkill(),
                concurrency: self.concurrency,
                overwrite: overwrite
            )
            let source = try LocalFolderSource(directory: project.imagesDirectory)
            let sink = try SidecarSink(directory: project.imagesDirectory)
            self.runPendingIDs = only ?? Set(project.images.map(\.id))
            defer { self.runPendingIDs = [] }
            _ = try await runner.run(source: source, sink: sink, only: only) { outcome in
                await self.receive(outcome)
            }
            self.message = "Captioning finished. Review each result beside its photo."
        }
    }

    func receive(_ outcome: Outcome) {
        gpu.noteActivity()
        runPendingIDs.remove(outcome.sampleID)
        project?.apply(outcome)
        completed += 1
        message = "\(completed) photos processed · \(outcome.sampleID): \(outcome.status.rawValue)"
    }

    /// Save a caption edit. Uses the edit gate, so it works while a caption run is in progress,
    /// except for a photo that run has not reached yet.
    func saveCaption(id: String, text: String, final: Bool) {
        guard !runPendingIDs.contains(id) else {
            errorMessage = "\(id) is still being captioned by the current run. Your edit is kept as a draft; "
                + "save it after this photo's new caption arrives, or cancel the run."
            return
        }
        perform("Saving caption…", gate: .edit) {
            guard !text.isBlank else {
                throw StudioError.message("Write a caption before saving or protecting it as final.")
            }
            guard let project = self.project else { return }
            try await StudioProject.writeCaption(
                id: id, text: text, final: final, imagesDirectory: project.imagesDirectory,
                skill: project.skillName, profile: project.job.profile
            )
            self.project?.applySavedCaption(id: id, text: text, final: final)
            self.clearSavedCaptionDraft(CaptionDraft(text: text, isFinal: final), for: id)
            self.message = final ? "Final caption saved. Model runs will skip it." : "Caption saved."
        }
    }

    func compare(id: String, model: String, kind: String) {
        perform("Comparing another model without changing your saved caption…") {
            guard let project = self.project else { return }
            let runner = try Runner(
                job: project.job,
                captioner: self.endpoint(model: model, kind: kind),
                skill: self.selectedSkill(),
                overwrite: true
            )
            let result = try await runner.run(
                source: LocalFolderSource(directory: project.imagesDirectory),
                sink: ComparisonSink(),
                only: [id]
            )
            let outcome = result.outcomes.first
            self.comparison = outcome?.caption ?? outcome?.notes.joined(separator: "\n") ?? "No result."
            self.message = "Comparison ready. Your saved caption is unchanged."
        }
    }

    func publish() {
        perform("Preparing your Hub dataset…") {
            guard let project = self.project, !project.images.isEmpty else {
                throw StudioError.message("Import photos before publishing your dataset.")
            }
            try project.save()
            let operations = try await ProjectPublisher.operations(for: project)
            if self.demoMode {
                for index in operations.indices {
                    try await Task.sleep(for: .milliseconds(50))
                    self.completed = index + 1
                }
                self.message = "Demo dataset prepared: photos, captions, response records and job file. "
                    + "No upload or money spent."
            } else {
                let client = try HubClient(token: self.keyStore.read("huggingface"))
                guard client.token?.isEmpty == false else {
                    throw StudioError.message("Save your Hugging Face write token in Settings before publishing.")
                }
                let repo = try RepoID(self.repoID)
                try await client.createRepo(repo, private: self.privateDataset)
                let commit = try await client.commit(
                    repo: repo,
                    operations: operations,
                    message: "Publish ConceptStudio project"
                ) { progress in
                    Task { @MainActor in self.message = "\(progress.phase.rawValue): \(progress.path ?? "dataset")" }
                }
                self.message = "Dataset published. " + commit.commitURL
            }
            self.rememberChoices()
        }
    }

    /// App-wide defaults for the next project: model choices and the pod setup. The dataset and
    /// training destinations are per project (`projectState`), never app-wide.
    func rememberChoices() {
        guard !demoMode else { return }
        preferences.set(openAIUsesChatGPT, forKey: "openAIUsesChatGPT")
        normalizePodImageChoice()
        for (key, value) in [
            "endpointKind": endpointKind,
            "modelName": modelName,
            "vllmBaseURL": customBaseURL,
            "podImage": podImageName,
            "volumeID": volumeID,
        ] {
            preferences.set(value, forKey: key)
        }
        preferences.removeObject(forKey: "hubRepo")
    }
}

/// A photo handed over by PhotosPicker, with the file name Photos suggests when it shares a file.
struct PickedPhoto: Transferable {
    let data: Data
    let suggestedName: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try PickedPhoto(data: Data(contentsOf: received.file), suggestedName: received.file.lastPathComponent)
        }
        DataRepresentation(importedContentType: .image) { data in
            PickedPhoto(data: data, suggestedName: nil)
        }
    }
}

/// Readable, stable names for photos imported from Apple Photos: the name Photos suggests (or the
/// capture date) plus a short content hash, so importing the same photo again yields the same name.
enum PhotoImportName {
    static func make(suggested: String?, captured: Date?, data: Data, suffix: String) -> String {
        let hash = String(VisionInspector.contentHash(data).prefix(8))
        let stem: String = if let readable = suggested.flatMap(readableStem) {
            readable
        } else if let captured {
            "photo-" + dateStem(captured)
        } else {
            "photo"
        }
        return "\(stem)-\(hash).\(suffix)"
    }

    /// The photo's bytes in a format the captioning pipeline reads, with the matching suffix.
    /// PNG, JPEG and WebP pass through; anything else (HEIC, TIFF, ...) is converted to JPEG.
    static func readable(_ data: Data) throws -> (Data, String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil else {
            throw StudioError.message("This photo could not be read. Export it from Photos and import the file.")
        }
        if let suffix = type.preferredFilenameExtension?.lowercased(),
           Sources.imageSuffixes.contains("." + suffix) {
            return (data, suffix == "jpeg" ? "jpg" : suffix)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw StudioError.message("This photo could not be converted to JPEG.") }
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw StudioError.message("This photo could not be converted to JPEG.")
        }
        return (output as Data, "jpg")
    }

    static func captureDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    static func dateStem(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// A safe stem from a suggested file name, or nil when it carries no meaning (blank or a UUID).
    static func readableStem(_ name: String) -> String? {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        guard !cleaned.isEmpty, UUID(uuidString: cleaned) == nil else { return nil }
        return String(cleaned.prefix(60))
    }
}

extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
