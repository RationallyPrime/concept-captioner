import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private struct PublishedDatasetTransport: HTTPTransport {
    let files: [String: Data]

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        if path.contains("/tree/main") {
            let tree = files.sorted { $0.key < $1.key }.map { path, data in
                JSONValue.object([
                    "type": .string("file"),
                    "path": .string(path),
                    "size": .int(data.count),
                    "oid": .string("test-oid"),
                ])
            }
            return HTTPResponse(status: 200, body: JSONValue.array(tree).pythonDumpsData())
        }
        let file = path.components(separatedBy: "/resolve/main/").last ?? ""
        guard let data = files[file] else { return HTTPResponse(status: 404) }
        return HTTPResponse(status: 200, body: data)
    }
}

@Suite("published imagefolder contract")
struct ProjectPublisherTests {
    @Test func publishedDatasetReplaysThroughHubAndRunner() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let localSource = try LocalFolderSource(directory: project.imagesDirectory)
        let localSink = try SidecarSink(directory: project.imagesDirectory)
        let endpoint = ResolvedEndpoint(client: DemoModelClient())
        _ = try await Runner(job: project.job, captioner: endpoint).run(source: localSource, sink: localSink)
        try await project.saveCaption(id: "garden.png", text: "NORA7 final caption.", final: true)
        let operations = try await ProjectPublisher.operations(for: project)
        var files: [String: Data] = [:]
        for operation in operations {
            switch operation {
            case let .add(path, data): files[path] = data
            case let .addFile(path, url): files[path] = try Data(contentsOf: url)
            case .delete: Issue.record("Unexpected delete operation")
            }
        }
        let hub = HubClient(token: nil, transport: PublishedDatasetTransport(files: files))
        let source = try await HubFolderSource.open(client: hub, repo: RepoID("demo/project"))
        #expect(try await source.sampleIDs() == localSource.files.map(\.lastPathComponent))
        #expect(try await source.count() == 3)
        let yaml = try #require(files["concept-captioner/job.yaml"])
        let job = try Job.load(yaml: #require(String(data: yaml, encoding: .utf8)))
        for id in try await source.sampleIDs() {
            #expect(job.mapping(for: id) != nil)
        }
        for row in source.rows {
            #expect(row.record?.sampleID == row.fileName)
        }
        let sink = try HubFolderSink(client: hub, origin: .hub(source), push: false)
        let replay = try await Runner(job: job, captioner: endpoint, overwrite: true).run(source: source, sink: sink)
        #expect(replay.outcomes.count(where: { $0.status == .written }) == 2)
        #expect(replay.outcomes.first { $0.sampleID == "garden.png" }?.notes == ["human-final"])
        #expect(!files.keys.contains { $0.hasPrefix("references/") })

        // A caller can retain this exact synthetic snapshot to exercise the Python pod reader too.
        if let path = ProcessInfo.processInfo.environment["CONCEPTSTUDIO_CONTRACT_FIXTURE"] {
            let snapshot = URL(fileURLWithPath: path, isDirectory: true)
            for (name, data) in files {
                let target = snapshot.appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: target)
            }
        }
    }
}
