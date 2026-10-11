import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Saved run identifiers and local output confinement")
struct GPURunIDTests {
    @MainActor @Test(arguments: [
        "../escape",
        "/absolute",
        "",
        "line\n",
        ".hidden",
        "éclair",
        String(repeating: "a", count: 65),
    ])
    func invalidRunIDsCannotCreateResultsFolders(_ value: String) throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(!RunArtifacts.validRunID(value))
        #expect(throws: StudioError.self) { try workspace.resultsFolder(for: value) }
    }

    @MainActor @Test
    func symlinkedResultsAndDownloadParentsRefused() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = FileManager.default
        let project = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: project); try? manager.removeItem(at: outside) }
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let workspace = makeWorkspace(GPUTransport(), preferences)
        workspace.projectFolder = project
        let results = project.appendingPathComponent("results")
        try manager.createSymbolicLink(at: results, withDestinationURL: outside)
        #expect(throws: StudioError.self) { try workspace.resultsFolder(for: "valid-run") }
        try manager.removeItem(at: results)
        let folder = try workspace.resultsFolder(for: "valid-run")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("nested"), withDestinationURL: outside)
        let agent = HistoryAgent()
        let bytes = Data("checkpoint".utf8)
        await agent.serve(["nested/model.safetensors": bytes])
        await #expect(throws: StudioError.self) {
            try await workspace.download(
                RunFile(path: "nested/model.safetensors", size: bytes.count, sha256: sha256(bytes)),
                runID: "valid-run", into: folder, agent: agent
            )
        }
        #expect(await agent.downloadedRunIDs.isEmpty)
        #expect(!manager.fileExists(atPath: outside.appendingPathComponent("model.safetensors").path))
    }

    @Test
    func restoredProjectAndPodRecordsDiscardInvalidRunIDsWithoutLosingPodControls() throws {
        let result = TrainingResult(
            runID: "../escape",
            outputRepo: "",
            destination: .download,
            volumeID: "storage",
            state: .pending
        )
        var record = ProjectTrainingRecord(results: [result])
        record.results.append(TrainingResult(
            runID: "valid-run",
            outputRepo: "",
            destination: .download,
            volumeID: "storage",
            state: .pending
        ))
        let restored = try JSONDecoder().decode(ProjectTrainingRecord.self, from: JSONEncoder().encode(record))
        #expect(restored.results.map(\.runID) == ["valid-run"])
        var pod = SavedPod(
            pod: RentedPod(id: "owned", status: "RUNNING", cost: 1, gpu: .init(count: 1)),
            started: Date(),
            hourlyRate: 1,
            budget: 10,
            trainer: "aitoolkit",
            runID: "../escape",
            outputRepo: "",
            volumeID: "storage"
        )
        pod.result = result
        let safe = try JSONDecoder().decode(SavedPod.self, from: JSONEncoder().encode(pod))
        #expect(safe.pod.id == "owned" && safe.budget == 10 && safe.volumeID == "storage")
        #expect(safe.runID.isEmpty && safe.result == nil)
    }

    @Test
    func restoredPathsCannotClaimSavedFilesOutsideThisProject() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        var record = ProjectTrainingRecord(results: [TrainingResult(
            runID: "valid-run", outputRepo: "", destination: .download, volumeID: "storage",
            state: .saved(folder: "/outside/private-files")
        )])
        record.comparisons = [GeneratedComparison(
            runID: "comparison", sourceRunID: "valid-run", checkpoint: "model.safetensors", trainer: "aitoolkit",
            volumeID: "storage", startedAt: Date(), state: .saved, folder: "/outside/private-files",
            paramsJSON: Data("{}".utf8)
        )]
        try record.save(to: project)
        let restored = ProjectTrainingRecord.load(from: project)
        #expect(restored.results.first?.state == .pending)
        #expect(restored.comparisons.first?.state == .pending)
        #expect(restored.comparisons.first?.folder == nil)
    }
}
