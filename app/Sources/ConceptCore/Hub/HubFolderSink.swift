// Buffer captions and records, then write metadata.jsonl (and new images for a folder origin)
// in one commit at finalize. Python counterpart: sources/hf.py::HFDatasetSink (semantics).

import Foundation

public actor HubFolderSink: CaptionSink {
    public enum Origin: Sendable {
        case hub(HubFolderSource)
        case folder(LocalFolderSource)
    }

    // Configuration is immutable and Sendable, so it is readable without hopping onto the actor.
    public nonisolated let name = "hub"
    public nonisolated let client: HubClient
    public nonisolated let repo: RepoID
    public nonisolated let origin: Origin
    public nonisolated let captionColumn: String
    public nonisolated let revision: String
    public nonisolated let isPrivate: Bool?
    public nonisolated let commitMessage: String
    public nonisolated let push: Bool
    /// Where `finalize()` reports; `finalize(onProgress:)` takes a handler per call instead.
    public nonisolated let onProgress: HubProgressHandler

    private var captions: [String: String] = [:]
    private var records: [String: ResponseRecord] = [:]
    private var existingCaptions: [String: String] = [:]
    private var existingRecords: [String: ResponseRecord] = [:]

    /// `repo` nil targets the hub origin's own repo; a folder origin needs an explicit target
    /// (ConfigurationError "a folder source needs an explicit target repo id", as in Python).
    /// The caption column must be a non-blank name other than `file_name`. With a hub origin the
    /// rows already in its metadata.jsonl seed the existing captions and records.
    public init(
        client: HubClient,
        repo: RepoID? = nil,
        origin: Origin,
        captionColumn: String = "caption",
        revision: String = "main",
        private isPrivate: Bool? = nil,
        commitMessage: String = "Add captions (concept-captioner)",
        push: Bool = true,
        onProgress: @escaping HubProgressHandler = { _ in }
    ) throws {
        let trimmedColumn = captionColumn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedColumn == captionColumn, !captionColumn.isEmpty,
              captionColumn != ImageFolderMetadata.fileNameColumn
        else {
            throw ConfigurationError("caption column must be a non-blank name other than 'file_name'")
        }
        let target: RepoID
        switch origin {
        case let .hub(source):
            target = repo ?? source.repo
        case .folder:
            guard let repo else { throw ConfigurationError("a folder source needs an explicit target repo id") }
            target = repo
        }
        self.client = client
        self.repo = target
        self.origin = origin
        self.captionColumn = captionColumn
        self.revision = revision
        self.isPrivate = isPrivate
        self.commitMessage = commitMessage
        self.push = push
        self.onProgress = onProgress
        if case let .hub(source) = origin {
            for row in source.rows {
                if let caption = row.caption, !caption.isEmpty {
                    existingCaptions[row.fileName] = caption
                }
                if let record = row.record {
                    existingRecords[row.fileName] = record
                }
            }
        }
    }

    public func exists(_ sampleID: String) async throws -> Bool {
        captions[sampleID] != nil || existingCaptions[sampleID] != nil
    }

    public func record(_ sampleID: String) async throws -> ResponseRecord? {
        records[sampleID] ?? existingRecords[sampleID]
    }

    public func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws {
        records[sampleID] = record
        if let caption {
            captions[sampleID] = caption
        }
    }

    /// Builds metadata.jsonl, creates the repo when needed, commits once. {"repo_id", "rows", "captions", "pushed"}.
    ///
    /// Pushing to the hub origin's own repo and revision commits only metadata.jsonl. Any other
    /// target (a folder origin, or a different repo or revision) is created when missing and
    /// receives the images it does not have yet (read from the folder, or downloaded from the
    /// origin) in the same commit. Progress goes to the handler given at init.
    public func finalize() async throws -> JSONObject {
        try await finalize(onProgress: onProgress)
    }

    /// `finalize()` reporting to `onProgress`: `.preparing` once the push starts, `.downloading`
    /// per image fetched from a hub origin, then the commit's own `.hashing`, `.uploading` and
    /// `.committing`. Images are never all in memory at once: folder images are committed from
    /// their files, origin images are downloaded one by one into a temporary folder that is
    /// removed when the commit has been sent or has failed.
    public func finalize(onProgress: @escaping HubProgressHandler) async throws -> JSONObject {
        let (rows, candidates) = await materialize()
        var summary: JSONObject = [
            "repo_id": .string(repo.id),
            "rows": .int(rows.count),
            "captions": .int(rows.count(where: { $0.caption != nil })),
            "pushed": .bool(false),
        ]
        guard push else { return summary }
        onProgress(HubProgress(phase: .preparing, total: candidates.count))

        var operations: [CommitOperation] = []
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("concept-captioner-hub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        if !candidates.isEmpty {
            try await client.createRepo(repo, private: isPrivate ?? false, existOK: true)
            let present = try await Set(client.listFiles(repo: repo, revision: revision).map(\.path))
            let missing = candidates.filter { !present.contains($0) }
            for (index, path) in missing.enumerated() {
                try await operations.append(.addFile(path: path, url: imageFile(
                    path, staging: staging, completed: index, total: missing.count, onProgress: onProgress
                )))
            }
        }
        operations.append(.add(
            path: ImageFolderMetadata.fileName,
            data: ImageFolderMetadata.serialize(rows, captionColumn: captionColumn)
        ))
        _ = try await client.commit(
            repo: repo, operations: operations, message: commitMessage, revision: revision, onProgress: onProgress
        )
        summary["pushed"] = .bool(true)
        return summary
    }

    /// What finalize would upload: one row per image in source order (buffered values win over
    /// existing ones, other columns of an existing row are kept, rows without an image are
    /// dropped), and the image paths finalize offers the target before checking what it has:
    /// none for the hub origin's own repo and revision, every image otherwise.
    public func materialize() async -> (rows: [MetadataRow], newImages: [String]) {
        let ids: [String]
        var existingRows: [String: MetadataRow] = [:]
        var newImages: [String] = []
        switch origin {
        case let .hub(source):
            ids = source.files.map(\.path)
            for row in source.rows where existingRows[row.fileName] == nil {
                existingRows[row.fileName] = row
            }
            if source.repo != repo || source.revision != revision {
                newImages = ids
            }
        case let .folder(source):
            ids = source.files.map(\.lastPathComponent)
            newImages = ids
        }
        let rows = ids.map { id in
            MetadataRow(
                fileName: id,
                caption: captions[id] ?? existingCaptions[id],
                record: records[id] ?? existingRecords[id],
                extra: existingRows[id]?.extra ?? [:]
            )
        }
        return (rows, newImages)
    }

    /// The file to commit for `path`: the folder's own file, or the origin's image downloaded
    /// into `staging` (reported as `.downloading`), so the commit can stream it from disk.
    private func imageFile(
        _ path: String,
        staging: URL,
        completed: Int,
        total: Int,
        onProgress: HubProgressHandler
    ) async throws -> URL {
        switch origin {
        case let .hub(source):
            let size = source.files.first(where: { $0.path == path })?.size ?? 0
            onProgress(HubProgress(phase: .downloading, path: path, completed: completed, total: total, bytes: size))
            let data = try await client.download(repo: source.repo, path: path, revision: source.revision)
            let file = staging.appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: file)
            } catch {
                throw HubError.transport("could not stage '\(path)' in \(staging.path): \(HubClient.describe(error))")
            }
            return file
        case let .folder(source):
            guard let file = source.files.first(where: { $0.lastPathComponent == path }) else {
                throw ConfigurationError("no image named '\(path)' in \(source.directory.path)")
            }
            return file
        }
    }
}
