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
            else { throw StudioError.message("Choose a readable image showing the person, object or character.") }
            let target = project.referenceURL(for: trigger)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFile.write(data, to: target)
            message = "Reference saved. Suggestions always need your confirmation."
        } catch { errorMessage = Self.describe(error) }
    }

    /// Import media picked with the permission-free PhotosPicker. Files get readable, stable names
    /// (see `PhotoImportName`); formats the pipeline cannot read (HEIC, TIFF, ...) become JPEG.
    func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        perform("Importing selected images and clips…") {
            var added = 0
            var already = 0
            for item in items {
                try Task.checkCancellation()
                guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else { continue }
                if try await self.importPickedPhoto(picked) {
                    added += 1
                } else {
                    already += 1
                }
                self.completed += 1
            }
            self.selectedImageID = self.project?.images.first?.id
            self.startImageAnalysis()
            self.message = "\(added) images or clips imported."
                + (already > 0 ? " \(already) were already in this project and were skipped." : "")
        }
    }

    /// Keep video transfer files on disk through hashing and project import.
    func importPickedPhoto(_ picked: PickedPhoto) async throws -> Bool {
        switch picked.content {
        case let .image(bytes):
            let (data, suffix) = try PhotoImportName.readable(bytes)
            let name = PhotoImportName.make(
                suggested: picked.suggestedName, captured: PhotoImportName.captureDate(data),
                hash: VisionInspector.contentHash(data), suffix: suffix
            )
            guard project?.images.contains(where: { $0.id == name }) != true else { return false }
            try Task.checkCancellation()
            return try project?.importData(data, name: name) != nil
        case let .video(file):
            let hash = try await VisionInspector.contentHash(fileURL: file)
            try Task.checkCancellation()
            let name = PhotoImportName.make(
                suggested: picked.suggestedName, captured: nil, hash: hash,
                suffix: file.pathExtension.lowercased()
            )
            guard project?.images.contains(where: { $0.id == name }) != true else { return false }
            return try project?.importVideo(file, name: name) != nil
        }
    }

    func importHub(_ id: String) {
        perform("Downloading dataset images and clips…") {
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
                    // Captioning offers to protect imported captions as final.
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
                    ? " Imported captions are not protected yet; protect them before re-captioning." : "")
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
        perform("Reviewing the training data…") {
            guard let project = self.project else { return }
            let assistant = try StudioAssistant(endpoint: self.endpoint(), demo: self.demoMode)
            self.datasetAdvice = try await assistant.critique(project, warnings: self.analyses) { done, _ in
                self.message = StudioAssistant.critiqueProgress(done: done, total: project.images.count)
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
        let oldConcept = oldTrigger.flatMap { project.job.concept(for: $0) }
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
        if let oldConcept, oldConcept.targetConcept != concept.targetConcept {
            for image in project.allMedia {
                guard var mapping = project.job.mapping(for: image.id) else { continue }
                let changedAssignment = mapping[concept.trigger] != nil && concept.targetConcept.requiresLocator
                mapping[concept.trigger] = nil
                try project.job.setMapping(changedAssignment || mapping.isEmpty ? nil : mapping, for: image.id)
            }
        } else if oldConcept == nil, concept.targetConcept.requiresLocator {
            for image in project.allMedia {
                try project.job.setMapping(nil, for: image.id)
            }
        }
        for image in project.images {
            try project.job.setMapping(
                project.job.mappingIncludingWholeTargets(project.job.mapping(for: image.id)), for: image.id
            )
        }
        project.job = try Job(json: project.job.jsonValue)
        try project.save()
        self.project = project
        if oldConcept != concept {
            mappingProposals = [:]
            mappingUndo = []
        }
        message = project.job.requiresLocatorMapping
            ? "Concept saved. Review its assignments on Mapping before captioning."
            : "Concept saved and assigned to every included image or clip."
        if oldConcept != nil, oldConcept != concept, project.images.contains(where: { !$0.caption.isEmpty }) {
            message += " Existing captions retain their text; review or re-caption them for the changed concept."
        }
    }

    func confirmConcepts() {
        guard !busy, !editing, let project else { return }
        guard !project.job.concepts.isEmpty else {
            errorMessage = "Add a concept before continuing to Mapping or Captioning."
            return
        }
        do {
            try project.save()
            message = project.job.requiresLocatorMapping
                ? "Concepts saved. Confirm their locations in the training samples."
                : "Concepts saved. Whole-target assignments are ready for captioning."
            next()
        } catch { errorMessage = Self.describe(error) }
    }

    func confirmMapping(id: String, mapping: Job.Mapping) {
        do {
            guard var project else { return }
            let previous = project.job.mapping(for: id)
            let confirmed = project.job.mappingIncludingWholeTargets(mapping)
            try project.job.setMapping(confirmed, for: id)
            try project.save()
            self.project = project
            mappingProposals[id] = nil
            if previous != confirmed {
                mappingUndo.append(MappingUndo(snapshots: [MappingSnapshot(sampleID: id, mapping: previous)]))
            }
            message = "Mapping confirmed and saved."
        } catch { errorMessage = Self.describe(error) }
    }

    func acceptMappingSuggestions() {
        guard !busy, !editing, var project else { return }
        let ids = validMappingSuggestionIDs
        guard !ids.isEmpty else {
            message = "There are no unconfirmed, valid suggestions to accept."
            return
        }
        let snapshots = ids.compactMap { id -> MappingSnapshot? in
            guard mappingProposals[id] != nil else { return nil }
            return MappingSnapshot(sampleID: id, mapping: project.job.mapping(for: id))
        }
        do {
            for id in ids {
                guard let proposal = mappingProposals[id] else { continue }
                try project.job.setMapping(project.job.mappingIncludingWholeTargets(proposal), for: id)
            }
            try project.save()
            self.project = project
            mappingUndo.append(MappingUndo(snapshots: snapshots))
            message = "\(snapshots.count) suggestions accepted. Review the assignments; Undo restores them."
        } catch { errorMessage = Self.describe(error) }
    }

    func unconfirmMapping(id: String) {
        guard var project, let previous = project.job.mapping(for: id) else { return }
        do {
            try project.job.setMapping(nil, for: id)
            try project.save()
            self.project = project
            mappingUndo.append(MappingUndo(snapshots: [MappingSnapshot(sampleID: id, mapping: previous)]))
            message = "Mapping cleared. Undo can restore it."
        } catch { errorMessage = Self.describe(error) }
    }

    func undoMappingChange() {
        guard let change = mappingUndo.last, var project else { return }
        do {
            for snapshot in change.snapshots {
                try project.job.setMapping(snapshot.mapping, for: snapshot.sampleID)
            }
            try project.save()
            self.project = project
            mappingUndo.removeLast()
            message = "Last mapping change undone."
        } catch { errorMessage = Self.describe(error) }
    }

    func proposeMappings(useModel: Bool) {
        perform(useModel ? "Requesting concept assignments…" : "Comparing reference faces on this Mac…") {
            guard let project = self.project else { return }
            guard !project.job.concepts.isEmpty else {
                throw StudioError.message("Add a concept before requesting assignments.")
            }
            if !project.job.requiresLocatorMapping {
                for image in project.images {
                    self.confirmMapping(id: image.id, mapping: project.job.wholeTargetMapping)
                }
                self.message = "Whole-target concepts are assigned to every included image and clip."
                return
            }
            let locatorConcepts = project.job.concepts.filter(\.targetConcept.requiresLocator)
            let references = self.references.filter { key, _ in locatorConcepts.contains { $0.trigger == key } }
            let personConcepts = locatorConcepts.filter(\.targetConcept.isPersonIdentity)
            if !useModel {
                guard personConcepts.count == locatorConcepts.count else {
                    throw StudioError.message("On-device face comparison supports person concepts. "
                        + "Use the selected model or enter a location for objects, characters and custom concepts.")
                }
                guard personConcepts.allSatisfy({ references[$0.trigger] != nil }) else {
                    throw StudioError.message("Choose a reference photo for each person in Concepts first.")
                }
                let stills = project.images.filter { !Sources.isVideo(Sources.suffix(of: $0.id)) }
                let proposals = try await self.inspector.proposals(
                    images: stills.map(\.url),
                    references: references
                )
                self.receiveMappingSuggestions(proposals, sampleIDs: stills.map(\.id))
            } else {
                guard personConcepts.allSatisfy({ references[$0.trigger] != nil }) else {
                    throw StudioError.message("Choose a reference photo for each person in Concepts first.")
                }
                let assistant = try StudioAssistant(endpoint: self.endpoint(), demo: self.demoMode)
                for image in project.images {
                    try Task.checkCancellation()
                    self.mappingProposals[image.id] = try await assistant.proposeMapping(
                        image: image.url, references: references, concepts: locatorConcepts
                    )
                    self.completed += 1
                }
            }
            self.message = "Suggestions are ready. Select a sample to compare the result with its confirmed assignment."
        }
    }

    /// An empty entry records a completed comparison with no confident suggestion; job mappings stay human-owned.
    func receiveMappingSuggestions(_ proposals: [String: Job.Mapping], sampleIDs: [String]) {
        mappingProposals = Dictionary(uniqueKeysWithValues: sampleIDs.map { ($0, proposals[$0] ?? [:]) })
    }

    func caption(only: Set<String>? = nil, overwrite: Bool = false) {
        guard let currentProject = project else { return }
        guard !currentProject.job.concepts.isEmpty else {
            errorMessage = "Add a concept before writing captions."
            step = .concepts
            return
        }
        let pending = only ?? Set(project?.images.map(\.id) ?? [])
        let started = perform("Writing captions…") {
            defer { self.runPendingIDs = []; self.partialCaptions = [:] }
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
            _ = try await runner.run(
                source: source, sink: sink, only: only,
                onPartialCaption: { id, text in await self.receivePartialCaption(id: id, text: text) },
                onOutcome: { outcome in await self.receive(outcome) }
            )
            self.message = "Captioning finished. Review each caption against its image or clip."
        }
        // Set before the run starts, so an edit made right after starting already waits for its photo.
        if started { runPendingIDs = pending; partialCaptions = [:] }
    }

    func receivePartialCaption(id: String, text: String) {
        guard runPendingIDs.contains(id) else { return }
        if text.isEmpty { partialCaptions.removeValue(forKey: id) } else { partialCaptions[id] = text }
    }

    func receive(_ outcome: Outcome) {
        gpu.noteActivity()
        runPendingIDs.remove(outcome.sampleID)
        partialCaptions.removeValue(forKey: outcome.sampleID)
        project?.apply(outcome)
        completed += 1
        message = "\(completed) samples processed · \(outcome.sampleID): \(outcome.status.rawValue)"
    }

    func receivePublishProgress(_ value: String, id: UUID, projectDirectory: URL) {
        guard activePublishID == id,
              project?.directory.standardizedFileURL == projectDirectory.standardizedFileURL else { return }
        message = value
    }

    /// Save a caption edit. Uses the edit gate, so it works while a caption run is in progress,
    /// except for a photo that run has not reached yet.
    func saveCaption(id: String, text: String, final: Bool) {
        guard !runPendingIDs.contains(id) else {
            errorMessage = "\(id) is still being captioned by the current run. Your edit is kept as a draft; "
                + "save it after its new caption arrives, or cancel the run."
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
        perform("Requesting a comparison caption…") {
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

    /// App-wide defaults for the next project: model choices and the pod setup. The dataset and
    /// training destinations are per project (`projectState`), never app-wide.
    func rememberChoices() {
        guard !demoMode else { return }
        preferences.set(openAIUsesChatGPT, forKey: "openAIUsesChatGPT")
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

extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
