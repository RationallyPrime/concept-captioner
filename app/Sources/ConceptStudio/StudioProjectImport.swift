import ConceptCore
import Foundation

extension StudioProject {
    // MARK: Images

    /// Imports media with any matching caption/record companions. A folder import lists the folder
    /// it was granted; individually chosen files (`fromFolder: false`) may have a parent a sandboxed
    /// build cannot list, and then import without companions.
    mutating func importFiles(_ files: [URL], fromFolder: Bool = true) async throws {
        let media = files.filter(Self.isImportableMedia)
        let companions = try Self.companionFiles(for: media, folderListingRequired: fromFolder)
        for source in media {
            try Task.checkCancellation()
            let previousJob = job
            let sidecars = companions[source.standardizedFileURL]
            let suffix = Sources.suffix(of: source.lastPathComponent).lowercased()
            let target: String
            if Sources.isVideo(suffix) {
                target = try importVideo(source, name: source.lastPathComponent)
            } else {
                let imported = try MediaEditor.normalizedImport(
                    Data(contentsOf: source), name: source.lastPathComponent
                )
                target = try importNormalizedData(imported.data, name: imported.name)
            }
            do {
                try await importSidecars(sidecars, for: target)
            } catch {
                images.removeAll { $0.id == target }
                job = previousJob
                try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(target))
                if let sink = try? SidecarSink(directory: imagesDirectory) {
                    try? FileManager.default.removeItem(at: sink.captionURL(for: target))
                    try? FileManager.default.removeItem(at: sink.recordURL(for: target))
                }
                try? save()
                throw error
            }
        }
        try save()
    }

    mutating func importData(_ data: Data, name: String) throws -> String {
        let imported = try MediaEditor.normalizedImport(data, name: URL(fileURLWithPath: name).lastPathComponent)
        return try importNormalizedData(imported.data, name: imported.name)
    }

    private mutating func importNormalizedData(_ data: Data, name: String) throws -> String {
        let target = availableTarget(for: name)
        try AtomicFile.write(data, to: target)
        images.append(ProjectImage(url: target))
        try job.setMapping(job.mappingIncludingWholeTargets(nil), for: target.lastPathComponent)
        try save()
        return target.lastPathComponent
    }

    private struct ImportSidecars {
        let captionURL: URL?
        let recordURL: URL?
    }

    private static func isImportableMedia(_ url: URL) -> Bool {
        let suffix = Sources.suffix(of: url.lastPathComponent).lowercased()
        return Sources.mediaSuffixes.contains(suffix) || MediaEditor.convertibleImageSuffixes.contains(suffix)
    }

    /// Resolve companions against the original files before normalization or collision renaming.
    /// Case-insensitive matches are safe only when exactly one media file owns that stem.
    private static func companionFiles(
        for media: [URL], folderListingRequired: Bool
    ) throws -> [URL: ImportSidecars] {
        var result: [URL: ImportSidecars] = [:]
        let folders = Dictionary(grouping: media, by: { $0.deletingLastPathComponent().standardizedFileURL })
        for (folder, requested) in folders {
            let listing: [URL]
            do {
                listing = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey]
                )
            } catch where !folderListingRequired {
                continue
            }
            let children = listing
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            let requestedStems = Set(requested.map { stemKey($0.lastPathComponent) })
            let siblings = children.filter(isImportableMedia)
            let mediaByStem = Dictionary(grouping: siblings, by: { stemKey($0.lastPathComponent) })
            let companions = children.filter {
                ["txt", "json"].contains($0.pathExtension.lowercased())
                    && requestedStems.contains(stemKey($0.lastPathComponent))
            }
            let companionStems = Set(companions.map { stemKey($0.lastPathComponent) })
            for key in companionStems {
                let matchingMedia = mediaByStem[key] ?? []
                guard matchingMedia.count == 1 else {
                    let stem = Sources.stem(of: matchingMedia.first?.lastPathComponent ?? key)
                    throw StudioError.message(
                        "More than one image or clip named ‘\(stem)’ matches the same captions. "
                            + "Rename the files or separate them before importing."
                    )
                }
            }
            for source in requested {
                let key = stemKey(source.lastPathComponent)
                let matching = companions.filter { stemKey($0.lastPathComponent) == key }
                guard !matching.isEmpty else { continue }
                func one(_ suffix: String) throws -> URL? {
                    let candidates = matching.filter { $0.pathExtension.caseInsensitiveCompare(suffix) == .orderedSame }
                    guard candidates.count <= 1 else {
                        throw StudioError.message(
                            "More than one .\(suffix) sidecar matches ‘\(source.lastPathComponent)’. "
                                + "Keep one companion file and import again."
                        )
                    }
                    return candidates.first
                }
                result[source.standardizedFileURL] = try ImportSidecars(
                    captionURL: one("txt"), recordURL: one("json")
                )
            }
        }
        return result
    }

    private static func stemKey(_ name: String) -> String {
        Sources.stem(of: name).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private mutating func importSidecars(_ sidecars: ImportSidecars?, for sampleID: String) async throws {
        guard let sidecars else { return }
        let caption = try sidecars.captionURL.map { try String(contentsOf: $0, encoding: .utf8) }
        var record: ResponseRecord?
        if let url = sidecars.recordURL {
            do {
                record = try ResponseRecord(json: JSONValue(parsing: Data(contentsOf: url)), sampleID: sampleID)
            } catch {
                throw StudioError.message(
                    "The response record ‘\(url.lastPathComponent)’ could not be read. "
                        + "Check that it is a valid Concept Captioner JSON record and import again."
                )
            }
        }
        let text = caption ?? record?.caption?.caption
        guard var record = record ?? text.map({ _ in
            ResponseRecord(
                sampleID: sampleID, status: .written, skill: skillName, profile: job.profile,
                captioner: ModelNames(requested: ProjectImage.importedCaptioner), critic: nil
            )
        }) else { return }
        record.sampleID = sampleID
        if let text {
            record.caption = Caption(caption: text, usable: record.caption?.usable ?? true, note: record.caption?.note)
        }
        try await SidecarSink(directory: imagesDirectory).write(sampleID, caption: text, record: record)
        if let index = images.firstIndex(where: { $0.id == sampleID }) {
            images[index].caption = text ?? ""
            images[index].status = record.status
            images[index].isFinal = record.isHumanFinal
            images[index].isImported = ProjectImage.isImported(record, caption: text ?? "")
        }
    }

    mutating func importVideo(_ source: URL, name: String) throws -> String {
        guard Sources.isVideo(Sources.suffix(of: name)) else {
            throw StudioError.message("Import this clip as an MP4, MOV or M4V file.")
        }
        let target = availableTarget(for: URL(fileURLWithPath: name).lastPathComponent)
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: target)
        let previousJob = job
        do {
            try Task.checkCancellation()
            try job.setMapping(job.mappingIncludingWholeTargets(nil), for: target.lastPathComponent)
            images.append(ProjectImage(url: target))
            try save()
        } catch {
            images.removeAll { $0.url == target }
            job = previousJob
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return target.lastPathComponent
    }

    /// A target in images/ whose stem no existing photo uses (sidecars are named by stem):
    /// `name.ext`, then `name-2.ext`, `name-3.ext`, ...
    func availableTarget(for fileName: String) -> URL {
        let file = URL(fileURLWithPath: fileName)
        let stem = file.deletingPathExtension().lastPathComponent
        let suffix = file.pathExtension
        let taken = Set(allMedia.map { $0.url.deletingPathExtension().lastPathComponent.lowercased() })
        var candidate = stem
        var counter = 1
        while taken.contains(candidate.lowercased())
            || FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent(
                suffix.isEmpty ? candidate : "\(candidate).\(suffix)"
            ).path) {
            counter += 1
            candidate = "\(stem)-\(counter)"
        }
        return imagesDirectory.appendingPathComponent(suffix.isEmpty ? candidate : "\(candidate).\(suffix)")
    }
}
