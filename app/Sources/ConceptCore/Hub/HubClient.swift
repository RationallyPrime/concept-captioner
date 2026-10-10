// Hugging Face Hub HTTP API with an injected token: list, download, create, commit (with LFS).
// Python counterpart: huggingface_hub as used by sources/hf.py. Only the dataset repo type is
// spoken; the imagefolder source and sink are built on top of it.

import CryptoKit
import Foundation

public struct RepoID: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let namespace: String?
    public let name: String

    /// "ns/name" or "name"; HubError.malformed otherwise. Each component uses the characters the
    /// Hub allows in repo names (ASCII letters, digits, `-`, `_`, `.`) and never contains `..`.
    public init(_ id: String) throws {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), parts.allSatisfy(RepoID.isComponent) else {
            throw HubError.malformed("repo id must look like 'namespace/name' or 'name', got '\(id)'")
        }
        namespace = parts.count == 2 ? String(parts[0]) : nil
        name = String(parts[parts.count - 1])
    }

    public var id: String {
        if let namespace { return "\(namespace)/\(name)" }
        return name
    }

    public var description: String {
        id
    }

    private static let componentScalars = CharacterSet(charactersIn: "a" ... "z")
        .union(CharacterSet(charactersIn: "A" ... "Z"))
        .union(CharacterSet(charactersIn: "0" ... "9"))
        .union(CharacterSet(charactersIn: "-_."))

    private static func isComponent(_ component: Substring) -> Bool {
        !component.isEmpty && !component.contains("..")
            && component.unicodeScalars.allSatisfy { componentScalars.contains($0) }
    }
}

public struct HubFile: Sendable, Equatable {
    public let path: String
    public let size: Int
    /// Git blob sha, or the LFS sha256 for LFS files.
    public let oid: String
    public let isLFS: Bool

    public init(path: String, size: Int, oid: String, isLFS: Bool) {
        self.path = path
        self.size = size
        self.oid = oid
        self.isLFS = isLFS
    }

    /// A tree item `{type, path, size, oid, lfs?: {oid, size}}`; nil for a directory entry.
    /// For an LFS file `oid` and `size` describe the object, not the pointer.
    init?(treeItem: JSONValue) throws {
        guard let object = treeItem.objectValue, let type = object["type"]?.stringValue else {
            throw HubError.malformed("tree entry is not an object with a type: \(treeItem.pythonDumps())")
        }
        guard type == "file" else { return nil }
        guard let path = object["path"]?.stringValue, let oid = object["oid"]?.stringValue else {
            throw HubError.malformed("tree file entry needs path and oid: \(treeItem.pythonDumps())")
        }
        let lfs = object["lfs"]?.objectValue
        self.path = path
        isLFS = lfs != nil
        self.oid = lfs?["oid"]?.stringValue ?? oid
        size = HubClient.integer(lfs?["size"]) ?? HubClient.integer(object["size"]) ?? 0
    }
}

public enum CommitOperation: Sendable {
    /// Bytes already in memory (metadata.jsonl, a job file). The client decides regular vs LFS via preupload.
    case add(path: String, data: Data)
    /// A file on disk. It is sampled, hashed and uploaded by reading through it when its turn
    /// comes, so a commit of many images never holds more than one of them in memory.
    case addFile(path: String, url: URL)
    case delete(path: String)

    /// The repo path this operation touches.
    public var path: String {
        switch self {
        case let .add(path, _), let .addFile(path, _), let .delete(path): path
        }
    }
}

public struct CommitResult: Sendable, Equatable {
    public let commitOID: String
    public let commitURL: String

    public init(commitOID: String, commitURL: String) {
        self.commitOID = commitOID
        self.commitURL = commitURL
    }
}

public struct HubClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://huggingface.co")!

    /// Error bodies are truncated to this many bytes in `HubError.http`.
    static let errorBodyLimit = 4096
    /// Leading bytes of each file the preupload call samples (huggingface_hub sends the same).
    static let preuploadSampleBytes = 512
    /// Files per preupload and per LFS batch request, the Hub's limit as huggingface_hub applies it.
    static let batchSize = 256
    static let lfsMediaType = "application/vnd.git-lfs+json"

    public let endpoint: URL
    public let token: String?
    public let transport: any HTTPTransport

    public init(token: String?, endpoint: URL = defaultEndpoint, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.endpoint = endpoint
        self.transport = transport
    }

    // MARK: - Public API

    /// GET /api/datasets/{repo}/tree/{revision}?recursive=true, following the Link next cursor.
    /// Directory entries (which a recursive listing may still include) are dropped.
    public func listFiles(repo: RepoID, revision: String = "main") async throws -> [HubFile] {
        var next: URL? = try url(
            "/api/datasets/\(HubClient.encodePath(repo.id))/tree/\(HubClient.encodeSegment(revision))",
            query: "recursive=true"
        )
        var files: [HubFile] = []
        while let page = next {
            let response = try await send(request("GET", page, authorized: isOwnHost(page)))
            guard let items = try parseJSON(response.body).arrayValue else {
                throw HubError.malformed("tree listing is not a JSON array")
            }
            for item in items {
                if let file = try HubFile(treeItem: item) {
                    files.append(file)
                }
            }
            next = try HubClient.nextLink(in: response.headers)
        }
        return files
    }

    /// GET /datasets/{repo}/resolve/{revision}/{path}
    public func download(repo: RepoID, path: String, revision: String = "main") async throws -> Data {
        let target = try url(
            "/datasets/\(HubClient.encodePath(repo.id))/resolve/\(HubClient.encodeSegment(revision))/"
                + HubClient.encodePath(path)
        )
        return try await send(request("GET", target)).body
    }

    /// POST /api/repos/create; 409 is success when existOK.
    public func createRepo(_ repo: RepoID, private isPrivate: Bool = false, existOK: Bool = true) async throws {
        var body: JSONObject = ["type": .string("dataset"), "name": .string(repo.name)]
        if let namespace = repo.namespace {
            body["organization"] = .string(namespace)
        }
        body["private"] = .bool(isPrivate)
        _ = try await send(jsonRequest("POST", url("/api/repos/create"), body: body), accepting: existOK ? [409] : [])
    }

    /// preupload -> lfs batch -> PUT each LFS object -> one NDJSON commit.
    ///
    /// LFS objects are hashed and uploaded one at a time; a `.addFile` operation is read from
    /// disk for each step and never kept whole between steps. `onProgress` sees `.hashing` and
    /// `.uploading` once per LFS file and `.committing` once.
    public func commit(
        repo: RepoID,
        operations: [CommitOperation],
        message: String,
        description: String = "",
        revision: String = "main",
        onProgress: @escaping HubProgressHandler = { _ in }
    ) async throws -> CommitResult {
        guard !operations.isEmpty else { throw HubError.malformed("a commit needs at least one operation") }
        let adds = try operations.compactMap(CommitSource.init)
        let modes = try await preupload(repo: repo, revision: revision, adds: adds)

        var lines: [JSONValue] = [
            .object(["key": .string("header"), "value": .object([
                "summary": .string(message), "description": .string(description),
            ])]),
        ]
        // Files the preupload told us to ignore (.gitignore'd) are left out of the commit.
        let lfsAdds = adds.filter { modes[$0.path] == .lfs }
        // In operation order, so upload progress walks the files the way the caller listed them.
        var lfsObjects: [(oid: String, source: CommitSource)] = []
        var lfsOIDs: Set<String> = []
        var hashed = 0
        var next = adds.startIndex // `adds` holds the add operations in order
        for operation in operations {
            switch operation {
            case .add, .addFile:
                let add = adds[next]
                next += 1
                guard let mode = modes[add.path] else { continue }
                switch mode {
                case .regular:
                    try lines.append(.object(["key": .string("file"), "value": .object([
                        "path": .string(add.path), "content": .string(add.bytes().base64EncodedString()),
                        "encoding": .string("base64"),
                    ])]))
                case .lfs:
                    onProgress(HubProgress(
                        phase: .hashing, path: add.path, completed: hashed, total: lfsAdds.count, bytes: add.size
                    ))
                    let oid = try add.sha256Hex()
                    hashed += 1
                    if lfsOIDs.insert(oid).inserted {
                        lfsObjects.append((oid, add))
                    }
                    lines.append(.object(["key": .string("lfsFile"), "value": .object([
                        "path": .string(add.path), "algo": .string("sha256"), "oid": .string(oid),
                        "size": .int(add.size),
                    ])]))
                }
            case let .delete(path):
                lines.append(.object(["key": .string("deletedFile"), "value": .object(["path": .string(path)])]))
            }
        }
        try await uploadLFS(repo: repo, objects: lfsObjects, onProgress: onProgress)

        onProgress(HubProgress(phase: .committing, total: operations.count))
        var request = try request(
            "POST",
            url("/api/datasets/\(HubClient.encodePath(repo.id))/commit/\(HubClient.encodeSegment(revision))")
        )
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(lines.map { $0.pythonDumps() }.joined(separator: "\n").utf8)
        let reply = try await parseJSON(send(request).body)
        guard let oid = reply.objectValue?["commitOid"]?.stringValue,
              let commitURL = reply.objectValue?["commitUrl"]?.stringValue
        else {
            throw HubError.malformed("commit reply has no commitOid/commitUrl: \(reply.pythonDumps())")
        }
        return CommitResult(commitOID: oid, commitURL: commitURL)
    }

    /// Single-file convenience (push_job parity; path "concept-captioner/job.yaml").
    public func uploadFile(repo: RepoID, path: String, data: Data, message: String) async throws -> CommitResult {
        try await commit(repo: repo, operations: [.add(path: path, data: data)], message: message)
    }

    // MARK: - Commit steps

    enum UploadMode: String {
        case regular
        case lfs
    }

    /// POST /api/datasets/{repo}/preupload/{revision}: the Hub decides, from a 512-byte sample and
    /// the size, which files are LFS. Files it flags `shouldIgnore` are absent from the result.
    func preupload(repo: RepoID, revision: String, adds: [CommitSource]) async throws -> [String: UploadMode] {
        var modes: [String: UploadMode] = [:]
        var start = 0
        while start < adds.count {
            let batch = adds[start ..< min(start + HubClient.batchSize, adds.count)]
            start += HubClient.batchSize
            let files = try batch.map { add in
                try JSONValue.object([
                    "path": .string(add.path),
                    "sample": .string(add.sample().base64EncodedString()),
                    "size": .int(add.size),
                ])
            }
            let target = try url(
                "/api/datasets/\(HubClient.encodePath(repo.id))/preupload/\(HubClient.encodeSegment(revision))"
            )
            let reply = try await parseJSON(send(jsonRequest("POST", target, body: ["files": .array(files)])).body)
            guard let entries = reply.objectValue?["files"]?.arrayValue else {
                throw HubError.malformed("preupload reply has no files: \(reply.pythonDumps())")
            }
            var answered: Set<String> = []
            for entry in entries {
                guard let object = entry.objectValue, let path = object["path"]?.stringValue,
                      let modeName = object["uploadMode"]?.stringValue, let mode = UploadMode(rawValue: modeName)
                else {
                    throw HubError.malformed("preupload entry needs path and uploadMode: \(entry.pythonDumps())")
                }
                answered.insert(path)
                if object["shouldIgnore"]?.boolValue != true {
                    modes[path] = mode
                }
            }
            if let missing = batch.first(where: { !answered.contains($0.path) }) {
                throw HubError.malformed("preupload did not answer for '\(missing.path)'")
            }
        }
        return modes
    }

    /// POST the LFS batches, then PUT every object the Hub does not have yet to the href it
    /// hands back, with the headers it names and without the Hub token (that host is a CDN, not
    /// the Hub), and POST the batch's `verify` action (when it names one) so the Hub registers
    /// the object before the commit references it, as huggingface_hub does. Uploads follow
    /// `objects` order; each object's bytes are read for its PUT alone, so one object is in
    /// memory at a time.
    func uploadLFS(
        repo: RepoID,
        objects: [(oid: String, source: CommitSource)],
        onProgress: HubProgressHandler = { _ in }
    ) async throws {
        guard !objects.isEmpty else { return }
        var actions: [String: LFSUpload] = [:]
        var start = 0
        while start < objects.count {
            let batch = objects[start ..< min(start + HubClient.batchSize, objects.count)]
            start += HubClient.batchSize
            for action in try await lfsBatch(repo: repo, objects: batch.map { ($0.oid, $0.source.size) }) {
                actions[action.oid] = action
            }
        }
        let pending = objects.filter { actions[$0.oid] != nil }
        for (index, object) in pending.enumerated() {
            let action = actions[object.oid]!
            onProgress(HubProgress(
                phase: .uploading, path: object.source.path, completed: index, total: pending.count,
                bytes: object.source.size
            ))
            var put = URLRequest(url: action.href)
            put.httpMethod = "PUT"
            for (name, value) in action.headers {
                put.setValue(value, forHTTPHeaderField: name)
            }
            put.httpBody = try object.source.bytes()
            _ = try await send(put)
            if let verify = action.verify {
                try await verifyLFS(verify, oid: object.oid, size: object.source.size)
            }
        }
    }

    /// POST {oid, size} to the batch reply's verify href with the LFS media types, the headers
    /// the action names, and the Hub token when the href is on the Hub (it normally is; the
    /// upload href is not). A non-2xx reply is `HubError.http`: the object is not registered.
    private func verifyLFS(_ verify: LFSAction, oid: String, size: Int) async throws {
        var request = request("POST", verify.href, authorized: isOwnHost(verify.href))
        request.setValue(HubClient.lfsMediaType, forHTTPHeaderField: "Accept")
        request.setValue(HubClient.lfsMediaType, forHTTPHeaderField: "Content-Type")
        for (name, value) in verify.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = JSONValue.object(["oid": .string(oid), "size": .int(size)]).pythonDumpsData()
        _ = try await send(request)
    }

    /// An LFS batch action `{href, header?}`.
    struct LFSAction {
        let href: URL
        let headers: [String: String]

        init(_ action: JSONObject, named name: String, in entry: JSONValue) throws {
            guard let href = action["href"]?.stringValue, let url = URL(string: href) else {
                throw HubError.malformed("LFS \(name) action has no usable href: \(entry.pythonDumps())")
            }
            self.href = url
            var headers: [String: String] = [:]
            for pair in (action["header"]?.objectValue ?? [:]).pairs {
                headers[pair.key] = pair.value.stringValue ?? pair.value.pythonDumps()
            }
            self.headers = headers
        }
    }

    struct LFSUpload {
        let oid: String
        let href: URL
        let headers: [String: String]
        /// The `verify` action of the same batch entry; the Hub sends one, a bare LFS server may not.
        let verify: LFSAction?
    }

    /// One LFS batch call; returns the upload actions for objects the server still needs.
    private func lfsBatch(repo: RepoID, objects: [(oid: String, size: Int)]) async throws -> [LFSUpload] {
        var request = try request("POST", url("/datasets/\(HubClient.encodePath(repo.id)).git/info/lfs/objects/batch"))
        request.setValue(HubClient.lfsMediaType, forHTTPHeaderField: "Accept")
        request.setValue(HubClient.lfsMediaType, forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONValue.object([
            "operation": .string("upload"),
            "transfers": .array([.string("basic"), .string("multipart")]),
            "objects": .array(objects.map { .object(["oid": .string($0.oid), "size": .int($0.size)]) }),
            "hash_algo": .string("sha256"),
        ]).pythonDumpsData()
        let reply = try await parseJSON(send(request).body)
        guard let entries = reply.objectValue?["objects"]?.arrayValue else {
            throw HubError.malformed("LFS batch reply has no objects: \(reply.pythonDumps())")
        }
        var uploads: [LFSUpload] = []
        for entry in entries {
            guard let object = entry.objectValue, let oid = object["oid"]?.stringValue else {
                throw HubError.malformed("LFS batch entry needs an oid: \(entry.pythonDumps())")
            }
            if let error = object["error"]?.objectValue {
                throw HubError.http(
                    status: HubClient.integer(error["code"]) ?? 0,
                    body: error["message"]?.stringValue ?? entry.pythonDumps()
                )
            }
            // No actions: the server already stores this object.
            guard let upload = object["actions"]?.objectValue?["upload"]?.objectValue else { continue }
            if upload["header"]?.objectValue?["chunk_size"] != nil {
                throw HubError.unsupported("multipart LFS upload (> 5 GB) is not supported")
            }
            let uploadAction = try LFSAction(upload, named: "upload", in: entry)
            var verifyAction: LFSAction?
            if let verify = object["actions"]?.objectValue?["verify"]?.objectValue {
                verifyAction = try LFSAction(verify, named: "verify", in: entry)
            }
            uploads.append(
                LFSUpload(
                    oid: oid, href: uploadAction.href, headers: uploadAction.headers, verify: verifyAction
                )
            )
        }
        return uploads
    }

    // MARK: - Requests

    private func url(_ path: String, query: String? = nil) throws -> URL {
        var base = endpoint.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let text = base + path + (query.map { "?\($0)" } ?? "")
        guard let url = URL(string: text) else { throw HubError.malformed("could not build URL '\(text)'") }
        return url
    }

    private func isOwnHost(_ url: URL) -> Bool {
        url.host()?.lowercased() == endpoint.host()?.lowercased()
    }

    private func request(_ method: String, _ url: URL, authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if authorized, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func jsonRequest(_ method: String, _ url: URL, body: JSONObject) -> URLRequest {
        var request = request(method, url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONValue.object(body).pythonDumpsData()
        return request
    }

    /// Sends through the transport, mapping failures to `HubError`: thrown errors become
    /// `.transport`, non-2xx statuses outside `accepting` become `.http` with a truncated body.
    private func send(_ request: URLRequest, accepting: Set<Int> = []) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HubError {
            throw error
        } catch {
            throw HubError.transport(HubClient.describe(error))
        }
        guard (200 ..< 300).contains(response.status) || accepting.contains(response.status) else {
            throw HubError.http(status: response.status, body: HubClient.truncatedText(response.body))
        }
        return response
    }

    private func parseJSON(_ data: Data) throws -> JSONValue {
        do {
            return try JSONValue(parsing: data)
        } catch {
            throw HubError.malformed("reply is not JSON: \(HubClient.truncatedText(data))")
        }
    }

    // MARK: - Helpers

    /// Characters kept verbatim inside one path segment: `.urlPathAllowed` without the separator.
    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// Percent-encodes one segment; a `/` inside it (a revision like `refs/pr/1`) becomes `%2F`.
    static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    /// Percent-encodes each `/`-separated segment, keeping the separators.
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { encodeSegment(String($0)) }
            .joined(separator: "/")
    }

    /// The `rel="next"` target of a `Link` header (RFC 8288 `<url>; rel=next` entries), nil when absent.
    static func nextLink(in headers: [String: String]) throws -> URL? {
        guard let link = headers["link"] else { return nil }
        var rest = Substring(link)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else {
                throw HubError.malformed("unterminated Link header: \(link)")
            }
            let target = rest[rest.index(after: open) ..< close]
            let tail = rest[rest.index(after: close)...]
            let end = tail.firstIndex(of: ",") ?? tail.endIndex
            let isNext = tail[..<end].split(separator: ";").contains { parameter in
                let text = parameter.trimmingCharacters(in: .whitespaces).lowercased()
                return text == "rel=\"next\"" || text == "rel=next"
            }
            if isNext {
                guard let url = URL(string: String(target)) else {
                    throw HubError.malformed("Link next target is not a URL: \(target)")
                }
                return url
            }
            rest = tail[end...]
        }
        return nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An integer field that the Hub may send as an int or (for very large sizes) a double.
    static func integer(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double.isFinite, double.magnitude < 9_007_199_254_740_992 {
            return Int(double)
        }
        return nil
    }

    /// UTF-8 text of at most `errorBodyLimit` bytes; a split multi-byte character shows as a replacement mark.
    static func truncatedText(_ data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data.prefix(errorBodyLimit), as: UTF8.self)
    }

    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.domain == NSCocoaErrorDomain {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }
}
