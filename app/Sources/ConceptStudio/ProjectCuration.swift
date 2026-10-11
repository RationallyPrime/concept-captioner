import ConceptCore
import Foundation

struct ProjectMediaState: Codable {
    var selections: [String: MediaSelection] = [:]
    static func url(in directory: URL) -> URL {
        ProjectAppState.folder(in: directory).appendingPathComponent("media.json")
    }

    static func load(in directory: URL) -> Self {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }

    func save(in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: ProjectAppState.folder(in: directory),
            withIntermediateDirectories: true
        )
        try AtomicFile.write(JSONEncoder().encode(self), to: Self.url(in: directory))
    }
}

enum CurationUndo {
    case inclusion(id: String, wasIncluded: Bool)
    case replacement(
        image: ProjectImage, mapping: Job.Mapping?, concepts: [Concept], selection: MediaSelection?,
        backup: URL, newID: String
    )

    var replacedIDs: Set<String> {
        switch self {
        case .inclusion: []
        case let .replacement(image, _, _, _, _, newID): [image.id, newID]
        }
    }
}

extension StudioProject {
    var excludedDirectory: URL {
        ProjectAppState.folder(in: directory).appendingPathComponent("excluded", isDirectory: true)
    }

    func isIncluded(_ id: String) -> Bool {
        images.contains { $0.id == id }
    }

    mutating func setIncluded(_ id: String, _ included: Bool, recordUndo: Bool = true) throws {
        guard isIncluded(id) != included,
              let image = allMedia.first(where: { $0.id == id }) else { return }
        let destination = included ? imagesDirectory : excludedDirectory
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let moved = try moveTarget(image.url, to: destination)
        var updated = image
        updated = ProjectImage(
            url: moved, caption: image.caption, status: image.status, notes: image.notes,
            isFinal: image.isFinal, isImported: image.isImported
        )
        images.removeAll { $0.id == id }
        excludedImages.removeAll { $0.id == id }
        if included { images.append(updated) } else { excludedImages.append(updated) }
        let previousJob = job
        do {
            if included {
                try job.setMapping(job.mappingIncludingWholeTargets(job.mapping(for: id)), for: id)
            }
            try save()
        } catch {
            _ = try? moveTarget(moved, to: image.url.deletingLastPathComponent())
            images.removeAll { $0.id == id }; excludedImages.removeAll { $0.id == id }
            if included { excludedImages.append(image) } else { images.append(image) }
            job = previousJob
            try? job.save(to: jobURL)
            throw error
        }
        if recordUndo { curationUndo.append(.inclusion(id: id, wasIncluded: !included)) }
    }

    /// Media and its two caption sidecars travel together. Roll back a partial move.
    private func moveTarget(_ source: URL, to directory: URL) throws -> URL {
        let stem = source.deletingPathExtension()
        let files = [source, stem.appendingPathExtension("txt"), stem.appendingPathExtension("json")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        var moved: [(URL, URL)] = []
        do {
            for file in files {
                let target = directory.appendingPathComponent(file.lastPathComponent)
                try FileManager.default.moveItem(at: file, to: target)
                moved.append((file, target))
            }
        } catch {
            for (original, target) in moved.reversed() {
                try? FileManager.default.moveItem(at: target, to: original)
            }
            throw error
        }
        return directory.appendingPathComponent(source.lastPathComponent)
    }

    mutating func approveTarget(id: String, data: Data, name: String, selection: MediaSelection) throws {
        try approveTarget(id: id, name: name, selection: selection) { try AtomicFile.write(data, to: $0) }
    }

    mutating func approveTarget(id: String, sourceFile: URL, name: String, selection: MediaSelection) throws {
        try approveTarget(id: id, name: name, selection: selection) {
            try FileManager.default.copyItem(at: sourceFile, to: $0)
        }
    }

    private mutating func approveTarget(
        id: String, name: String, selection: MediaSelection, write: (URL) throws -> Void
    ) throws {
        guard let image = images.first(where: { $0.id == id }) else {
            throw StudioError.message("Include this sample before approving its crop or segment.")
        }
        let target = imagesDirectory.appendingPathComponent(name)
        guard name == id || !FileManager.default.fileExists(atPath: target.path) else {
            throw StudioError.message("A target with this name already exists. Choose another segment name.")
        }
        let backup = ProjectAppState.folder(in: directory).appendingPathComponent("edits/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        _ = try moveTarget(image.url, to: backup)
        let oldMapping = job.mapping(for: id)
        let previousSelection = mediaState.selections[id]
        do {
            try write(target)
            images.removeAll { $0.id == id }
            images.append(ProjectImage(url: target))
            job.samples.removeValue(forKey: id)
            try job.setMapping(job.mappingIncludingWholeTargets(nil), for: target.lastPathComponent)
            mediaState.selections[id] = nil
            mediaState.selections[target.lastPathComponent] = selection
            try save()
        } catch {
            try? FileManager.default.removeItem(at: target)
            _ = try? moveTarget(backup.appendingPathComponent(id), to: imagesDirectory)
            images.removeAll { $0.id == target.lastPathComponent }; images.append(image)
            job.samples.removeValue(forKey: target.lastPathComponent)
            try? job.setMapping(oldMapping, for: id)
            mediaState.selections[target.lastPathComponent] = nil
            mediaState.selections[id] = previousSelection
            try? save()
            throw error
        }
        curationUndo.append(.replacement(
            image: image, mapping: oldMapping, concepts: job.concepts, selection: previousSelection, backup: backup,
            newID: target.lastPathComponent
        ))
    }

    mutating func undoCuration() throws {
        guard let undo = curationUndo.last else { return }
        switch undo {
        case let .inclusion(id, included): try setIncluded(id, included, recordUndo: false)
        case let .replacement(image, mapping, concepts, selection, backup, newID):
            guard let current = images.first(where: { $0.id == newID }) else {
                throw StudioError.message("Include the edited sample before undoing its edit.")
            }
            let discarded = ProjectAppState.folder(in: directory).appendingPathComponent("edits/\(UUID().uuidString)")
            let previous = self
            try FileManager.default.createDirectory(at: discarded, withIntermediateDirectories: true)
            _ = try moveTarget(current.url, to: discarded)
            do { _ = try moveTarget(backup.appendingPathComponent(image.id), to: imagesDirectory) } catch {
                _ = try? moveTarget(discarded.appendingPathComponent(newID), to: imagesDirectory)
                throw error
            }
            do {
                images.removeAll { $0.id == newID }; images.append(image)
                job.samples.removeValue(forKey: newID)
                let restoredMapping = job.mappingIncludingWholeTargets(job.concepts == concepts ? mapping : nil)
                try job.setMapping(restoredMapping, for: image.id)
                mediaState.selections[newID] = nil
                mediaState.selections[image.id] = selection
                try save()
            } catch {
                _ = try? moveTarget(imagesDirectory.appendingPathComponent(image.id), to: backup)
                _ = try? moveTarget(discarded.appendingPathComponent(newID), to: imagesDirectory)
                self = previous
                try? save()
                throw error
            }
        }
        curationUndo.removeLast()
    }
}

@MainActor
extension StudioSession {
    func includeMedia(_ id: String, included: Bool) {
        guard !busy, !editing else { return }
        do {
            try project?.setIncluded(id, included)
            startImageAnalysis()
            message = included ? "Sample included in training." : "Sample excluded. Undo can restore it."
        } catch { errorMessage = Self.describe(error) }
    }

    func undoMediaCuration() {
        guard !busy, !editing else { return }
        do {
            let replaced = project?.curationUndo.last?.replacedIDs ?? []
            try project?.undoCuration()
            for id in replaced {
                invalidateMediaDraft(id: id)
            }
            if let image = project?.images.first(where: { replaced.contains($0.id) }) {
                selectedImageID = image.id
            }
            PhotoThumbnails.removeAll()
            startImageAnalysis()
            message = "Previous curation change restored."
        } catch { errorMessage = Self.describe(error) }
    }
}
