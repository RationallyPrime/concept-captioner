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
        return operations
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
