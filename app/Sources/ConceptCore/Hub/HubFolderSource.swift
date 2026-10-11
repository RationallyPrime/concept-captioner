// A dataset repo in the imagefolder convention as an ImageSource. Parquet-backed datasets are
// out of scope for the Swift core in v1 (HubError.unsupported).

import Foundation

public struct HubFolderSource: ImageSource {
    public let name = "hub"
    public let client: HubClient
    public let repo: RepoID
    public let revision: String
    public let captionColumn: String
    /// Image and video targets, sorted by path.
    public let files: [HubFile]
    /// Existing metadata.jsonl rows ([] when absent).
    public let rows: [MetadataRow]

    public init(
        client: HubClient,
        repo: RepoID,
        revision: String,
        captionColumn: String,
        files: [HubFile],
        rows: [MetadataRow]
    ) {
        self.client = client
        self.repo = repo
        self.revision = revision
        self.captionColumn = captionColumn
        self.files = files
        self.rows = rows
    }

    /// Lists the repo once and reads the root metadata.jsonl when present. Media files anywhere
    /// in the tree count (their `file_name` is the path from the repo root); a repo whose only
    /// data lives in parquet shards is rejected.
    public static func open(
        client: HubClient,
        repo: RepoID,
        revision: String = "main",
        captionColumn: String = "caption"
    ) async throws -> HubFolderSource {
        let tree = try await client.listFiles(repo: repo, revision: revision)
        let images = tree.filter { HubFolderSource.isMedia($0.path) }
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        if images.isEmpty, tree.contains(where: { Sources.suffix(of: $0.path).lowercased() == ".parquet" }) {
            throw HubError.unsupported(
                "parquet-backed datasets are not supported by the Swift core; convert to imagefolder"
            )
        }
        var rows: [MetadataRow] = []
        if tree.contains(where: { $0.path == ImageFolderMetadata.fileName }) {
            let data = try await client.download(repo: repo, path: ImageFolderMetadata.fileName, revision: revision)
            rows = try ImageFolderMetadata.parse(data, captionColumn: captionColumn)
        }
        return HubFolderSource(
            client: client,
            repo: repo,
            revision: revision,
            captionColumn: captionColumn,
            files: images,
            rows: rows
        )
    }

    public func sampleIDs() async throws -> [String] {
        files.map(\.path)
    }

    public func count() async throws -> Int {
        files.count
    }

    /// Downloads each target when the consumer asks for it (a pull stream, like the Python async
    /// generator). A failed download ends the stream with that error.
    public func samples() -> AsyncThrowingStream<Sample, any Error> {
        samples(only: nil)
    }

    /// `samples()` over the listed files whose path is in `ids`; the others are never downloaded.
    public func samples(only ids: Set<String>?) -> AsyncThrowingStream<Sample, any Error> {
        let wanted = ids.map { ids in files.filter { ids.contains($0.path) } } ?? files
        let cursor = Cursor(files: wanted, client: client, repo: repo, revision: revision)
        return AsyncThrowingStream(unfolding: { try await cursor.next() })
    }

    static func isMedia(_ path: String) -> Bool {
        let lastComponent = path.split(separator: "/").last.map(String.init) ?? path
        return Sources.mediaSuffixes.contains(Sources.suffix(of: lastComponent).lowercased())
    }

    /// Walks the file list; an actor so the pull closure stays `Sendable` without a lock.
    private actor Cursor {
        private var remaining: ArraySlice<HubFile>
        private let client: HubClient
        private let repo: RepoID
        private let revision: String

        init(files: [HubFile], client: HubClient, repo: RepoID, revision: String) {
            remaining = files[...]
            self.client = client
            self.repo = repo
            self.revision = revision
        }

        func next() async throws -> Sample? {
            guard let file = remaining.popFirst() else { return nil }
            let data = try await client.download(repo: repo, path: file.path, revision: revision)
            let lastComponent = file.path.split(separator: "/").last.map(String.init) ?? file.path
            return Sample(sampleID: file.path, data: data, suffix: Sources.suffix(of: lastComponent))
        }
    }
}
