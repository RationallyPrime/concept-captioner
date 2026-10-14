import ConceptCore
import CryptoKit
import Foundation

struct TrainingPlan: Decodable {
    struct Assignment: Decodable { let gpus: [Int] }
    let mode: String
    let caption: Assignment?
    let train: Assignment?
}

struct AgentService: Decodable {
    let name: String
    let state: String
    let groupAlive: Bool?
    var runID: String?
    enum CodingKeys: String, CodingKey {
        case name, state
        case groupAlive = "group_alive"
        case runID = "run_id"
    }

    var active: Bool {
        state == "running" || state == "stuck" || groupAlive == true
    }
}

struct TrainingPoint: Identifiable, Codable, Equatable {
    var id: Int {
        step
    }

    let step: Int
    let loss: Double
}

/// One file of a finished run, as the agent's `GET /runs/{id}/files` lists it (POD-SPEC 2.10):
/// `{"path", "size", "sha256", "modified_at"}`, with `modified_at` an ISO 8601 UTC timestamp.
struct RunFile: Codable, Equatable {
    /// Relative to the run's output directory (`/workspace/runs/<id>/output/`), `/`-separated.
    let path: String
    let size: Int
    let sha256: String
    var modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case path, size, sha256
        case modifiedAt = "modified_at"
    }

    init(path: String, size: Int, sha256: String, modifiedAt: Date? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        size = try values.decode(Int.self, forKey: .size)
        sha256 = try values.decode(String.self, forKey: .sha256)
        let stamp = try values.decodeIfPresent(String.self, forKey: .modifiedAt)
        modifiedAt = stamp.flatMap { try? Date($0, strategy: .iso8601) }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(size, forKey: .size)
        try values.encode(sha256, forKey: .sha256)
        try values.encodeIfPresent(modifiedAt?.formatted(.iso8601), forKey: .modifiedAt)
    }
}

struct AgentStorageUsage: Decodable, Equatable {
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64
    let datasetsBytes: Int64
    let reclaimableDatasetBytes: Int64

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes", usedBytes = "used_bytes", freeBytes = "free_bytes"
        case datasetsBytes = "datasets_bytes", reclaimableDatasetBytes = "reclaimable_dataset_bytes"
    }
}

struct AgentRunConfiguration {
    let config: JSONObject
    let dataset: JSONObject
}

struct AgentGPU: Decodable {
    let index: Int
    let name: String
    let memoryTotalMiB: Int
    enum CodingKeys: String, CodingKey {
        case index, name
        case memoryTotalMiB = "memory_total_mib"
    }
}

protocol PodAgent: Sendable {
    func gpus() async throws -> [AgentGPU]
    func upload(name: String, fileName: String, from file: URL, size: Int64) async throws
    func plan() async throws -> TrainingPlan
    func services() async throws -> [AgentService]
    func start(_ service: String, gpus: [Int], params: JSONObject) async throws
    func stop(_ service: String) async throws
    /// The trainer log of a run, read from the volume (POD-SPEC 2.8), so it survives an agent restart.
    func runLog(runID: String) async throws -> String
    func latest(runID: String) async throws -> TrainingPoint?
    /// Every loss point TensorBoard holds for the run (through the agent's authenticated proxy).
    func history(runID: String) async throws -> [TrainingPoint]
    func runFiles(runID: String) async throws -> [RunFile]
    /// Streams one run file to `destination` without holding it in memory.
    func download(runID: String, path: String, to destination: URL) async throws
    func runConfiguration(runID: String) async throws -> AgentRunConfiguration
    func storageUsage() async throws -> AgentStorageUsage
}

/// Thrown by an agent that cannot report GPU memory, such as one running an older training image.
/// `GPUWorkspace.verifyGPUMemory` words it for the model being checked.
struct AgentCannotReportGPUMemory: Error, LocalizedError {
    var errorDescription: String? {
        "This agent cannot report GPU memory. Update its training image."
    }
}

extension PodAgent {
    func gpus() async throws -> [AgentGPU] {
        throw AgentCannotReportGPUMemory()
    }

    func upload(name: String, fileName: String, from file: URL, size: Int64) async throws {
        throw StudioError.message("This computer does not support direct training uploads. Update its training image.")
    }

    func storageUsage() async throws -> AgentStorageUsage {
        throw StudioError.message("This agent does not expose workspace storage usage.")
    }

    func runConfiguration(runID: String) async throws -> AgentRunConfiguration {
        throw StudioError.message("This agent does not expose saved run configuration.")
    }
}

/// Streams a response body to disk. The seam exists so tests never touch the network.
protocol FileDownloading: Sendable {
    /// Writes the body to `destination` on a 2xx reply and returns the HTTP status either way.
    func download(_ request: URLRequest, to destination: URL) async throws -> Int
}

struct URLSessionDownloader: FileDownloading {
    func download(_ request: URLRequest, to destination: URL) async throws -> Int {
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: NoRedirects())
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200 ..< 300).contains(status) {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return status
    }

    /// The agent never redirects; refusing keeps its bearer token on its own host.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _: URLSession, task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}

struct PodAgentClient: PodAgent {
    let baseURL: URL
    let token: String
    let transport: any HTTPTransport
    var downloader: any FileDownloading = URLSessionDownloader()
    var uploader: any FileUploading = URLSessionUploader()

    func gpus() async throws -> [AgentGPU] {
        struct Result: Decodable { let gpus: [AgentGPU] }
        return try await JSONDecoder().decode(Result.self, from: call("gpus")).gpus
    }

    func plan() async throws -> TrainingPlan {
        try await JSONDecoder().decode(TrainingPlan.self, from: call(
            "plan", method: "POST", body: ["caption": .bool(true), "train": .bool(true)]
        ))
    }

    func services() async throws -> [AgentService] {
        struct Result: Decodable { let services: [AgentService] }
        return try await JSONDecoder().decode(Result.self, from: call("services")).services
    }

    func storageUsage() async throws -> AgentStorageUsage {
        try await JSONDecoder().decode(AgentStorageUsage.self, from: call("storage"))
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) async throws {
        _ = try await call(
            "services/\(service)/start",
            method: "POST",
            body: ["gpus": .array(gpus.map(JSONValue.int)), "params": .object(params)]
        )
    }

    func stop(_ service: String) async throws {
        _ = try await call("services/\(service)/stop", method: "POST", body: ["timeout_s": .int(30)])
    }

    func runLog(runID: String) async throws -> String {
        let json = try await JSONValue(parsing: call("runs/\(runID)/log", query: [
            URLQueryItem(name: "tail", value: "200"),
        ]))
        let lines = json.objectValue?["lines"]?.arrayValue ?? []
        return lines.compactMap(\.stringValue).joined(separator: "\n")
    }

    func latest(runID: String) async throws -> TrainingPoint? {
        let json = try await JSONValue(parsing: call("runs/\(runID)/events"))
        let scalars = json.objectValue?["scalars"]?.objectValue
        let loss = scalars?["loss"]?.objectValue ?? scalars?["scraped/loss"]?.objectValue
        guard let step = loss?["step"]?.intValue, let value = loss?["value"]?.doubleValue else { return nil }
        return TrainingPoint(step: step, loss: value)
    }

    func history(runID: String) async throws -> [TrainingPoint] {
        // TensorBoard names each event directory under /workspace/runs as a run: `<id>/tensorboard`,
        // plus `<id>/tensorboard/<name>_<timestamp>` for ai-toolkit's native files.
        let tags = try await JSONValue(parsing: call("tensorboard/data/plugin/scalars/tags")).objectValue ?? [:]
        let runs = tags.keys.filter { $0.hasPrefix(runID + "/") }.sorted()
        for tag in ["loss", "scraped/loss"] {
            guard let run = runs.first(where: { tags[$0]?.objectValue?[tag] != nil }) else { continue }
            let rows = try await JSONValue(parsing: call("tensorboard/data/plugin/scalars/scalars", query: [
                URLQueryItem(name: "run", value: run), URLQueryItem(name: "tag", value: tag),
            ])).arrayValue ?? []
            // Each row is [wall_time, step, value].
            return rows.compactMap { row in
                guard let values = row.arrayValue, values.count == 3, let step = values[1].intValue,
                      let loss = values[2].doubleValue ?? values[2].intValue.map(Double.init) else { return nil }
                return TrainingPoint(step: step, loss: loss)
            }
        }
        return []
    }

    func runFiles(runID: String) async throws -> [RunFile] {
        struct Result: Decodable { let files: [RunFile] }
        return try await JSONDecoder().decode(Result.self, from: call("runs/\(runID)/files")).files
    }

    func runConfiguration(runID: String) async throws -> AgentRunConfiguration {
        let info = try await JSONValue(parsing: call("runs/\(runID)/config")).objectValue
        return AgentRunConfiguration(
            config: info?["config"]?.objectValue ?? [:],
            dataset: info?["dataset"]?.objectValue ?? [:]
        )
    }

    func download(runID: String, path: String, to destination: URL) async throws {
        var url = baseURL.appendingPathComponent("runs/\(runID)/files")
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let status = try await downloader.download(request, to: destination)
        guard (200 ..< 300).contains(status) else { throw Self.failure(status) }
    }

    private func call(
        _ path: String, method: String = "GET", body: JSONObject? = nil, query: [URLQueryItem] = []
    ) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONValue.object(body).pythonDumpsData()
        }
        let response = try await transport.send(request)
        guard (200 ..< 300).contains(response.status) else { throw Self.failure(response.status) }
        return response.body
    }

    private static func failure(_ status: Int) -> StudioError {
        if [502, 503, 504].contains(status) || (520 ... 526).contains(status) {
            return StudioError.message(
                "The computer is starting or unreachable. Refresh in a moment; you can still stop it."
            )
        }
        return StudioError.message(
            "The computer could not complete this action (\(status)). Check its status and logs."
        )
    }
}

actor DemoPodAgent: PodAgent {
    func gpus() -> [AgentGPU] {
        (0 ..< count).map { AgentGPU(index: $0, name: "Simulated 96 GB GPU", memoryTotalMiB: 97887) }
    }

    let count: Int
    private var states: [String: String] = [:]
    private var runIDs: [String: String] = [:]
    private var ticks = 0
    private let lora = Data("demo LoRA weights".utf8)

    init(count: Int) {
        self.count = count
    }

    func storageUsage() -> AgentStorageUsage {
        AgentStorageUsage(
            totalBytes: 100_000_000_000,
            usedBytes: 25_000_000_000,
            freeBytes: 75_000_000_000,
            datasetsBytes: 2_000_000_000,
            reclaimableDatasetBytes: 0
        )
    }

    func plan() -> TrainingPlan {
        TrainingPlan(
            mode: count == 1 ? "sequential" : "concurrent",
            caption: .init(gpus: [0]),
            train: .init(gpus: count == 1 ? [0] : Array(1 ..< count))
        )
    }

    func services() -> [AgentService] {
        states.map { AgentService(name: $0.key, state: $0.value, groupAlive: false, runID: runIDs[$0.key]) }
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) {
        states[service] = ["pull-dataset", "push-lora", "cleanup-datasets"].contains(service) ? "exited" : "running"
        runIDs[service] = params["run_id"]?.stringValue
        if service.hasPrefix("trainer-") { ticks = 0 }
    }

    func stop(_ service: String) {
        states[service] = "stopped"
    }

    func runLog(runID: String) -> String {
        let trainer = states.first { $0.key.hasPrefix("trainer-") }
        return "Demo · \(runID): \(trainer?.value ?? "idle")\nNo remote computer is being billed."
    }

    func latest(runID: String) -> TrainingPoint? {
        guard states.contains(where: { $0.key.hasPrefix("trainer-") && $0.value == "running" }) else { return nil }
        ticks += 1
        if ticks >= 8 {
            for name in states.keys where name.hasPrefix("trainer-") {
                states[name] = "exited"
            }
        }
        return TrainingPoint(step: ticks * 25, loss: 1 / Double(ticks + 1))
    }

    func history(runID: String) -> [TrainingPoint] {
        (0 ..< ticks).map { TrainingPoint(step: ($0 + 1) * 25, loss: 1 / Double($0 + 2)) }
    }

    func runFiles(runID: String) -> [RunFile] {
        let digest = SHA256.hash(data: lora).map { String(format: "%02x", $0) }.joined()
        return [RunFile(path: "\(runID)/\(runID).safetensors", size: lora.count, sha256: digest, modifiedAt: Date())]
    }

    func download(runID: String, path: String, to destination: URL) throws {
        try lora.write(to: destination)
    }
}
