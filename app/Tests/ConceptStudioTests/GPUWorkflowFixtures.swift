// Fakes for the GPU workflow tests: a RunPod API and pod agent, a file downloader and a sleep
// assertion counter. Nothing here touches the network.

import ConceptCore
@testable import ConceptStudio
import CryptoKit
import Foundation
import Testing

actor GPUTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let body: Data

    init(_ json: String = "{}") {
        body = Data(json.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: 200, body: body)
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A fake RunPod API plus pod agent. `agentAvailable: false` makes the agent proxy answer 522.
actor UnreachableAgentTransport: HTTPTransport {
    private var stopped = false
    private var failedFirstStop: Bool
    private let agentAvailable: Bool
    private let inferenceReady: Bool
    private let gpuCount: Int
    private var services: [String: String] = [:]
    private var runIDs: [String: String] = [:]
    private var servedModel = "Qwen/Qwen3-VL-8B-Instruct"
    private var listedPods: [String] = []
    private var runFiles: [RunFile] = []
    private var filesFail = false
    private var listFails = false
    private var hubAccount: String?
    private var history: [(Int, Double)] = []
    private(set) var stopCalls = 0
    private(set) var stoppedPods: [String] = []
    private(set) var inferenceRequests: [URLRequest] = []
    private(set) var starts: [URLRequest] = []
    private(set) var agentRequests: [URLRequest] = []

    init(failFirstStop: Bool = false, agentAvailable: Bool = false, inferenceReady: Bool = false, gpuCount: Int = 1) {
        failedFirstStop = !failFirstStop
        self.agentAvailable = agentAvailable
        self.inferenceReady = inferenceReady
        self.gpuCount = gpuCount
    }

    func list(_ pods: [String]) {
        listedPods = pods
    }

    func files(_ files: [RunFile]) {
        runFiles = files
    }

    func failFiles(_ fail: Bool) {
        filesFail = fail
    }

    func failList(_ fail: Bool) {
        listFails = fail
    }

    /// The account `GET huggingface.co/api/whoami-v2` reports; nil answers 401.
    func signIn(_ account: String?) {
        hubAccount = account
    }

    func curve(_ points: [(Int, Double)]) {
        history = points
    }

    func finish(_ service: String, state: String) {
        services[service] = state
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        if url.host()?.contains("-8000.") == true {
            inferenceRequests.append(request)
            return HTTPResponse(
                status: inferenceReady ? 200 : 503,
                body: JSONValue.object(["data": .array([.object(["id": .string(servedModel)])])]).pythonDumpsData()
            )
        }
        if url.host() == "huggingface.co" {
            guard let hubAccount, request.value(forHTTPHeaderField: "Authorization") != nil else {
                return HTTPResponse(status: 401)
            }
            return HTTPResponse(status: 200, body: JSONValue.object(["name": .string(hubAccount)]).pythonDumpsData())
        }
        if url.host() != "api.runpod.io" {
            guard agentAvailable else { return HTTPResponse(status: 522) }
            agentRequests.append(request)
            return try HTTPResponse(
                status: 200,
                body: JSONValue.object(agentReply(request, url: url)).pythonDumpsData()
            )
        }
        if url.path().hasSuffix("action") {
            stopCalls += 1
            stoppedPods.append(url.deletingLastPathComponent().lastPathComponent)
            if !failedFirstStop {
                failedFirstStop = true
                return HTTPResponse(status: 503)
            }
            if url.deletingLastPathComponent().lastPathComponent == "test" { stopped = true }
        }
        if listFails, url.path().hasSuffix("/v2/pods"), request.httpMethod != "POST" {
            return HTTPResponse(status: 500)
        }
        return HTTPResponse(status: 200, body: Data(provider(request, url: url).utf8))
    }

    private func agentReply(_ request: URLRequest, url: URL) throws -> JSONObject {
        let path = url.path()
        if url.lastPathComponent == "start" {
            starts.append(request)
            let service = url.deletingLastPathComponent().lastPathComponent
            let params = try JSONValue(parsing: #require(request.httpBody)).objectValue?["params"]?.objectValue
            services[service] = ["pull-dataset", "push-lora"].contains(service) ? "exited" : "running"
            runIDs[service] = params?["run_id"]?.stringValue
            if service == "vllm" { servedModel = params?["model"]?.stringValue ?? servedModel }
        }
        if url.lastPathComponent == "plan" {
            return [
                "mode": .string(gpuCount == 1 ? "sequential" : "concurrent"),
                "caption": .object(["gpus": .array([.int(0)])]),
                "train": .object(["gpus": .array([.int(gpuCount == 1 ? 0 : 1)])]),
            ]
        }
        if path.hasSuffix("/files") {
            if filesFail { throw StudioError.message("listing failed") }
            // The agent's shape (pod/agent artifacts.py): paths relative to the run's output/.
            return try ["files": JSONValue(parsing: JSONEncoder().encode(runFiles))]
        }
        if path.hasSuffix("/log") { return ["lines": .array([.string("step 1 loss 0.5")])] }
        if path.hasSuffix("/events") { return ["scalars": .object([:])] }
        if path.hasSuffix("scalars/tags") {
            let run = runIDs.values.first ?? "previous-run"
            return ["\(run)/tensorboard": .object(["scraped/loss": .object([:])])]
        }
        if path.hasSuffix("scalars/scalars") {
            throw StudioError.message("answered by scalarsReply")
        }
        return ["services": .array(services.map { name, state in
            var service: JSONObject = ["name": .string(name), "state": .string(state)]
            if let run = runIDs[name] { service["run_id"] = .string(run) }
            return .object(service)
        })]
    }

    private func provider(_ request: URLRequest, url: URL) -> String {
        if url.path().contains("catalog/gpus") {
            return #"{"gpus":[{"id":"test","name":"Test GPU","memory":80,"secure":true,"#
                + #""price":{"secure":1},"maxCount":{"secure":4},"#
                + #""dataCenters":[{"id":"EU-IS-1","availability":"HIGH"}]}]}"#
        }
        if url.path().hasSuffix("network-volumes") {
            return #"{"networkVolumes":[{"id":"test","name":"Test","size":100,"dataCenter":"EU-IS-1"}]}"#
        }
        if url.path().hasSuffix("/v2/pods"), request.httpMethod != "POST" {
            return #"{"pods":["# + listedPods.joined(separator: ",")
                + #"],"pagination":{"nextCursor":null,"hasNextPage":false}}"#
        }
        return "{\"id\":\"test\",\"status\":\"\(stopped ? "EXITED" : "RUNNING")\",\"cost\":1,"
            + "\"gpu\":{\"count\":\(gpuCount)},\"name\":\"ConceptStudio-test\","
            + "\"mounts\":{\"network\":[{\"volumeId\":\"test\",\"path\":\"/workspace\"}]}}"
    }
}

/// The scalars route answers with a bare JSON array, which `agentReply` cannot return.
actor CurveTransport: HTTPTransport {
    let inner: UnreachableAgentTransport
    let rows: String

    init(_ inner: UnreachableAgentTransport, rows: String) {
        self.inner = inner
        self.rows = rows
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path().hasSuffix("scalars/scalars") == true {
            return HTTPResponse(status: 200, body: Data(rows.utf8))
        }
        return try await inner.send(request)
    }
}

actor FakeDownloader: FileDownloading {
    private var contents: [String: Data]
    private(set) var requests: [URLRequest] = []

    init(_ contents: [String: Data]) {
        self.contents = contents
    }

    /// File bodies by last path component.
    func serve(_ contents: [String: Data]) {
        self.contents = contents
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> Int {
        requests.append(request)
        guard let name = request.url?.lastPathComponent, let data = contents[name] else { return 404 }
        try data.write(to: destination)
        return 200
    }
}

@MainActor
final class SleepCounter {
    var begun = 0
    var ended = 0

    var assertion: SleepAssertion {
        SleepAssertion(begin: { self.begun += 1; return NSObject() }, end: { _ in self.ended += 1 })
    }
}

@MainActor
func makeWorkspace(
    _ transport: any HTTPTransport, _ preferences: UserDefaults,
    downloader: any FileDownloading = FakeDownloader([:]), sleep: SleepCounter = SleepCounter(),
    readAgentToken: @escaping (String) throws -> String? = { _ in nil },
    saveAgentToken: @escaping (String, String) throws -> Void = { _, _ in },
    deleteAgentToken: @escaping (String) throws -> Void = { _ in }
) -> GPUWorkspace {
    GPUWorkspace(
        demoMode: false, transport: transport, preferences: preferences, readAgentToken: readAgentToken,
        saveAgentToken: saveAgentToken, deleteAgentToken: deleteAgentToken, downloader: downloader,
        keepAwake: sleep.assertion
    )
}

func temporaryPreferences() throws -> (UserDefaults, String) {
    let suite = "GPUWorkflowTests." + UUID().uuidString
    return try (#require(UserDefaults(suiteName: suite)), suite)
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 300 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
}

func trainerParams(_ transport: UnreachableAgentTransport, _ trainer: String) async throws -> JSONObject {
    let start = try #require(await transport.starts
        .first { $0.url?.path() == "/services/trainer-\(trainer)/start" })
    let body = try #require(start.httpBody)
    return try #require(JSONValue(parsing: body).objectValue?["params"]?.objectValue)
}
