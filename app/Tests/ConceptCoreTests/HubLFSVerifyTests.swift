import ConceptCore
import Foundation
import Testing

@Suite("Hub LFS verify")
struct HubLFSVerifyTests {
    private func transport(verifyStatus: Int = 200) -> StubTransport {
        StubTransport { request in
            let url = try #require(request.url)
            if url.path().contains("preupload") {
                let files = try #require(StubTransport.body(of: request)["files"] as? [[String: Any]])
                return try StubTransport.json(["files": files.map { ["path": $0["path"]!, "uploadMode": "lfs"] }])
            }
            if url.path().hasSuffix("batch") {
                let objects = try #require(StubTransport.body(of: request)["objects"] as? [[String: Any]])
                return try StubTransport.json(["objects": objects.map { object in
                    let oid = try #require(object["oid"] as? String)
                    return ["oid": oid, "actions": [
                        "upload": ["href": "https://cdn.test/upload/\(oid)"],
                        "verify": ["href": "https://huggingface.co/verify/\(oid)", "header": ["X-Verify": oid]],
                    ]]
                }])
            }
            if url.path().contains("verify") {
                return HTTPResponse(status: verifyStatus, body: Data("verification failed".utf8))
            }
            if url.path().contains("commit") {
                return try StubTransport.json(["commitOid": "commit", "commitUrl": "https://huggingface.co/commit"])
            }
            return HTTPResponse(status: 200)
        }
    }

    @Test func everyPutIsVerifiedBeforeCommit() async throws {
        let transport = transport()
        let client = HubClient(token: "hf_test", transport: transport)
        _ = try await client.commit(
            repo: RepoID("test/images"),
            operations: [.add(path: "a.png", data: Data([1, 2, 3])), .add(path: "b.png", data: Data([4, 5]))],
            message: "images"
        )
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "PUT", "POST", "PUT", "POST", "POST"])
        for (putIndex, size) in [(2, 3), (4, 2)] {
            let put = requests[putIndex]
            let verify = requests[putIndex + 1]
            let oid = try #require(put.url?.lastPathComponent)
            #expect(put.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(verify.url?.absoluteString == "https://huggingface.co/verify/\(oid)")
            #expect(verify.value(forHTTPHeaderField: "Authorization") == "Bearer hf_test")
            #expect(verify.value(forHTTPHeaderField: "X-Verify") == oid)
            #expect(verify.value(forHTTPHeaderField: "Accept") == "application/vnd.git-lfs+json")
            #expect(verify.value(forHTTPHeaderField: "Content-Type") == "application/vnd.git-lfs+json")
            let body = try StubTransport.body(of: verify)
            #expect(body["oid"] as? String == oid)
            #expect(body["size"] as? Int == size)
        }
    }

    @Test func verificationFailureStopsBeforeCommit() async throws {
        let transport = transport(verifyStatus: 422)
        let error = await #expect(throws: HubError.self) {
            try await HubClient(token: "hf_test", transport: transport).uploadFile(
                repo: RepoID("test/images"), path: "a.png", data: Data([1]), message: "image"
            )
        }
        guard case let .http(status, _) = error else { Issue.record("expected HTTP error"); return }
        #expect(status == 422)
        #expect(await transport.requests.count == 4)
        #expect(await transport.requests.last?.url?.path().contains("verify") == true)
    }
}
