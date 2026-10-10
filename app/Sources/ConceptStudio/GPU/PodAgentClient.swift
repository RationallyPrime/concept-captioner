import ConceptCore
import Foundation

struct TrainingPlan: Decodable {
    struct Assignment: Decodable { let gpus: [Int] }
    let mode: String
    let caption: Assignment?
    let train: Assignment?

    var explanation: String {
        if mode == "sequential" {
            "One GPU: finish captioning, stop the caption model to free its memory, then train."
        } else {
            "Captioning uses GPU 0. Training uses the other GPUs, so you can keep improving captions while training."
        }
    }
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

struct TrainingPoint: Identifiable {
    var id: Int {
        step
    }

    let step: Int
    let loss: Double
}

protocol PodAgent: Sendable {
    func plan() async throws -> TrainingPlan
    func services() async throws -> [AgentService]
    func start(_ service: String, gpus: [Int], params: JSONObject) async throws
    func stop(_ service: String) async throws
    func logs(_ service: String) async throws -> String
    func latest(runID: String) async throws -> TrainingPoint?
}

struct PodAgentClient: PodAgent {
    let baseURL: URL
    let token: String
    let transport: any HTTPTransport

    func plan() async throws -> TrainingPlan {
        try await JSONDecoder().decode(TrainingPlan.self, from: call(
            "plan", method: "POST", body: ["caption": .bool(true), "train": .bool(true)]
        ))
    }

    func services() async throws -> [AgentService] {
        struct Result: Decodable { let services: [AgentService] }
        return try await JSONDecoder().decode(Result.self, from: call("services")).services
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

    func logs(_ service: String) async throws -> String {
        let json = try await JSONValue(parsing: call("services/\(service)/logs"))
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

    private func call(_ path: String, method: String = "GET", body: JSONObject? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONValue.object(body).pythonDumpsData()
        }
        let response = try await transport.send(request)
        guard (200 ..< 300).contains(response.status) else {
            if [502, 503, 504].contains(response.status) || (520 ... 526).contains(response.status) {
                throw StudioError
                    .message(
                        "The computer is starting or unreachable. Refresh in a moment; you can still stop it."
                    )
            }
            throw StudioError
                .message(
                    "The computer could not complete this action (\(response.status)). Check its status and logs."
                )
        }
        return response.body
    }
}

actor DemoPodAgent: PodAgent {
    let count: Int
    private var states: [String: String] = [:]
    private var ticks = 0

    init(count: Int) {
        self.count = count
    }

    func plan() -> TrainingPlan {
        TrainingPlan(
            mode: count == 1 ? "sequential" : "concurrent",
            caption: .init(gpus: [0]),
            train: .init(gpus: count == 1 ? [0] : Array(1 ..< count))
        )
    }

    func services() -> [AgentService] {
        states.map { AgentService(name: $0.key, state: $0.value, groupAlive: false) }
    }

    func start(_ service: String, gpus: [Int], params: JSONObject) {
        states[service] = ["pull-dataset", "push-lora"].contains(service) ? "exited" : "running"
        if service.hasPrefix("trainer-") { ticks = 0 }
    }

    func stop(_ service: String) {
        states[service] = "stopped"
    }

    func logs(_ service: String)
        -> String {
        "Demo · \(service): \(states[service] ?? "idle")\nNo remote computer is being billed."
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
}
