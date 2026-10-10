// HubClient commit/LFS over StubTransport and HubFolderSource. See docs/CORE-SPEC.md, module `hub`.
// HubFolderSink is covered in HubSinkTests.swift, on the same scripted `Hub`.

import ConceptCore
import CryptoKit
import Foundation
import Synchronization
import Testing

/// A scripted Hub: routes a StubTransport by "METHOD /path"; replies are built inside the handler.
/// Shared with HubSinkTests.swift.
enum Hub {
    static let endpoint = URL(string: "https://huggingface.co")!
    static let repo = "ns/name"
    static let commitOID = "0123456789abcdef0123456789abcdef01234567"
    static let commitURL = "https://huggingface.co/datasets/ns/name/commit/\(commitOID)"
    static let preuploadRoute = "POST /api/datasets/ns/name/preupload/main"
    static let batchRoute = "POST /datasets/ns/name.git/info/lfs/objects/batch"
    static let commitRoute = "POST /api/datasets/ns/name/commit/main"
    static let treeRoute = "GET /api/datasets/ns/name/tree/main"
    static let bearer = "Bearer hf_test_token"
    static let existingCaption = "A photo of NORA7, a woman."
    static let existingRecord = record("a.png", caption: existingCaption)
    static let width: JSONObject = ["width": .int(256)]
    static let existingRow = MetadataRow(
        fileName: "a.png",
        caption: existingCaption,
        record: existingRecord,
        extra: width
    )

    static func client(_ transport: StubTransport, token: String? = "hf_test_token") -> HubClient {
        HubClient(token: token, endpoint: endpoint, transport: transport)
    }

    static func route(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "GET") \(request.url?.path(percentEncoded: false) ?? "")"
    }

    static func file(_ path: String, size: Int, lfs: Bool) -> [String: Any] {
        var item: [String: Any] = ["type": "file", "path": path, "size": lfs ? 134 : size, "oid": "blob-\(path)"]
        if lfs {
            item["lfs"] = ["oid": "sha-\(path)", "size": size, "pointerSize": 134]
        }
        return item
    }

    /// Preupload: `lfs` for image suffixes, `regular` otherwise; dotfiles are flagged shouldIgnore.
    static func preupload(_ request: URLRequest) throws -> HTTPResponse {
        let files = try StubTransport.body(of: request)["files"] as? [[String: Any]] ?? []
        let answer: [[String: Any]] = files.map { file in
            let path = file["path"] as? String ?? ""
            let isImage = Sources.imageSuffixes.contains(Sources.suffix(of: path).lowercased())
            return ["path": path, "uploadMode": isImage ? "lfs" : "regular", "shouldIgnore": path.hasPrefix(".")]
        }
        return try StubTransport.json(["files": answer])
    }

    /// LFS batch: one upload action per object at https://lfs.test/upload/<oid> with a header.
    static func batch(_ request: URLRequest) throws -> HTTPResponse {
        let objects = try StubTransport.body(of: request)["objects"] as? [[String: Any]] ?? []
        let answer: [[String: Any]] = objects.map { object in
            let oid = object["oid"] as? String ?? ""
            let upload: [String: Any] = [
                "href": "https://lfs.test/upload/\(oid)",
                "header": ["x-upload-token": "t-\(oid)"],
            ]
            return ["oid": oid, "size": object["size"] ?? 0, "actions": ["upload": upload]]
        }
        return try StubTransport.json(["transfer": "basic", "objects": answer])
    }

    /// The default commit flow (preupload / batch / PUT / commit) behind `extra`, which answers first.
    static func commitTransport(
        extra: @escaping @Sendable (URLRequest) throws -> HTTPResponse? = { _ in nil }
    ) -> StubTransport {
        StubTransport { request in
            if let response = try extra(request) { return response }
            return switch route(request) {
            case preuploadRoute: try preupload(request)
            case batchRoute: try batch(request)
            case let route where route.hasPrefix("PUT /upload/"): HTTPResponse(status: 200)
            case commitRoute: try StubTransport.json(["commitUrl": commitURL, "commitOid": commitOID])
            default: HTTPResponse(status: 404, body: Data("no route for \(route(request))".utf8))
            }
        }
    }

    /// The NDJSON lines of a commit request as (key, value) pairs.
    static func commitLines(_ request: URLRequest) throws -> [(key: String, value: [String: Any])] {
        try text(request.httpBody ?? Data()).split(separator: "\n").map { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try (#require(object["key"] as? String), #require(object["value"] as? [String: Any]))
        }
    }

    static func base64(_ value: Any?) throws -> Data {
        let text = try #require(value as? String)
        return try #require(Data(base64Encoded: text))
    }

    static func text(_ data: Data) throws -> String {
        try #require(String(data: data, encoding: .utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Collects the `HubProgress` reports a commit or finalize hands out, in order.
    final class ProgressLog: Sendable {
        private let seen = Mutex<[HubProgress]>([])
        var handler: HubProgressHandler {
            { progress in self.seen.withLock { $0.append(progress) } }
        }

        var reports: [HubProgress] {
            seen.withLock { $0 }
        }

        /// "phase path done/total bytes" per report, for one-line comparisons.
        var lines: [String] {
            reports.map { "\($0.phase.rawValue) \($0.path ?? "-") \($0.completed)/\($0.total) \($0.bytes)" }
        }
    }

    /// Staging folders HubFolderSink leaves behind (it should leave none).
    static func stagingFolders() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("concept-captioner-hub-") }
    }

    static func record(_ sampleID: String, caption: String) -> ResponseRecord {
        ResponseRecord(
            sampleID: sampleID, status: .written, skill: "diffusion-training-captioner", profile: "h3-still",
            captioner: ModelNames(requested: "cap-1", served: "cap-1"), critic: nil, attempts: 1, requests: 1,
            caption: Caption(caption: caption)
        )
    }

    /// A hub origin for ns/name with a captioned a.png and an uncaptioned b.jpg, no network behind it.
    static func origin(_ transport: StubTransport) throws -> HubFolderSource {
        try HubFolderSource(
            client: client(transport), repo: RepoID(repo), revision: "main", captionColumn: "caption",
            files: [
                HubFile(path: "a.png", size: 4096, oid: "sha-a", isLFS: true),
                HubFile(path: "b.jpg", size: 3, oid: "blob-b", isLFS: false),
            ],
            rows: [
                existingRow, MetadataRow(fileName: "b.jpg"), MetadataRow(fileName: "gone.png", caption: "orphan"),
            ]
        )
    }
}

// MARK: - RepoID and metadata

@Suite("hub metadata")
struct HubMetadataTests {
    @Test("RepoID accepts ns/name and bare names only")
    func repoID() throws {
        let scoped = try RepoID("ns/name")
        #expect(scoped.namespace == "ns" && scoped.name == "name" && scoped.id == "ns/name")
        #expect(String(describing: scoped) == "ns/name")
        let bare = try RepoID("name-only.v2")
        #expect(bare.namespace == nil && bare.id == "name-only.v2")
        for bad in ["", "a/b/c", "ns/", "/name", "a b", "ns/../x", "ns/na\u{E9}me"] {
            let error = #expect(throws: HubError.self) { try RepoID(bad) }
            #expect(error?.localizedDescription.hasPrefix("malformed: repo id must look like") == true, "'\(bad)'")
        }
    }

    @Test("metadata.jsonl rows parse, keep extra columns, and serialize in the Python column order")
    func parseAndSerialize() throws {
        let record = Hub.record("a.png", caption: "A photo of NORA7.")
        let recordString = JSONValue.string(record.jsonValue.pythonDumps()).pythonDumps()
        let text = """
        {"file_name": "a.png", "width": 256, "caption": "A photo of NORA7.", "caption_response": \(recordString)}

        {"file_name": "b.jpg", "caption": "", "caption_response": ""}\r
        {"file_name": "c.webp", "caption_response": \(record.jsonValue.pythonDumps())}
        {"file_name": "d.png", "caption": null, "caption_response": "{}"}
        {"file_name": "e.png", "caption_response": "not json"}
        """
        let rows = try ImageFolderMetadata.parse(Data(text.utf8))
        #expect(rows.map(\.fileName) == ["a.png", "b.jpg", "c.webp", "d.png", "e.png"])
        #expect(rows[0].caption == "A photo of NORA7." && rows[0].record == record)
        #expect(rows[0].extra == ["width": .int(256)])
        #expect(rows[1].caption == nil && rows[1].record == nil)
        #expect(rows[2].caption == nil)
        #expect(rows[2].record == record, "an object record column is accepted on read")
        #expect(rows[3].record?.sampleID == "d.png", "{} is an empty record, as json.loads keeps it")
        #expect(rows[4].record == nil, "an undecodable record is ignored, as in Python")

        let serialized = ImageFolderMetadata.serialize(Array(rows.prefix(2)))
        let lines = try Hub.text(serialized).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3 && lines[2].isEmpty, "one newline-terminated line per row")
        #expect(lines[0].hasPrefix(#"{"file_name": "a.png", "width": 256, "caption": "A photo of NORA7.", "#))
        #expect(lines[1] == #"{"file_name": "b.jpg", "caption": "", "caption_response": ""}"#)
        #expect(try ImageFolderMetadata.parse(serialized) == Array(rows.prefix(2)), "round trip")

        let row = MetadataRow(fileName: "x.png", caption: "c")
        let custom = ImageFolderMetadata.serialize([row], captionColumn: "text")
        #expect(try Hub.text(custom) == "{\"file_name\": \"x.png\", \"text\": \"c\", \"text_response\": \"\"}\n")
        #expect(try ImageFolderMetadata.parse(custom, captionColumn: "text")[0].caption == "c")
    }

    @Test("malformed metadata lines are HubError.malformed")
    func malformedLines() {
        for bad in ["[1, 2]", "{\"caption\": \"x\"}", "{\"file_name\": \"a.png\", \"caption\": 3}", "{not json"] {
            let error = #expect(throws: HubError.self) { try ImageFolderMetadata.parse(Data(bad.utf8)) }
            #expect(error?.localizedDescription.hasPrefix("malformed: metadata.jsonl line 1") == true, "\(bad)")
        }
    }
}

// MARK: - HubClient

@Suite("hub client")
struct HubClientTests {
    @Test("listFiles follows the Link next cursor and keeps files only, marking LFS")
    func listFilesPaged() async throws {
        let pageTwo = "https://huggingface.co/api/datasets/ns/name/tree/main?cursor=abc&recursive=true"
        let transport = StubTransport { request in
            guard Hub.route(request) == Hub.treeRoute else { return HTTPResponse(status: 404) }
            if request.url?.query()?.contains("cursor=abc") == true {
                return try StubTransport.json([Hub.file("sub/b.jpg", size: 10, lfs: false)])
            }
            #expect(request.url?.query() == "recursive=true")
            #expect(request.value(forHTTPHeaderField: "Authorization") == Hub.bearer)
            let link = "<https://huggingface.co/api/datasets/ns/name/tree/main?cursor=zzz>; rel=\"first\", <\(pageTwo)>; rel=\"next\""
            return try StubTransport.json(
                [Hub.file("a.png", size: 2048, lfs: true), ["type": "directory", "path": "sub", "oid": "tree-sub"]],
                headers: ["link": link]
            )
        }
        let files = try await Hub.client(transport).listFiles(repo: RepoID(Hub.repo))
        #expect(files == [
            HubFile(path: "a.png", size: 2048, oid: "sha-a.png", isLFS: true),
            HubFile(path: "sub/b.jpg", size: 10, oid: "blob-sub/b.jpg", isLFS: false),
        ])
        let requests = await transport.requests
        #expect(requests.count == 2 && requests[1].url?.absoluteString == pageTwo)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == Hub.bearer)
    }

    @Test("download resolves the percent-encoded path with the bearer token")
    func download() async throws {
        let transport = StubTransport { request in
            HTTPResponse(status: 200, body: Data("bytes of \(request.url?.path(percentEncoded: false) ?? "")".utf8))
        }
        let data = try await Hub.client(transport).download(repo: RepoID(Hub.repo), path: "sub/a b.png")
        #expect(try Hub.text(data) == "bytes of /datasets/ns/name/resolve/main/sub/a b.png")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://huggingface.co/datasets/ns/name/resolve/main/sub/a%20b.png")
        #expect(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == Hub.bearer)

        let anonymous = Hub.client(transport, token: nil)
        _ = try await anonymous.download(repo: RepoID("solo"), path: "x.png", revision: "refs/pr/1")
        let last = try #require(await transport.requests.last)
        #expect(last.url?.absoluteString == "https://huggingface.co/datasets/solo/resolve/refs%2Fpr%2F1/x.png")
        #expect(last.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("HTTP failures, transport failures and non-JSON replies map to HubError")
    func failures() async throws {
        let failing = StubTransport { _ in HTTPResponse(status: 403, body: Data("Forbidden: nope".utf8)) }
        let denied = await #expect(throws: HubError.self) {
            try await Hub.client(failing).download(repo: RepoID(Hub.repo), path: "x.png")
        }
        #expect(denied?.localizedDescription == "HTTP 403: Forbidden: nope")

        let broken = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let offline = await #expect(throws: HubError.self) {
            try await Hub.client(broken).listFiles(repo: RepoID(Hub.repo))
        }
        #expect(offline?.localizedDescription.hasPrefix("transport:") == true)

        let garbage = StubTransport { _ in HTTPResponse(status: 200, body: Data("<html>".utf8)) }
        let notJSON = await #expect(throws: HubError.self) {
            try await Hub.client(garbage).listFiles(repo: RepoID(Hub.repo))
        }
        #expect(notJSON?.localizedDescription == "malformed: reply is not JSON: <html>")
    }

    @Test("createRepo posts the dataset shape and treats 409 as success only with existOK")
    func createRepo() async throws {
        let transport = StubTransport { request in
            #expect(Hub.route(request) == "POST /api/repos/create")
            return try StubTransport.json(["error": "You already created this dataset repo"], status: 409)
        }
        let client = Hub.client(transport)
        try await client.createRepo(RepoID(Hub.repo), private: true)
        let body = try StubTransport.body(of: #require(await transport.requests.first))
        #expect(body["type"] as? String == "dataset" && body["name"] as? String == "name")
        #expect(body["organization"] as? String == "ns" && body["private"] as? Bool == true)

        let error = await #expect(throws: HubError.self) {
            try await client.createRepo(RepoID(Hub.repo), existOK: false)
        }
        #expect(error?.localizedDescription.hasPrefix("HTTP 409:") == true)

        try await client.createRepo(RepoID("bare"))
        let bare = try StubTransport.body(of: #require(await transport.requests.last))
        #expect(bare["organization"] == nil && bare["private"] as? Bool == false)
    }

    @Test("commit: preupload, LFS batch, PUT without the Hub token, then one NDJSON commit")
    func commitWithLFS() async throws {
        let small = Data("{\"file_name\": \"big.png\", \"caption\": \"x\"}\n".utf8)
        let big = Data((0 ..< 2 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let bigOID = Hub.sha256(big)
        let transport = Hub.commitTransport()
        let result = try await Hub.client(transport).commit(
            repo: RepoID(Hub.repo),
            operations: [
                .add(path: "metadata.jsonl", data: small),
                .add(path: "big.png", data: big),
                .delete(path: "old.txt"),
            ],
            message: "Add captions",
            description: "two files"
        )
        #expect(result == CommitResult(commitOID: Hub.commitOID, commitURL: Hub.commitURL))

        let requests = await transport.requests
        #expect(requests.map(Hub.route) == [
            Hub.preuploadRoute,
            Hub.batchRoute,
            "PUT /upload/\(bigOID)",
            Hub.commitRoute,
        ])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            Hub.bearer,
            Hub.bearer,
            nil,
            Hub.bearer,
        ])

        let preupload = try StubTransport.body(of: requests[0])
        let sampled = try #require(preupload["files"] as? [[String: Any]])
        #expect(sampled.map { $0["path"] as? String } == ["metadata.jsonl", "big.png"])
        #expect(sampled.map { $0["size"] as? Int } == [small.count, big.count])
        #expect(try sampled.map { try Hub.base64($0["sample"]) } == [small, big.prefix(512)])

        let batch = try StubTransport.body(of: requests[1])
        #expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/vnd.git-lfs+json")
        #expect(batch["operation"] as? String == "upload" && batch["hash_algo"] as? String == "sha256")
        #expect(batch["transfers"] as? [String] == ["basic", "multipart"])
        let objects = try #require(batch["objects"] as? [[String: Any]])
        #expect(objects.count == 1 && objects[0]["oid"] as? String == bigOID && objects[0]["size"] as? Int == big.count)

        #expect(requests[2].url?.absoluteString == "https://lfs.test/upload/\(bigOID)")
        #expect(requests[2].httpBody == big)
        #expect(requests[2].value(forHTTPHeaderField: "x-upload-token") == "t-\(bigOID)")

        #expect(requests[3].value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson")
        let lines = try Hub.commitLines(requests[3])
        #expect(lines.map(\.key) == ["header", "file", "lfsFile", "deletedFile"])
        #expect(lines[0].value["summary"] as? String == "Add captions")
        #expect(lines[0].value["description"] as? String == "two files")
        #expect(lines[1].value["path"] as? String == "metadata.jsonl")
        #expect(lines[1].value["encoding"] as? String == "base64")
        #expect(try Hub.base64(lines[1].value["content"]) == small)
        #expect(lines[2].value["path"] as? String == "big.png" && lines[2].value["algo"] as? String == "sha256")
        #expect(lines[2].value["oid"] as? String == bigOID && lines[2].value["size"] as? Int == big.count)
        #expect(lines[3].value["path"] as? String == "old.txt")
    }

    @Test("commit: a stored LFS object skips the PUT; ignored files drop; multipart unsupported; empty refused")
    func commitEdges() async throws {
        let stored = Fixtures.syntheticPNG(seed: 4, size: CGSize(width: 32, height: 32))
        let huge = Fixtures.syntheticPNG(seed: 5, size: CGSize(width: 32, height: 32))
        let transport = Hub.commitTransport { request in
            guard Hub.route(request) == Hub.batchRoute else { return nil }
            let objects = try StubTransport.body(of: request)["objects"] as? [[String: Any]] ?? []
            let answer: [[String: Any]] = objects.map { object in
                // No actions: the server already stores it. The huge one gets a multipart (chunked) action.
                guard object["oid"] as? String == Hub.sha256(huge) else { return object }
                let upload: [String: Any] = ["href": "https://lfs.test/multi", "header": ["chunk_size": "5000000"]]
                return ["oid": object["oid"] ?? "", "size": object["size"] ?? 0, "actions": ["upload": upload]]
            }
            return try StubTransport.json(["objects": answer])
        }
        let client = Hub.client(transport)
        _ = try await client.uploadFile(repo: RepoID(Hub.repo), path: "a.png", data: stored, message: "m")
        let requests = await transport.requests
        #expect(requests.map(Hub.route) == [Hub.preuploadRoute, Hub.batchRoute, Hub.commitRoute], "no PUT")
        let lines = try Hub.commitLines(#require(requests.last))
        #expect(lines.map(\.key) == ["header", "lfsFile"] && lines[1].value["oid"] as? String == Hub.sha256(stored))

        let multipart = await #expect(throws: HubError.self) {
            try await client.commit(
                repo: RepoID(Hub.repo),
                operations: [.add(path: "huge.png", data: huge), .add(path: ".DS_Store", data: Data([0]))],
                message: "m"
            )
        }
        #expect(multipart?.localizedDescription == "unsupported: multipart LFS upload (> 5 GB) is not supported")
        let batch = try StubTransport.body(of: #require(await transport.requests.last))
        #expect((batch["objects"] as? [[String: Any]])?.count == 1, "the ignored file never reaches the LFS batch")

        let empty = await #expect(throws: HubError.self) {
            try await client.commit(repo: RepoID(Hub.repo), operations: [], message: "m")
        }
        #expect(empty?.localizedDescription == "malformed: a commit needs at least one operation")
    }

    @Test("commit: addFile samples, hashes and PUTs from disk, reporting each LFS file; an unreadable file fails early")
    func commitFromDisk() async throws {
        let folder = try Fixtures.tempDirectory()
        let small = Data("{\"file_name\": \"big.png\", \"caption\": \"x\"}\n".utf8)
        // Larger than one hashing chunk, so the streaming hash covers more than one read.
        let big = Data((0 ..< 3 * 1024 * 1024 + 17).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        let smallFile = folder.appendingPathComponent("metadata.jsonl")
        let bigFile = folder.appendingPathComponent("big.png")
        try small.write(to: smallFile)
        try big.write(to: bigFile)
        let bigOID = Hub.sha256(big)
        let transport = Hub.commitTransport()
        let progress = Hub.ProgressLog()
        let result = try await Hub.client(transport).commit(
            repo: RepoID(Hub.repo),
            operations: [.addFile(path: "metadata.jsonl", url: smallFile), .addFile(path: "big.png", url: bigFile)],
            message: "From disk",
            onProgress: progress.handler
        )
        #expect(result == CommitResult(commitOID: Hub.commitOID, commitURL: Hub.commitURL))

        let requests = await transport.requests
        #expect(requests.map(Hub.route) == [
            Hub.preuploadRoute,
            Hub.batchRoute,
            "PUT /upload/\(bigOID)",
            Hub.commitRoute,
        ])
        let sampled = try #require(StubTransport.body(of: requests[0])["files"] as? [[String: Any]])
        #expect(sampled.map { $0["size"] as? Int } == [small.count, big.count])
        #expect(try sampled.map { try Hub.base64($0["sample"]) } == [small, big.prefix(512)])
        let objects = try #require(StubTransport.body(of: requests[1])["objects"] as? [[String: Any]])
        #expect(objects.count == 1 && objects[0]["oid"] as? String == bigOID && objects[0]["size"] as? Int == big.count)
        #expect(requests[2].httpBody == big)
        let lines = try Hub.commitLines(requests[3])
        #expect(lines.map(\.key) == ["header", "file", "lfsFile"])
        #expect(try Hub.base64(lines[1].value["content"]) == small, "a regular file is read from disk for the commit")
        #expect(lines[2].value["oid"] as? String == bigOID && lines[2].value["size"] as? Int == big.count)
        #expect(progress.lines == [
            "hashing big.png 0/1 \(big.count)",
            "uploading big.png 0/1 \(big.count)",
            "committing - 0/2 0",
        ])

        let missing = await #expect(throws: HubError.self) {
            try await Hub.client(transport).commit(
                repo: RepoID(Hub.repo),
                operations: [.addFile(path: "gone.png", url: folder.appendingPathComponent("gone.png"))],
                message: "m"
            )
        }
        #expect(missing?.localizedDescription.hasPrefix("transport: could not read '") == true)
        #expect(await transport.requests.count == 4, "an unreadable file is refused before anything is sent")
    }
}

// MARK: - HubFolderSource

@Suite("hub source")
struct HubFolderSourceTests {
    @Test("open lists image files in path order, reads metadata.jsonl and streams downloads")
    func openImagefolder() async throws {
        let metadata = ImageFolderMetadata.serialize([
            MetadataRow(fileName: "a.png", caption: Hub.existingCaption, record: Hub.existingRecord),
            MetadataRow(fileName: "b.jpg"),
        ])
        let transport = StubTransport { request in
            switch Hub.route(request) {
            case Hub.treeRoute:
                try StubTransport.json([
                    Hub.file("README.md", size: 12, lfs: false),
                    Hub.file("metadata.jsonl", size: metadata.count, lfs: false),
                    Hub.file("b.jpg", size: 3, lfs: false),
                    Hub.file("a.png", size: 4096, lfs: true),
                    ["type": "directory", "path": "notes", "oid": "tree-notes"],
                ])
            case "GET /datasets/ns/name/resolve/main/metadata.jsonl":
                HTTPResponse(status: 200, body: metadata)
            case let route where route.hasPrefix("GET /datasets/ns/name/resolve/main/"):
                HTTPResponse(status: 200, body: Data("image:\(route.split(separator: "/").last ?? "")".utf8))
            default: HTTPResponse(status: 404)
            }
        }
        let source = try await HubFolderSource.open(client: Hub.client(transport), repo: RepoID(Hub.repo))
        #expect(source.name == "hub" && source.files.map(\.path) == ["a.png", "b.jpg"])
        #expect(source.files[0].isLFS && !source.files[1].isLFS)
        #expect(try await source.sampleIDs() == ["a.png", "b.jpg"])
        #expect(try await source.count() == 2)
        #expect(source.rows.map(\.fileName) == ["a.png", "b.jpg"])
        #expect(source.rows[0].caption == Hub.existingCaption && source.rows[0].record == Hub.existingRecord)
        #expect(source.rows[1].caption == nil)

        let samples = try await source.samples().reduce(into: [Sample]()) { $0.append($1) }
        #expect(samples == [
            Sample(sampleID: "a.png", data: Data("image:a.png".utf8), suffix: ".png"),
            Sample(sampleID: "b.jpg", data: Data("image:b.jpg".utf8), suffix: ".jpg"),
        ])
        let routes = await transport.requests.map(Hub.route)
        #expect(routes == [
            Hub.treeRoute,
            "GET /datasets/ns/name/resolve/main/metadata.jsonl",
            "GET /datasets/ns/name/resolve/main/a.png",
            "GET /datasets/ns/name/resolve/main/b.jpg",
        ], "the listing happens once; images download lazily")
    }

    @Test("a parquet-backed dataset is HubError.unsupported")
    func parquet() async throws {
        let parquet = StubTransport { request in
            guard Hub.route(request) == Hub.treeRoute else { return HTTPResponse(status: 404) }
            return try StubTransport.json([Hub.file("data/train-00000-of-00001.parquet", size: 9000, lfs: true)])
        }
        let error = await #expect(throws: HubError.self) {
            try await HubFolderSource.open(client: Hub.client(parquet), repo: RepoID(Hub.repo))
        }
        #expect(error?.localizedDescription.contains("parquet-backed datasets are not supported") == true)
    }
}
