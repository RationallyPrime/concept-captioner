import ConceptCore
import Foundation
import Security

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
        "\(name) · \(memory) GB · \(StudioMoney.format(price.secure))/GPU/hour"
    }
}

struct GPUVolume: Identifiable, Codable {
    let id: String
    let name: String
    let size: Int
    let dataCenter: String
}

/// A pod as the provider reports it. Every field added after the first release is optional so a
/// record saved by an older build still decodes (startup recovery depends on it).
struct RentedPod: Identifiable, Codable {
    struct GPUs: Codable { let count: Int }
    struct Mounts: Codable { let network: [PodNetworkMount]? }

    let id: String
    let status: String
    let cost: Double
    let gpu: GPUs
    var name: String?
    var mounts: Mounts?

    init(id: String, status: String, cost: Double, gpu: GPUs, name: String? = nil, mounts: Mounts? = nil) {
        self.id = id
        self.status = status
        self.cost = cost
        self.gpu = gpu
        self.name = name
        self.mounts = mounts
    }

    /// The network volume mounted at /workspace, when the provider reports it.
    var volumeID: String? {
        mounts?.network?.first?.volumeId
    }

    var isRunning: Bool {
        !["EXITED", "ERROR", "TERMINATED"].contains(status)
    }

    /// Pods this app creates are named `ConceptStudio-<project>`; earlier builds used the bare prefix.
    var isFromThisApp: Bool {
        name.map(PodNaming.isFromThisApp) ?? false
    }
}

/// One element of `GET /v2/pods`. Other pods on the account need not match `RentedPod` (a CPU pod
/// has no `gpu`), so the name is read first and only this app's pods are decoded in full.
private struct PodListEntry: Decodable {
    private struct Named: Decodable { let name: String? }

    let name: String?
    let pod: Result<RentedPod, any Error>

    init(from decoder: any Decoder) throws {
        name = try? Named(from: decoder).name
        pod = Result(catching: { try RentedPod(from: decoder) })
    }
}

struct PodNetworkMount: Codable {
    let volumeId: String
}

/// The ports the app publishes on every pod (POD-SPEC §1). Which URL reaches a port is the
/// provider's business, not the workspace's.
enum PodPort {
    static let agent = 8800
    static let inference = 8000
}

enum PodNaming {
    static let prefix = "ConceptStudio"

    static func isFromThisApp(_ name: String) -> Bool {
        name == prefix || name.hasPrefix(prefix + "-")
    }

    static func name(project: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(project.map { allowed.contains($0) ? $0 : "-" }.prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? prefix : "\(prefix)-\(cleaned)"
    }
}

struct PodCreation {
    let name: String
    let offer: GPUOffer
    let count: Int
    let image: String
    /// Lowest host CUDA version the image's wheels run on, as `major.minor`.
    let minCudaVersion: String
    let volume: GPUVolume
    /// The environment the container boots with. Credentials are never literal here: the
    /// workspace stores them as account secrets first and passes `PodSecrets.reference` values.
    let env: [String: String]
}

/// RunPod account secrets stand in for credentials in a pod's environment. A pod listing returns
/// `env` verbatim, so a literal token there is readable by anyone who can read the account; a
/// `{{ RUNPOD_SECRET_<name> }}` placeholder is substituted only inside the container when it
/// boots, and a secret's value can never be read back (`account/secrets` in the v2 schema).
enum PodSecrets {
    /// The user's Hub token, rewritten before every rental so a rotated token takes effect.
    static let hubTokenName = "conceptstudio_hf_token"
    /// One agent bearer per pod, deleted when the pod is removed.
    static let agentPrefix = "conceptstudio_agent_"
    private static let marker = "RUNPOD_SECRET_"

    static func reference(_ name: String) -> String {
        "{{ \(marker)\(name) }}"
    }

    /// The secret a placeholder names; nil for a literal value.
    static func referencedName(in value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}") else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix(marker), inner.count > marker.count else { return nil }
        return String(inner.dropFirst(marker.count))
    }

    /// `conceptstudio_agent_` plus 96 random bits, hex encoded.
    static func newAgentSecretName() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StudioError.message("Your Mac could not generate a key for the computer. Try again.")
        }
        return agentPrefix + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

protocol GPUProvider: Sendable {
    func offers(count: Int, minCudaVersion: String) async throws -> [GPUOffer]
    func volumes() async throws -> [GPUVolume]
    func create(_ request: PodCreation) async throws -> RentedPod
    func status(id: String) async throws -> RentedPod
    /// Every pod on the account this app created (named `ConceptStudio…`), any status. Throws when
    /// the account cannot be listed or one of this app's pods cannot be read.
    func list() async throws -> [RentedPod]
    func stop(id: String) async throws
    func terminate(id: String) async throws
    /// The HTTPS URL that reaches `port` on the pod.
    func url(for pod: RentedPod, port: Int) -> URL
    /// Writes `value` under `name` in the account's secret store, replacing an existing value.
    func storeSecret(name: String, value: String) async throws
    /// Removes the named secret. A secret that does not exist is not an error.
    func deleteSecret(name: String) async throws
    /// Secrets whose name starts with `prefix` that no pod on the account, in any state, references.
    func orphanedSecrets(prefix: String) async throws -> [String]
}

/// One page of `GET /v2/pods`, decoded as whatever the caller needs from each pod.
private struct PodPage<Entry: Decodable>: Decodable {
    struct Pagination: Decodable {
        let nextCursor: String?
        let hasNextPage: Bool
    }

    let pods: [Entry]
    let pagination: Pagination?
}

/// Uses RunPod's REST v2 schema, fetched from api.runpod.io/v2/openapi.json on 2026-10-10 and
/// re-read 2026-10-11 for `GET /v2/pods` (cursor-paginated, newest first, with `name` and `mounts`).
struct RunPodProvider: GPUProvider {
    let key: String
    let transport: any HTTPTransport
    private let origin = URL(string: "https://api.runpod.io/v2")!

    func offers(count: Int, minCudaVersion: String) async throws -> [GPUOffer] {
        struct Result: Decodable { let gpus: [GPUOffer] }
        let data = try await call("catalog/gpus", query: [
            URLQueryItem(name: "include", value: "AVAILABILITY"), URLQueryItem(name: "product", value: "POD"),
            URLQueryItem(name: "cloud", value: "SECURE"), URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "minCudaVersion", value: minCudaVersion),
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
            "name": .string(request.name), "image": .string(request.image), "cloud": .string("SECURE"),
            "gpu": .object([
                "id": .string(request.offer.id),
                "count": .int(request.count),
                "minCudaVersion": .string(request.minCudaVersion),
                "minRamPerGpu": .int(60),
            ]),
            "disk": .int(50),
            "dataCenterIds": .array([.string(request.volume.dataCenter)]),
            "mounts": .object(["network": .array([.object([
                "volumeId": .string(request.volume.id), "path": .string("/workspace"),
            ])])]),
            "ports": .array([.string("\(PodPort.agent)/http"), .string("\(PodPort.inference)/http")]),
            "env": .object(JSONObject(
                request.env.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) }
            )),
        ]
        return try await JSONDecoder().decode(RentedPod.self, from: call("pods", method: "POST", body: payload))
    }

    func status(id: String) async throws -> RentedPod {
        try await JSONDecoder().decode(RentedPod.self, from: call("pods/\(id)"))
    }

    func list() async throws -> [RentedPod] {
        var pods: [RentedPod] = []
        for entry in try await podPages(PodListEntry.self) where entry.name.map(PodNaming.isFromThisApp) == true {
            try pods.append(entry.pod.get())
        }
        return pods
    }

    /// Every pod on the account, newest first, across the cursor-paginated pages.
    private func podPages<Entry: Decodable>(_: Entry.Type) async throws -> [Entry] {
        var entries: [Entry] = []
        var cursor: String?
        for _ in 0 ..< 20 {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try await JSONDecoder().decode(PodPage<Entry>.self, from: call("pods", query: query))
            entries.append(contentsOf: page.pods)
            guard page.pagination?.hasNextPage == true, let next = page.pagination?.nextCursor else { break }
            cursor = next
        }
        return entries
    }

    func stop(id: String) async throws {
        _ = try await call("pods/\(id)/action", method: "POST", body: ["action": .string("stop")])
    }

    func terminate(id: String) async throws {
        _ = try await call("pods/\(id)", method: "DELETE")
    }

    private struct Secret: Decodable {
        let id: String
        let name: String
    }

    private struct SecretList: Decodable { let secrets: [Secret] }

    /// `GET account/secrets?name=` filters case-insensitively; the exact name is kept here.
    private func secrets(named name: String) async throws -> [Secret] {
        let listed = try await JSONDecoder().decode(
            SecretList.self, from: call("account/secrets", query: [URLQueryItem(name: "name", value: name)])
        )
        return listed.secrets.filter { $0.name == name }
    }

    func storeSecret(name: String, value: String) async throws {
        if let existing = try await secrets(named: name).first {
            _ = try await call("account/secrets/\(existing.id)", method: "PATCH", body: ["value": .string(value)])
        } else {
            _ = try await call("account/secrets", method: "POST", body: [
                "name": .string(name), "value": .string(value),
                "description": .string("Written by ConceptStudio and referenced from its pods' environment."),
            ])
        }
    }

    func deleteSecret(name: String) async throws {
        for secret in try await secrets(named: name) {
            _ = try await call("account/secrets/\(secret.id)", method: "DELETE")
        }
    }

    func orphanedSecrets(prefix: String) async throws -> [String] {
        struct Environment: Decodable { let env: [String: String]? }
        let names = try await JSONDecoder().decode(SecretList.self, from: call("account/secrets")).secrets
            .map(\.name).filter { $0.hasPrefix(prefix) }
        guard !names.isEmpty else { return [] }
        var referenced: Set<String> = []
        for pod in try await podPages(Environment.self) {
            for value in (pod.env ?? [:]).values {
                if let name = PodSecrets.referencedName(in: value) { referenced.insert(name) }
            }
        }
        return names.filter { !referenced.contains($0) }.sorted()
    }

    /// RunPod's HTTP proxy: `https://<pod-id>-<port>.proxy.runpod.net` (POD-SPEC §1).
    func url(for pod: RentedPod, port: Int) -> URL {
        URL(string: "https://\(pod.id)-\(port).proxy.runpod.net")!
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

    func offers(count: Int, minCudaVersion: String) -> [GPUOffer] {
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
            gpu: .init(count: request.count),
            name: request.name
        )
        return pod
    }

    func status(id: String) -> RentedPod {
        pod
    }

    func list() -> [RentedPod] {
        pod.status == "TERMINATED" ? [] : [pod]
    }

    func stop(id: String) {
        pod = RentedPod(id: id, status: "EXITED", cost: 0, gpu: pod.gpu, name: pod.name)
    }

    func terminate(id: String) {
        pod = RentedPod(id: id, status: "TERMINATED", cost: 0, gpu: pod.gpu, name: pod.name)
    }

    nonisolated func url(for pod: RentedPod, port: Int) -> URL {
        URL(string: "https://demo.invalid:\(port)")!
    }

    /// The demo has no account: secrets are accepted and forgotten.
    func storeSecret(name: String, value: String) {}

    func deleteSecret(name: String) {}

    func orphanedSecrets(prefix: String) -> [String] {
        []
    }
}
