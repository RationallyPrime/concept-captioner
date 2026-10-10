// HubFolderSink over the scripted `Hub` of HubTests.swift: buffering, finalize commits, progress
// reports and the memory-bounded image path. See docs/CORE-SPEC.md, module `hub`.

import ConceptCore
import Foundation
import Testing

// MARK: - HubFolderSink

@Suite("hub sink")
struct HubFolderSinkTests {
    @Test("hub origin: existing rows seed exists/record; finalize commits one metadata.jsonl")
    func hubOriginFinalize() async throws {
        let transport = Hub.commitTransport()
        let sink = try HubFolderSink(client: Hub.client(transport), origin: .hub(Hub.origin(transport)))
        #expect(sink.repo.id == "ns/name", "the target defaults to the origin repo")
        #expect(try await sink.exists("a.png"))
        #expect(try await sink.exists("b.jpg") == false)
        #expect(try await sink.record("a.png") == Hub.existingRecord)
        #expect(try await sink.record("b.jpg") == nil)

        let newRecord = Hub.record("b.jpg", caption: "A photo of IVAN9, a man.")
        try await sink.write("b.jpg", caption: "A photo of IVAN9, a man.", record: newRecord)
        #expect(try await sink.exists("b.jpg"))
        #expect(try await sink.record("b.jpg") == newRecord)

        let preview = await sink.materialize()
        #expect(preview.newImages.isEmpty)
        #expect(preview.rows.map(\.fileName) == ["a.png", "b.jpg"], "rows follow the images; the orphan row is dropped")

        let summary = try await sink.finalize()
        #expect(summary == ["repo_id": .string("ns/name"), "rows": .int(2), "captions": .int(2), "pushed": .bool(true)])
        let requests = await transport.requests
        #expect(requests.map(Hub.route) == [Hub.preuploadRoute, Hub.commitRoute])

        let lines = try Hub.commitLines(#require(requests.last))
        #expect(lines.map(\.key) == ["header", "file"])
        #expect(lines[0].value["summary"] as? String == "Add captions (concept-captioner)")
        #expect(lines[1].value["path"] as? String == "metadata.jsonl")
        let uploaded = try Hub.base64(lines[1].value["content"])
        let added = MetadataRow(fileName: "b.jpg", caption: "A photo of IVAN9, a man.", record: newRecord)
        #expect(try ImageFolderMetadata.parse(uploaded) == [Hub.existingRow, added])
        #expect(try Hub.text(uploaded).contains(#""caption_response": "{\"sample_id\": \"b.jpg\""#), "a JSON string")
    }

    @Test("hub origin: a caption-less record and a rewrite are buffered like Python; push: false never commits")
    func bufferingRules() async throws {
        let transport = Hub.commitTransport()
        let sink = try HubFolderSink(client: Hub.client(transport), origin: .hub(Hub.origin(transport)), push: false)
        var unusable = Hub.record("b.jpg", caption: "")
        unusable.status = .unusable
        try await sink.write("b.jpg", caption: nil, record: unusable)
        #expect(try await sink.exists("b.jpg") == false, "a record without a caption is not a caption")
        #expect(try await sink.record("b.jpg") == unusable)

        let rewritten = Hub.record("a.png", caption: "A photo of NORA7, a woman, seated.")
        try await sink.write("a.png", caption: "A photo of NORA7, a woman, seated.", record: rewritten)
        let rows = await sink.materialize().rows
        #expect(rows[0].caption == "A photo of NORA7, a woman, seated.", "buffered values win over existing")
        #expect(rows[0].record == rewritten)
        #expect(rows[1].caption == nil && rows[1].record == unusable)

        let summary = try await sink.finalize()
        #expect(summary == [
            "repo_id": .string("ns/name"),
            "rows": .int(2),
            "captions": .int(1),
            "pushed": .bool(false),
        ])
        let untouched = await transport.requests
        #expect(untouched.isEmpty, "push: false never touches the Hub")
    }

    @Test("folder origin: the repo is created and the commit carries the images with metadata.jsonl")
    func folderOriginFinalize() async throws {
        let folder = try LocalFolderSource(directory: Fixtures.imagesFolder())
        let transport = Hub.commitTransport { request in
            switch Hub.route(request) {
            case "POST /api/repos/create": try StubTransport.json(["url": "https://huggingface.co/datasets/ns/name"])
            case Hub.treeRoute: try StubTransport.json([Hub.file(".gitattributes", size: 10, lfs: false)])
            default: nil
            }
        }
        let progress = Hub.ProgressLog()
        let sink = try HubFolderSink(
            client: Hub.client(transport), repo: RepoID(Hub.repo), origin: .folder(folder), private: true,
            commitMessage: "Captions from a folder", onProgress: progress.handler
        )
        let record = Hub.record("solo.png", caption: Hub.existingCaption)
        try await sink.write("solo.png", caption: Hub.existingCaption, record: record)
        let preview = await sink.materialize()
        #expect(preview.newImages == ["pair.png", "solo.png", "unmapped.png"])
        #expect(preview.rows.map(\.fileName) == ["pair.png", "solo.png", "unmapped.png"])

        let summary = try await sink.finalize()
        #expect(summary == ["repo_id": .string("ns/name"), "rows": .int(3), "captions": .int(1), "pushed": .bool(true)])
        let sizes = try folder.files.map { try Data(contentsOf: $0).count }
        #expect(progress.lines == [
            "preparing - 0/3 0",
            "hashing pair.png 0/3 \(sizes[0])", "hashing solo.png 1/3 \(sizes[1])",
            "hashing unmapped.png 2/3 \(sizes[2])",
            "uploading pair.png 0/3 \(sizes[0])", "uploading solo.png 1/3 \(sizes[1])",
            "uploading unmapped.png 2/3 \(sizes[2])",
            "committing - 0/4 0",
        ], "the handler given at init hears every step of finalize()")

        let requests = await transport.requests
        let routes = requests.map(Hub.route)
        #expect(routes.prefix(4) == ["POST /api/repos/create", Hub.treeRoute, Hub.preuploadRoute, Hub.batchRoute])
        #expect(routes.count(where: { $0.hasPrefix("PUT /upload/") }) == 3 && routes.last == Hub.commitRoute)
        #expect(try StubTransport.body(of: requests[0])["private"] as? Bool == true)

        let lines = try Hub.commitLines(#require(requests.last))
        #expect(lines.map(\.key) == ["header", "lfsFile", "lfsFile", "lfsFile", "file"])
        #expect(lines[0].value["summary"] as? String == "Captions from a folder")
        #expect(lines[1 ... 3].map { $0.value["path"] as? String } == ["pair.png", "solo.png", "unmapped.png"])
        let solo = try Data(contentsOf: folder.files[1])
        #expect(lines[2].value["oid"] as? String == Hub.sha256(solo) && lines[2].value["size"] as? Int == solo.count)
        #expect(lines[4].value["path"] as? String == "metadata.jsonl")
        #expect(try ImageFolderMetadata.parse(Hub.base64(lines[4].value["content"])) == [
            MetadataRow(fileName: "pair.png"),
            MetadataRow(fileName: "solo.png", caption: Hub.existingCaption, record: record),
            MetadataRow(fileName: "unmapped.png"),
        ])
        let puts = requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(try Set(puts.compactMap(\.httpBody)) == Set(folder.files.map { try Data(contentsOf: $0) }))
    }

    @Test("another target is created and gets only the images it lacks, downloaded from the hub origin")
    func hubOriginToOtherRepo() async throws {
        let transport = Hub.commitTransport { request in
            switch Hub.route(request) {
            case "POST /api/repos/create": try StubTransport.json(["error": "exists"], status: 409)
            case "GET /api/datasets/ns/copy/tree/main": try StubTransport.json([Hub.file("a.png", size: 1, lfs: true)])
            case "GET /datasets/ns/name/resolve/main/b.jpg": HTTPResponse(status: 200, body: Data("B".utf8))
            case "POST /api/datasets/ns/copy/preupload/main": try Hub.preupload(request)
            case "POST /datasets/ns/copy.git/info/lfs/objects/batch": try Hub.batch(request)
            case "POST /api/datasets/ns/copy/commit/main": try StubTransport.json(["commitUrl": "u", "commitOid": "o"])
            default: nil
            }
        }
        let origin = try Hub.origin(transport)
        let sink = try HubFolderSink(client: Hub.client(transport), repo: RepoID("ns/copy"), origin: .hub(origin))
        #expect(await sink.materialize().newImages == ["a.png", "b.jpg"])
        let before = try Set(Hub.stagingFolders())
        let progress = Hub.ProgressLog()
        let summary = try await sink.finalize(onProgress: progress.handler)
        #expect(summary["repo_id"] == .string("ns/copy") && summary["pushed"] == .bool(true))
        #expect(progress.lines == [
            "preparing - 0/2 0", "downloading b.jpg 0/1 3", "hashing b.jpg 0/1 1", "uploading b.jpg 0/1 1",
            "committing - 0/2 0",
        ], "`.downloading` reports the origin's size, the commit steps the downloaded bytes")
        #expect(try Set(Hub.stagingFolders()).subtracting(before).isEmpty, "the staged download is removed")
        let routes = await transport.requests.map(Hub.route)
        #expect(routes[0] == "POST /api/repos/create" && routes[1] == "GET /api/datasets/ns/copy/tree/main")
        #expect(routes[2] == "GET /datasets/ns/name/resolve/main/b.jpg", "only the missing image is fetched")
        let lines = try Hub.commitLines(#require(await transport.requests.last))
        #expect(lines.map { $0.value["path"] as? String } == [nil, "b.jpg", "metadata.jsonl"])
        #expect(lines[1].value["oid"] as? String == Hub.sha256(Data("B".utf8)))
    }

    @Test("init validates the target and the caption column")
    func initValidation() throws {
        let transport = Hub.commitTransport()
        let folder = try LocalFolderSource(directory: Fixtures.imagesFolder())
        let noTarget = #expect(throws: ConfigurationError.self) {
            try HubFolderSink(client: Hub.client(transport), origin: .folder(folder))
        }
        #expect(noTarget?.message == "a folder source needs an explicit target repo id")
        let origin = try Hub.origin(transport)
        for column in ["", " caption", "file_name"] {
            #expect(throws: ConfigurationError.self, "'\(column)'") {
                try HubFolderSink(client: Hub.client(transport), origin: .hub(origin), captionColumn: column)
            }
        }
    }
}
