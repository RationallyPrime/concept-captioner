// LocalFolderSource and SidecarSink. See docs/CORE-SPEC.md, module `sources`.

import ConceptCore
import Foundation
import Testing

@Suite("sources")
struct SourcesTests {
    // MARK: - Helpers

    private func folder(_ files: [String: Data], directories: [String] = []) throws -> URL {
        let url = try Fixtures.tempDirectory()
        for name in directories {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        for (name, data) in files {
            try data.write(to: url.appendingPathComponent(name))
        }
        return url
    }

    private func collect(_ source: LocalFolderSource) async throws -> [Sample] {
        var samples: [Sample] = []
        for try await sample in source.samples() {
            samples.append(sample)
        }
        return samples
    }

    private func entries(of directory: URL) throws -> Set<String> {
        // Not `.skipsHiddenFiles`: the temp files are dotfiles and must not be left behind.
        try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func record(_ sampleID: String = "solo.png", status: SampleStatus = .written) -> ResponseRecord {
        ResponseRecord(
            sampleID: sampleID,
            status: status,
            skill: "diffusion-training-captioner",
            profile: "h3-still",
            captioner: ModelNames(requested: "cap-1", served: "cap-1"),
            critic: nil,
            attempts: 1,
            requests: 1,
            caption: Caption(caption: "x")
        )
    }

    // MARK: - Path helpers

    @Test("suffix and stem follow Python's Path rules")
    func suffixAndStem() {
        #expect(Sources.suffix(of: "a.png") == ".png")
        #expect(Sources.suffix(of: "a.b.PNG") == ".PNG")
        #expect(Sources.suffix(of: ".hidden") == "")
        #expect(Sources.suffix(of: "trailing.") == "")
        #expect(Sources.suffix(of: "none") == "")
        #expect(Sources.stem(of: "a.png") == "a")
        #expect(Sources.stem(of: "a.b.png") == "a.b")
        #expect(Sources.stem(of: ".hidden") == ".hidden")
        #expect(Sources.stem(of: "trailing.") == "trailing.")
        #expect(Sources.stem(of: "none") == "none")
        #expect(Sources.stem(of: "héllo.webp") == "héllo")
    }

    // MARK: - LocalFolderSource

    @Test("lists image files sorted by name and yields their bytes")
    func listsAndYields() async throws {
        let bPNG = Fixtures.syntheticPNG(seed: 1)
        let aJPG = Data("not really a jpeg".utf8)
        let cWEBP = Data([0x52, 0x49, 0x46, 0x46])
        let directory = try folder([
            "b.png": bPNG,
            "a.jpg": aJPG,
            "notes.txt": Data("x".utf8),
            "c.webp": cWEBP,
        ])
        let source = try LocalFolderSource(directory: directory)

        #expect(source.name == "folder")
        #expect(try await source.sampleIDs() == ["a.jpg", "b.png", "c.webp"])
        #expect(try await source.count() == 3)
        #expect(source.files.map(\.lastPathComponent) == ["a.jpg", "b.png", "c.webp"])

        let samples = try await collect(source)
        #expect(samples.map(\.sampleID) == ["a.jpg", "b.png", "c.webp"])
        #expect(samples.map(\.suffix) == [".jpg", ".png", ".webp"])
        #expect(samples.map(\.data) == [aJPG, bPNG, cWEBP])
    }

    @Test("sorts by byte order, keeps the suffix case, ignores directories and other suffixes")
    func sortingAndFiltering() async throws {
        let directory = try folder(
            [
                "b.png": Data([1]),
                "a.jpg": Data([2]),
                "D.PNG": Data([3]),
                "é.jpeg": Data([4]),
                "_z.webp": Data([5]),
                "noext": Data([6]),
                "trailing.": Data([7]),
                ".png": Data([8]),
                "archive.tar.gz": Data([9]),
            ],
            directories: ["dir.png"]
        )
        let source = try LocalFolderSource(directory: directory)
        // Uppercase, then underscore, then lowercase, then non-ASCII: UTF-8 byte order, as Python sorts.
        #expect(try await source.sampleIDs() == ["D.PNG", "_z.webp", "a.jpg", "b.png", "é.jpeg"])
        let samples = try await collect(source)
        #expect(samples.map(\.suffix) == [".PNG", ".webp", ".jpg", ".png", ".jpeg"])
    }

    @Test("an empty folder is a valid, empty source")
    func emptyFolder() async throws {
        let source = try LocalFolderSource(directory: folder([:]))
        #expect(try await source.count() == 0)
        #expect(try await collect(source).isEmpty)
    }

    @Test("colliding stems are refused")
    func stemCollision() throws {
        let directory = try folder(["a.png": Data([1]), "a.jpg": Data([2])])
        #expect(throws: ConfigurationError("image stems collide; sidecar captions would be ambiguous")) {
            try LocalFolderSource(directory: directory)
        }
    }

    @Test("a missing directory is refused with its path")
    func missingDirectory() throws {
        let missing = try Fixtures.tempDirectory().appendingPathComponent("nope")
        #expect(throws: ConfigurationError("input directory does not exist: \(missing.path)")) {
            try LocalFolderSource(directory: missing)
        }
    }

    @Test("a file where a directory was expected is refused")
    func fileInsteadOfDirectory() throws {
        let directory = try folder(["x.png": Data([1])])
        let file = directory.appendingPathComponent("x.png")
        #expect(throws: ConfigurationError.self) {
            try LocalFolderSource(directory: file)
        }
    }

    @Test("samples are read lazily, and a vanished file ends the stream with an error")
    func lazyReads() async throws {
        let directory = try folder(["a.jpg": Data([1]), "b.png": Data([2]), "c.webp": Data([3])])
        let source = try LocalFolderSource(directory: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.png"))

        var seen: [String] = []
        var failed = false
        do {
            for try await sample in source.samples() {
                seen.append(sample.sampleID)
            }
        } catch {
            failed = true
        }
        #expect(seen == ["a.jpg"])
        #expect(failed)
        // The listing taken at init is unchanged; only the read fails.
        #expect(try await source.sampleIDs() == ["a.jpg", "b.png", "c.webp"])
    }

    @Test("samples(only:) never reads the files it was told to skip")
    func onlyHintSkipsReads() async throws {
        let directory = try folder(["a.jpg": Data([1]), "b.png": Data([2]), "c.webp": Data([3])])
        let source = try LocalFolderSource(directory: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.png"))

        var seen: [Sample] = []
        for try await sample in source.samples(only: ["c.webp", "a.jpg", "zzz.png"]) {
            seen.append(sample)
        }
        #expect(seen == [
            Sample(sampleID: "a.jpg", data: Data([1]), suffix: ".jpg"),
            Sample(sampleID: "c.webp", data: Data([3]), suffix: ".webp"),
        ], "b.png is gone but was never touched; order is the folder's")

        var unhinted: [String] = []
        await #expect(throws: (any Error).self, "nil means every file, and b.png's read now fails") {
            for try await sample in source.samples(only: nil) {
                unhinted.append(sample.sampleID)
            }
        }
        #expect(unhinted == ["a.jpg"])
    }

    @Test("HubFolderSource.samples(only:) downloads only the files it was told to keep")
    func hubOnlyHintSkipsDownloads() async throws {
        let transport = StubTransport { request in
            HTTPResponse(status: 200, body: Data("image:\(request.url?.lastPathComponent ?? "")".utf8))
        }
        let files = ["a.png", "b.jpg", "c.webp"].map { HubFile(path: $0, size: 1, oid: "blob-\($0)", isLFS: false) }
        let source = try HubFolderSource(
            client: HubClient(token: nil, transport: transport),
            repo: RepoID("ns/name"),
            revision: "main",
            captionColumn: "caption",
            files: files,
            rows: []
        )

        var seen: [Sample] = []
        for try await sample in source.samples(only: ["c.webp", "a.png", "zzz.png"]) {
            seen.append(sample)
        }
        #expect(seen == [
            Sample(sampleID: "a.png", data: Data("image:a.png".utf8), suffix: ".png"),
            Sample(sampleID: "c.webp", data: Data("image:c.webp".utf8), suffix: ".webp"),
        ])
        let downloaded = await transport.requests.compactMap { $0.url?.lastPathComponent }
        #expect(downloaded == ["a.png", "c.webp"], "b.jpg is never requested")
    }

    @Test("each samples() call is an independent pass over the folder")
    func repeatedPasses() async throws {
        let directory = try folder(["a.jpg": Data([1]), "b.png": Data([2])])
        let source = try LocalFolderSource(directory: directory)
        let first = try await collect(source).map(\.sampleID)
        let second = try await collect(source).map(\.sampleID)
        #expect(first == ["a.jpg", "b.png"])
        #expect(second == first)
    }

    // MARK: - AtomicFile

    @Test("AtomicFile creates parents, overwrites, and leaves no temp file")
    func atomicFile() throws {
        let root = try Fixtures.tempDirectory()
        let target = root.appendingPathComponent("deep/er/file.txt")
        try AtomicFile.write(text: "one", to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "one")
        try AtomicFile.write(Data("two ✓".utf8), to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "two ✓")
        #expect(try entries(of: target.deletingLastPathComponent()) == ["file.txt"])
    }

    @Test("AtomicFile fails cleanly when the target cannot be written")
    func atomicFileFailure() throws {
        let root = try Fixtures.tempDirectory()
        let blocker = root.appendingPathComponent("taken")
        try Data("file".utf8).write(to: blocker)
        // The parent "directory" is a regular file: createDirectory fails before any temp file exists.
        #expect(throws: (any Error).self) {
            try AtomicFile.write(text: "x", to: blocker.appendingPathComponent("child.txt"))
        }
        #expect(try entries(of: root) == ["taken"])
        #expect(try String(contentsOf: blocker, encoding: .utf8) == "file")
    }

    // MARK: - SidecarSink

    @Test("init creates the output directory and finalize reports it")
    func createsDirectory() async throws {
        let out = try Fixtures.tempDirectory().appendingPathComponent("out/nested")
        let sink = try SidecarSink(directory: out)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: out.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(sink.name == "sidecar")
        #expect(try await sink.finalize() == ["directory": .string(sink.directory.path)])
        #expect(sink.directory.path == out.standardizedFileURL.path)
        // Creating it again is fine (mkdir exist_ok).
        _ = try SidecarSink(directory: out)
    }

    @Test("init refuses a path that is an existing file")
    func refusesFile() throws {
        let root = try Fixtures.tempDirectory()
        let file = root.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        #expect(throws: ConfigurationError.self) {
            try SidecarSink(directory: file)
        }
    }

    @Test("sidecar paths use the sample's stem")
    func sidecarPaths() throws {
        let sink = try SidecarSink(directory: Fixtures.tempDirectory())
        #expect(sink.captionURL(for: "solo.png").lastPathComponent == "solo.txt")
        #expect(sink.recordURL(for: "solo.png").lastPathComponent == "solo.json")
        #expect(sink.captionURL(for: "a.b.JPG").lastPathComponent == "a.b.txt")
        #expect(sink.recordURL(for: "noext").lastPathComponent == "noext.json")
        #expect(sink.captionURL(for: "sub/dir/x.webp").lastPathComponent == "x.txt")
        #expect(sink.captionURL(for: "solo.png").deletingLastPathComponent().path == sink.directory.path)
    }

    @Test("write stores the caption and the record in Python's layout; record() round-trips")
    func writeAndReadBack() async throws {
        let out = try Fixtures.tempDirectory()
        let sink = try SidecarSink(directory: out)
        let record = record()

        #expect(try await sink.exists("solo.png") == false)
        #expect(try await sink.record("solo.png") == nil)

        try await sink.write("solo.png", caption: "x", record: record)

        #expect(try await sink.exists("solo.png"))
        let captionText = try String(contentsOf: out.appendingPathComponent("solo.txt"), encoding: .utf8)
        #expect(captionText == "x")
        let recordText = try String(contentsOf: out.appendingPathComponent("solo.json"), encoding: .utf8)
        #expect(recordText == record.jsonValue.pythonDumps(indent: 1))
        // What `json.dumps(record, ensure_ascii=False, indent=1)` prints for this record.
        let python = """
        {
         "sample_id": "solo.png",
         "status": "written",
         "source": "model",
         "skill": "diffusion-training-captioner",
         "profile": "h3-still",
         "captioner": {
          "requested": "cap-1",
          "served": "cap-1"
         },
         "critic": null,
         "attempts": 1,
         "requests": 1,
         "caption": {
          "caption": "x",
          "usable": true,
          "note": null
         },
         "critique": null
        }
        """
        #expect(recordText == python)
        #expect(try await sink.record("solo.png") == record)
        #expect(try entries(of: out) == ["solo.txt", "solo.json"])
    }

    @Test("write with no caption stores only the record")
    func writeWithoutCaption() async throws {
        let out = try Fixtures.tempDirectory()
        let sink = try SidecarSink(directory: out)
        let record = ResponseRecord(
            sampleID: "solo.png",
            status: .unusable,
            skill: "s",
            profile: "p",
            captioner: ModelNames(requested: "cap-1", served: "cap-1"),
            critic: nil,
            attempts: 1,
            requests: 1,
            caption: Caption(caption: "", usable: false, note: "face too small")
        )
        try await sink.write("solo.png", caption: nil, record: record)
        #expect(try await sink.exists("solo.png") == false)
        #expect(try await sink.record("solo.png") == record)
        #expect(try entries(of: out) == ["solo.json"])
    }

    @Test("write replaces earlier sidecars atomically and leaves no temp files")
    func overwrite() async throws {
        let out = try Fixtures.tempDirectory()
        let sink = try SidecarSink(directory: out)
        try await sink.write("pair.png", caption: "first", record: record("pair.png"))
        try await sink.write("pair.png", caption: "second", record: record("pair.png", status: .rejected))
        #expect(try String(contentsOf: sink.captionURL(for: "pair.png"), encoding: .utf8) == "second")
        #expect(try await sink.record("pair.png")?.status == .rejected)
        #expect(try entries(of: out) == ["pair.txt", "pair.json"])
    }

    @Test("record() is nil for garbage JSON or a non-object, and reads any object as a record")
    func recordEdgeCases() async throws {
        let out = try Fixtures.tempDirectory()
        let sink = try SidecarSink(directory: out)

        try Data("{not json".utf8).write(to: sink.recordURL(for: "garbage.png"))
        #expect(try await sink.record("garbage.png") == nil)

        try Data("[1, 2]".utf8).write(to: sink.recordURL(for: "list.png"))
        #expect(try await sink.record("list.png") == nil)

        // No sample_id: the sink knows which sample it asked for, as json.loads needs no key at all.
        try Data(#"{"status": "written"}"#.utf8).write(to: sink.recordURL(for: "noid.png"))
        let noID = try await sink.record("noid.png")
        #expect(noID?.sampleID == "noid.png" && noID?.isHumanFinal == false)

        // A hand-edited human record with an invented status and a quoted number still loads.
        try Data(#"{"source": "human", "status": "approved", "attempts": "1"}"#.utf8)
            .write(to: sink.recordURL(for: "edited.png"))
        let edited = try await sink.record("edited.png")
        #expect(edited?.isHumanFinal == true)
        #expect(edited?.sampleID == "edited.png" && edited?.status == .written && edited?.attempts == 0)

        // A hand-edited record (single line, minimal keys) still loads, as in the Python runner test.
        try Data(#"{"sample_id": "pair.png", "source": "human"}"#.utf8).write(to: sink.recordURL(for: "pair.png"))
        let human = try await sink.record("pair.png")
        #expect(human?.isHumanFinal == true)
        #expect(human?.status == .written)
        #expect(try await sink.exists("pair.png") == false)
    }

    @Test("a record with extra keys and a critic survives the sidecar byte for byte")
    func extraKeysRoundTrip() async throws {
        let out = try Fixtures.tempDirectory()
        let sink = try SidecarSink(directory: out)
        var record = ResponseRecord(
            sampleID: "pair.png",
            status: .written,
            skill: "diffusion-training-captioner",
            profile: "h3-still",
            captioner: ModelNames(requested: "cap-1", served: "cap-1"),
            critic: ModelNames(requested: "crit-1", served: "crit-1"),
            attempts: 2,
            requests: 3,
            caption: Caption(caption: Fixtures.h3("NORA7 and IVAN9.")),
            critique: Critique(approved: true, notes: ["looks right"])
        )
        record.extra = ["reviewer": .string("me"), "tags": .array([.string("a"), .string("b")])]
        try await sink.write("pair.png", caption: record.caption?.caption, record: record)

        let text = try String(contentsOf: sink.recordURL(for: "pair.png"), encoding: .utf8)
        #expect(text.hasSuffix("\n \"reviewer\": \"me\",\n \"tags\": [\n  \"a\",\n  \"b\"\n ]\n}"))
        let read = try await sink.record("pair.png")
        #expect(read == record)
        #expect(read?.jsonValue.pythonDumps(indent: 1) == text)
        #expect(try String(contentsOf: sink.captionURL(for: "pair.png"), encoding: .utf8) == record.caption?.caption)
    }

    @Test("the fixture folder flows through source and sink")
    func fixtureFolder() async throws {
        let images = try Fixtures.imagesFolder()
        let source = try LocalFolderSource(directory: images)
        #expect(try await source.sampleIDs() == ["pair.png", "solo.png", "unmapped.png"])
        let out = images.deletingLastPathComponent().appendingPathComponent("out")
        let sink = try SidecarSink(directory: out)
        let seeds = ["solo.png": 1, "pair.png": 2, "unmapped.png": 3]
        for try await sample in source.samples() {
            let seed = try #require(seeds[sample.sampleID])
            #expect(sample.data == Fixtures.syntheticPNG(seed: seed))
            try await sink.write(
                sample.sampleID,
                caption: "caption for \(sample.sampleID)",
                record: record(sample.sampleID)
            )
        }
        let expected: Set = ["pair.txt", "pair.json", "solo.txt", "solo.json", "unmapped.txt", "unmapped.json"]
        #expect(try entries(of: out) == expected)
        #expect(try await sink.finalize()["directory"]?.stringValue == sink.directory.path)
    }
}
