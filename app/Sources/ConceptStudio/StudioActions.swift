import AppKit
import ConceptCore
import PhotosUI
import SwiftUI

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

    func chooseReference(trigger: String) {
        guard let source = ProjectAccess.chooseImages(multiple: false).first, let project else { return }
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

    func importPhotos(_ items: [PhotosPickerItem]) {
        perform("Importing selected photos…") {
            for item in items {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let suffix = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                _ = try self.project?.importData(data, name: "photo-\(UUID().uuidString).\(suffix)")
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            try await self.analyzeImages()
            self.message = "Selected photos imported. Originals in Photos are unchanged."
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
                guard var project = self.project else { return }
                let name = try project.importData(sample.data, name: sample.sampleID)
                if let row = source.rows.first(where: { $0.fileName == sample.sampleID }),
                   row.record != nil || row.caption != nil {
                    let sink = try SidecarSink(directory: project.imagesDirectory)
                    var localRecord = row.record ?? ResponseRecord(
                        sampleID: name,
                        status: .written,
                        skill: "diffusion-training-captioner",
                        profile: project.job.profile,
                        captioner: ModelNames(requested: "imported"),
                        critic: nil
                    )
                    localRecord.sampleID = name
                    try await sink.write(name, caption: row.caption, record: localRecord)
                    project.images[project.images.count - 1].caption = row.caption ?? ""
                    project.images[project.images.count - 1].isFinal = localRecord.isHumanFinal
                }
                self.project = project
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            try await self.analyzeImages()
            self.message = "Dataset downloaded. Confirm its subject mapping before captioning."
        }
    }

    func datasetCritique() {
        perform("Reviewing your image set…") {
            guard let project = self.project else { return }
            let assistant = try StudioAssistant(endpoint: self.endpoint(), demo: self.demoMode)
            self.datasetAdvice = try await assistant.critique(project, warnings: self.analyses)
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
            project.job = try self.jobForCaptioning()
            try project.save()
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
            _ = try await runner.run(source: source, sink: sink, only: only) { outcome in
                await self.receive(outcome)
            }
            self.message = "Captioning finished. Review each result beside its photo."
        }
    }

    func receive(_ outcome: Outcome) {
        gpu.noteActivity()
        project?.apply(outcome)
        completed += 1
        message = "\(completed) photos processed · \(outcome.sampleID): \(outcome.status.rawValue)"
    }

    func saveCaption(id: String, text: String, final: Bool) {
        perform("Saving caption…") {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StudioError.message("Write a caption before saving or protecting it as final.")
            }
            guard var project = self.project else { return }
            try await project.saveCaption(id: id, text: text, final: final)
            self.project = project
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

    func rememberChoices() {
        guard !demoMode else { return }
        normalizePodImageChoice()
        for (key, value) in [
            "endpointKind": endpointKind,
            "modelName": modelName,
            "vllmBaseURL": customBaseURL,
            "hubRepo": repoID,
            "podImage": podImageName,
            "volumeID": volumeID,
        ] {
            preferences.set(value, forKey: key)
        }
    }
}
