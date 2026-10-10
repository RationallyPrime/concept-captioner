import ConceptCore
import Foundation

struct GPUOffer: Identifiable, Decodable {
    struct Prices: Decodable { let secure: Double }
    struct Counts: Decodable { let secure: Int }
    struct Location: Decodable {
        let id: String
        let availability: String
    }

    let id: String
    let name: String
    let memory: Int
    let secure: Bool
    let price: Prices
    let maxCount: Counts
    let availability: String?
    var dataCenters: [Location]?

    func isAvailable(in dataCenter: String) -> Bool {
        dataCenters?.contains { $0.id == dataCenter && $0.availability != "NONE" } == true
    }

    var summary: String {
        "\(name) · \(memory) GB · \(price.secure.formatted(.currency(code: "USD")))/GPU/hour"
    }
}

struct GPUVolume: Identifiable, Codable {
    let id: String
    let name: String
    let size: Int
    let dataCenter: String
}

struct RentedPod: Identifiable, Codable {
    struct GPUs: Codable { let count: Int }
    let id: String
    let status: String
    let cost: Double
    let gpu: GPUs

    var isRunning: Bool {
        !["EXITED", "ERROR", "TERMINATED"].contains(status)
    }

    var agentURL: URL {
        URL(string: "https://\(id)-8800.proxy.runpod.net")!
    }
}

struct PodCreation {
    let offer: GPUOffer
    let count: Int
    let image: String
    let volume: GPUVolume
    let agentToken: String
    let hubToken: String
}

protocol GPUProvider: Sendable {
    func offers(count: Int) async throws -> [GPUOffer]
    func volumes() async throws -> [GPUVolume]
    func create(_ request: PodCreation) async throws -> RentedPod
    func status(id: String) async throws -> RentedPod
    func stop(id: String) async throws
    func terminate(id: String) async throws
}

/// Uses RunPod's REST v2 schema, fetched from api.runpod.io/v2/openapi.json on 2026-10-10.
struct RunPodProvider: GPUProvider {
    let key: String
    let transport: any HTTPTransport
    private let origin = URL(string: "https://api.runpod.io/v2")!

    func offers(count: Int) async throws -> [GPUOffer] {
        struct Result: Decodable { let gpus: [GPUOffer] }
        let data = try await call("catalog/gpus", query: [
            URLQueryItem(name: "include", value: "AVAILABILITY"), URLQueryItem(name: "product", value: "POD"),
            URLQueryItem(name: "cloud", value: "SECURE"), URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "minCudaVersion", value: "13.0"),
        ])
        return try JSONDecoder().decode(Result.self, from: data).gpus
            .filter { $0.secure && $0.maxCount.secure >= count && $0.price.secure > 0 }
            .sorted { $0.price.secure < $1.price.secure }
    }

    func volumes() async throws -> [GPUVolume] {
        struct Result: Decodable { let networkVolumes: [GPUVolume] }
        return try await JSONDecoder().decode(Result.self, from: call("network-volumes")).networkVolumes
    }

    func create(_ request: PodCreation) async throws -> RentedPod {
        guard [1, 2, 4].contains(request.count), request.count <= request.offer.maxCount.secure else {
            throw StudioError.message("Choose 1, 2 or 4 GPUs available for this computer.")
        }
        let payload: JSONObject = [
            "name": .string("ConceptStudio"), "image": .string(request.image), "cloud": .string("SECURE"),
            "gpu": .object([
                "id": .string(request.offer.id),
                "count": .int(request.count),
                "minCudaVersion": .string("13.0"),
            ]),
            "disk": .int(50),
            "dataCenterIds": .array([.string(request.volume.dataCenter)]),
            "mounts": .object(["network": .array([.object([
                "volumeId": .string(request.volume.id), "path": .string("/workspace"),
            ])])]),
            "ports": .array([.string("8800/http"), .string("8000/http")]),
            "env": .object(["PODAGENT_TOKEN": .string(request.agentToken), "HF_TOKEN": .string(request.hubToken)]),
        ]
        return try await JSONDecoder().decode(RentedPod.self, from: call("pods", method: "POST", body: payload))
    }

    func status(id: String) async throws -> RentedPod {
        try await JSONDecoder().decode(RentedPod.self, from: call("pods/\(id)"))
    }

    func stop(id: String) async throws {
        _ = try await call("pods/\(id)/action", method: "POST", body: ["action": .string("stop")])
    }

    func terminate(id: String) async throws {
        _ = try await call("pods/\(id)", method: "DELETE")
    }

    private func call(
        _ path: String, method: String = "GET", body: JSONObject? = nil, query: [URLQueryItem] = []
    ) async throws -> Data {
        var components = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONValue.object(body).pythonDumpsData()
        }
        let response = try await transport.send(request)
        guard (200 ..< 300).contains(response.status) else {
            switch response.status {
            case 401, 403: throw StudioError.message("RunPod could not accept your key. Check it in Settings.")
            case 409, 429,
                 503: throw StudioError
                .message("This computer is not available now. Refresh the list or choose another.")
            default: throw StudioError
                .message(
                    "RunPod could not complete this action (\(response.status)). Check your account and try again."
                )
            }
        }
        return response.body
    }
}

actor DemoGPUProvider: GPUProvider {
    private var pod = RentedPod(id: "demo", status: "EXITED", cost: 0, gpu: .init(count: 1))

    func offers(count: Int) -> [GPUOffer] {
        [GPUOffer(
            id: "demo-80",
            name: "Demo training computer",
            memory: 80,
            secure: true,
            price: .init(secure: 1.50),
            maxCount: .init(secure: 4),
            availability: "HIGH", dataCenters: [.init(id: "demo", availability: "HIGH")]
        )]
    }

    func volumes() -> [GPUVolume] {
        [GPUVolume(id: "demo-volume", name: "Demo project storage", size: 100, dataCenter: "demo")]
    }

    func create(_ request: PodCreation) -> RentedPod {
        pod = RentedPod(
            id: "demo",
            status: "RUNNING",
            cost: request.offer.price.secure * Double(request.count),
            gpu: .init(count: request.count)
        )
        return pod
    }

    func status(id: String) -> RentedPod {
        pod
    }

    func stop(id: String) {
        pod = RentedPod(id: id, status: "EXITED", cost: 0, gpu: pod.gpu)
    }

    func terminate(id: String) {
        pod = RentedPod(id: id, status: "TERMINATED", cost: 0, gpu: pod.gpu)
    }
}
