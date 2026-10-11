import ConceptCore
import Foundation

enum ProjectPublisher {
    static func operations(for project: StudioProject) async throws -> [CommitOperation] {
        let sink = try SidecarSink(directory: project.imagesDirectory)
        var operations: [CommitOperation] = [.addFile(path: "concept-captioner/job.yaml", url: project.jobURL)]
        var rows: [MetadataRow] = []
        for image in project.images {
            try Task.checkCancellation()
            let path = image.id
            operations.append(.addFile(path: path, url: image.url))
            let record = try await sink.record(image.id)
            let caption = (try? String(contentsOf: sink.captionURL(for: image.id), encoding: .utf8))
            rows.append(MetadataRow(fileName: path, caption: caption, record: record))
            for url in [sink.captionURL(for: image.id), sink.recordURL(for: image.id)]
                where FileManager.default.fileExists(atPath: url.path) {
                operations.append(.addFile(path: url.lastPathComponent, url: url))
            }
        }
        operations.append(.add(path: ImageFolderMetadata.fileName, data: ImageFolderMetadata.serialize(rows)))
        return try operations + skillOperations(for: project)
    }

    /// The project's own skill copy, published beside job.yaml so its relative `skill:` path
    /// (`./skill/<name>`) resolves next to the published job file. Hidden files and images are left
    /// out: dataset readers treat any image in the repository as a training sample. Nothing from the
    /// app-only `.conceptstudio/` folder or `references/` is ever published.
    static func skillOperations(for project: StudioProject) throws -> [CommitOperation] {
        guard !project.skillIsOutsideProject, let skill = project.skillURL,
              let enumerator = FileManager.default.enumerator(
                  at: skill,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        let root = project.directory.standardizedFileURL.path + "/"
        var operations: [CommitOperation] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  !Sources.imageSuffixes.contains("." + url.pathExtension.lowercased()) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            operations.append(.addFile(path: "concept-captioner/" + path.dropFirst(root.count), url: url))
        }
        return operations.sorted { $0.path < $1.path }
    }
}

actor ComparisonSink: CaptionSink {
    let name = "comparison"
    func exists(_ sampleID: String) async throws -> Bool {
        false
    }

    func record(_ sampleID: String) async throws -> ResponseRecord? {
        nil
    }

    func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws {}
    func finalize() async throws -> JSONObject {
        [:]
    }
}
