import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor EndpointWire: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: 200, body: Data(#"{"model":"m","choices":[{"message":{"content":"{}"}}]}"#.utf8))
    }
}

@Suite("app endpoint trust")
@MainActor
struct StudioEndpointTests {
    @Test func downloadedJobTargetDoesNotBecomeTheConfiguredKeyHost() async throws {
        let session = StudioSession()
        session.customBaseURL = "https://trusted.example/v1"
        let downloaded = try Job(
            concepts: [Concept(trigger: "NORA7")],
            endpoints: Endpoints(
                captioner: EndpointSpec(kind: "vllm", model: "m", baseURL: "https://different.example/v1"),
                critic: EndpointSpec(kind: "vllm", model: "critic", baseURL: "https://reviewer.example/v1")
            )
        )
        session.applyJobChoices(downloaded)
        let wire = EndpointWire()
        let resolved = try session.endpoint(keys: StaticKeyStore(
            [.vllm: "test-only-key"],
            vllmBaseURL: session.customBaseURL
        ), transport: wire)
        _ = try await resolved.client.request(
            instructions: "test",
            messages: [.user("test")],
            output: OutputRequest(
                name: Caption.schemaName,
                schema: Caption.jsonSchema,
                mode: .native
            ),
            settings: resolved.settings
        )
        let request = try #require(await wire.requests.first)
        #expect(request.url?.host() == "different.example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(session.customBaseURL == "https://trusted.example/v1")
        let critic = try session.endpoint(
            model: session.criticModel,
            kind: session.criticKind,
            baseURL: session.criticTargetURL,
            keys: StaticKeyStore([.vllm: "test-only-key"], vllmBaseURL: session.customBaseURL),
            transport: wire
        )
        _ = try await critic.client.request(
            instructions: "test",
            messages: [.user("test")],
            output: OutputRequest(name: Critique.schemaName, schema: Critique.jsonSchema, mode: .native),
            settings: critic.settings
        )
        let criticRequest = try #require(await wire.requests.last)
        #expect(criticRequest.url?.host() == "reviewer.example")
        #expect(criticRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func demoPodChoiceDoesNotChangeSavedLivePreferences() async throws {
        let name = "ConceptStudio.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set("https://user-server.example/v1", forKey: "vllmBaseURL")
        preferences.set("owner/real-dataset", forKey: "hubRepo")
        preferences.set("openrouter", forKey: "endpointKind")
        let session = StudioSession(preferences: preferences)
        session.useDemo()
        await session.task?.value
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await session.gpu.refreshOffers()
        await session.gpu.rent()
        session.usePodCaptionServer()
        await session.task?.value
        #expect(session.usingPodCaptioner)
        #expect(session.customBaseURL == "https://user-server.example/v1")
        #expect(session.requestBaseURL == session.gpu.captionEndpoint?.absoluteString)
        await session.closeProject()
        session.demoMode = false
        session.loadSavedChoices()
        #expect(session.requestBaseURL.isEmpty)
        #expect(!session.usingPodCaptioner)
        #expect(session.endpointKind == "openrouter")
        #expect(session.repoID == "owner/real-dataset")
        #expect(session.vllmTargetURL == "https://user-server.example/v1")
    }
}
