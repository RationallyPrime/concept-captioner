import ConceptCore
import CryptoKit
import Foundation

/// An immutable, temporary copy of the included approved targets and saved training sidecars.
/// The private digest is local-input provenance for Resume, never a Hub revision.
struct LocalTrainingDataset {
    struct File {
        let name: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    static let maximumFileBytes: Int64 = 2_147_483_648
    static let maximumDatasetBytes: Int64 = 21_474_836_480
    let folder: URL
    let files: [File]
    let digest: String
    let containsVideo: Bool
    /// How many images and clips the upload holds, not counting captions and records.
    let itemCount: Int

    static func prepare(projectFolder: URL) async throws -> LocalTrainingDataset {
        let project = try await StudioProject.open(at: projectFolder)
        try project.job.requireConcepts()
        guard !project.images.isEmpty else { throw StudioError.message("Include training images or clips first.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-upload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let sink = try SidecarSink(directory: project.imagesDirectory)
            let copiedSink = try SidecarSink(directory: folder)
            var rows: [MetadataRow] = []
            var copiedBytes: Int64 = 0
            try copy(project.jobURL, name: "job.yaml", to: folder, total: &copiedBytes)
            for image in project.images {
                try Task.checkCancellation()
                let captionURL = sink.captionURL(for: image.id)
                guard FileManager.default.fileExists(atPath: captionURL.path) else {
                    throw StudioError.message("Save a caption for \(image.id) before preparing training data.")
                }
                try copy(image.url, name: image.id, to: folder, total: &copiedBytes)
                try copy(captionURL, name: captionURL.lastPathComponent, to: folder, total: &copiedBytes)
                let recordURL = sink.recordURL(for: image.id)
                if FileManager.default.fileExists(atPath: recordURL.path) {
                    try copy(recordURL, name: recordURL.lastPathComponent, to: folder, total: &copiedBytes)
                }
                let caption = try String(contentsOf: copiedSink.captionURL(for: image.id), encoding: .utf8)
                guard !caption.isBlank
                else { throw StudioError.message("Save a caption for \(image.id) before training.") }
                let record = try await copiedSink.record(image.id)
                rows.append(MetadataRow(fileName: image.id, caption: caption, record: record))
            }
            let metadata = ImageFolderMetadata.serialize(rows)
            guard metadata.count <= maximumFileBytes, copiedBytes + Int64(metadata.count) <= maximumDatasetBytes else {
                throw StudioError
                    .message("Training metadata exceeds the direct upload size limits. Use the Hub instead.")
            }
            try metadata.write(to: folder.appendingPathComponent("metadata.jsonl"))
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
            var files: [File] = []
            var bytes: Int64 = 0
            for url in urls {
                try Task.checkCancellation()
                let size = try Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                guard size <= maximumFileBytes, size > 0 else {
                    throw StudioError.message("\(url.lastPathComponent) must be nonempty and no larger than 2 GiB.")
                }
                bytes += size
                guard bytes <= maximumDatasetBytes else {
                    throw StudioError
                        .message("Direct uploads support at most 20 GiB. Exclude some targets or use the Hub.")
                }
                let hash = try RunArtifacts.sha256(of: url)
                let name = url.lastPathComponent
                files.append(File(name: name, url: url, size: size, sha256: hash))
            }
            return LocalTrainingDataset(
                folder: folder, files: files,
                digest: inputDigest(files),
                containsVideo: project.images.contains { Sources.isVideo(Sources.suffix(of: $0.id)) },
                itemCount: project.images.count
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func inputDigest(_ files: [File]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
            hasher.update(data: Data("\(file.name)\0\(file.size)\0\(file.sha256)\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copy(_ url: URL, name: String, to folder: URL, total: inout Int64) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= maximumFileBytes,
              !name.contains("/"), !name.contains("\\"), !name.hasPrefix(".") else {
            throw StudioError.message("Training uploads require regular, flat files of at most 2 GiB: \(name).")
        }
        guard total + Int64(size) <= maximumDatasetBytes else {
            throw StudioError.message("Direct uploads support at most 20 GiB. Exclude some targets or use the Hub.")
        }
        total += Int64(size)
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
    }
}

extension GPUWorkspace {
    var usesLocalDataset: Bool {
        !demoMode && hubToken.isEmpty
    }

    func currentLocalDataset(
        capture: (@MainActor () async throws -> LocalTrainingDataset)? = nil
    ) async throws -> LocalTrainingDataset? {
        guard usesLocalDataset else { return nil }
        if let capture { return try await capture() }
        guard let projectFolder
        else { throw StudioError.message("Open the project containing your training media first.") }
        return try await LocalTrainingDataset.prepare(projectFolder: projectFolder)
    }

    func installTrainingDataset(
        _ snapshot: LocalTrainingDataset?, repo: String, revision: String?, name: String, agent: any PodAgent
    ) async throws {
        var pull: JSONObject = ["name": .string(name), "only_metadata": .bool(true)]
        if let snapshot {
            try await uploadDataset(snapshot, name: name, agent: agent)
            pull["local_name"] = .string(name)
            message = "Installing your uploaded training media and captions."
        } else {
            pull["repo_id"] = .string(repo)
            if let revision { pull["revision"] = .string(revision) }
            message = "Downloading your published media and captions."
        }
        try await agent.start("pull-dataset", gpus: [], params: pull)
        try await waitForService("pull-dataset")
    }

    func uploadDataset(_ snapshot: LocalTrainingDataset, name: String, agent: any PodAgent) async throws {
        for (index, file) in snapshot.files.enumerated() {
            try Task.checkCancellation()
            message = "Uploading \(index + 1) of \(snapshot.files.count): \(file.name)"
            try await agent.upload(name: name, fileName: file.name, from: file.url, size: file.size)
            lastActivity = Date()
        }
    }
}
