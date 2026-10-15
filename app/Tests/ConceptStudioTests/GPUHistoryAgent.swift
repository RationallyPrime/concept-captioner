import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

/// No account or GPU calls: records the native agent contract and supplies synthetic file bytes.
actor HistoryAgent: PodAgent {
    struct Start { let service: String; let gpus: [Int]; let params: JSONObject }
    private(set) var starts: [Start] = []
    private(set) var listedRunIDs: [String] = []
    private(set) var downloadedRunIDs: [String] = []
    var files: [RunFile] = []
    var bodies: [String: Data] = [:]
    var logBodies: [String: Data] = [:]
    var damageDownloads = false
    var loseStartReply = false
    private var pauseProgress = false
    private var progressWaiter: CheckedContinuation<Void, Never>?
    private var progressRelease: CheckedContinuation<Void, Never>?

    func pauseNextProgressRead() {
        pauseProgress = true
    }

    func waitForPausedProgressRead() async {
        if progressRelease != nil { return }
        await withCheckedContinuation { progressWaiter = $0 }
    }

    func releaseProgressRead() {
        progressRelease?.resume()
        progressRelease = nil
    }

    func loseStartAcknowledgements() {
        loseStartReply = true
    }

    func plan() -> TrainingPlan {
        TrainingPlan(mode: "concurrent", caption: .init(gpus: [0]), train: .init(gpus: [1]))
    }

    func services() -> [AgentService] {
        starts.map { start in
            AgentService(
                name: start.service,
                state: ["pull-dataset", "push-lora"].contains(start.service) ? "exited" : "running",
                groupAlive: false,
                runID: start.params["run_id"]?.stringValue
            )
        }
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) throws {
        starts.append(Start(service: service, gpus: gpus, params: params))
        if loseStartReply, service.hasPrefix("trainer-") || service.hasPrefix("generate-") {
            throw StudioError.message("Synthetic lost start acknowledgement")
        }
    }

    func stop(_ service: String) {}
    func runLog(runID: String) -> String {
        "Synthetic offline log"
    }

    func latest(runID: String) async -> TrainingPoint? {
        if pauseProgress {
            pauseProgress = false
            await withCheckedContinuation { continuation in
                progressRelease = continuation
                progressWaiter?.resume()
                progressWaiter = nil
            }
        }
        return nil
    }

    func history(runID: String) -> [TrainingPoint] {
        []
    }

    func runFiles(runID: String) -> [RunFile] {
        listedRunIDs.append(runID)
        return files
    }

    func runConfiguration(runID: String) -> AgentRunConfiguration {
        AgentRunConfiguration(config: [:], dataset: ["revision": .string("resolved-revision")])
    }

    func serve(_ bodies: [String: Data], damaged: Bool = false) {
        self.bodies = bodies
        damageDownloads = damaged
        files = bodies.map { RunFile(path: $0.key, size: $0.value.count, sha256: sha256($0.value)) }
    }

    func download(runID: String, path: String, to destination: URL) throws {
        downloadedRunIDs.append(runID)
        try (damageDownloads ? Data("damaged".utf8) : bodies[path] ?? Data()).write(to: destination)
    }

    func serveLogs(_ bodies: [String: Data]) {
        logBodies = bodies
    }

    func runLogFiles(runID: String) -> [RunFile] {
        logBodies.map { RunFile(path: $0.key, size: $0.value.count, sha256: sha256($0.value)) }
    }

    func downloadLogFile(runID: String, path: String, to destination: URL) throws {
        try (logBodies[path] ?? Data()).write(to: destination)
    }
}
