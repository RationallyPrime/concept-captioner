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
    @Test func chatGPTChoiceNeverFallsBackToSavedAPIKey() throws {
        let session = makeTestSession()
        session.endpointKind = "openai"
        session.openAIUsesChatGPT = true
        session.modelName = "account-model"
        #expect(throws: StudioError.self) {
            _ = try session.endpoint(keys: StaticKeyStore([.openai: "must-not-be-used"]))
        }
    }

    @Test func chatGPTAuthenticationStaysOutsideTheSharedJob() async throws {
        let name = "ConceptStudio.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let session = StudioSession(preferences: preferences)
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        session.project = project
        session.endpointKind = "openai"
        session.modelName = "account-model"
        session.openAIUsesChatGPT = true
        let job = try session.jobForCaptioning()
        #expect(job.endpoints?.captioner.kind == "openai")
        #expect(job.endpoints?.captioner.model == "account-model")
        #expect(job.endpoints?.captioner.baseURL == nil)
        #expect(job.endpoints?.captioner.settings.isEmpty == true)
        session.rememberChoices()
        let reopened = StudioSession(preferences: preferences)
        reopened.applyJobChoices(job)
        #expect(reopened.openAIUsesChatGPT)
        #expect(reopened.endpointKind == "openai")
        #expect(reopened.modelName == "account-model")
    }

    @Test func demoUsesFakeModelWithChatGPTSelectedAndNoAccount() async throws {
        let session = makeTestSession()
        session.demoMode = true
        session.endpointKind = "openai"
        session.openAIUsesChatGPT = true
        let endpoint = try session.endpoint()
        #expect(endpoint.client is DemoModelClient)
        await session.prepareChatGPTModels()
        #expect(session.chatGPT.accounts.isEmpty)
    }

    @Test func chatGPTSettingsRecoveryKeepsOtherProviderSettings() async throws {
        let session = makeTestSession()
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job.endpoints = try Endpoints(
            captioner: EndpointSpec(
                kind: "openai",
                model: "account-model",
                outputMode: .tool,
                settings: ["max_tokens": .int(8192)]
            ),
            critic: EndpointSpec(kind: "google", model: "reviewer", settings: ["temperature": .double(0.2)])
        )
        session.project = project
        session.applyJobChoices(project.job)
        session.openAIUsesChatGPT = true
        session.modelThinking = .high
        #expect(session.chatGPTConfigurationIssue != nil)
        session.useDefaultChatGPTSettings()
        #expect(session.chatGPTConfigurationIssue == nil)
        #expect(session.project?.job.endpoints?.captioner.settings.isEmpty == true)
        #expect(session.project?.job.endpoints?.captioner.outputMode == .native)
        #expect(session.project?.job.endpoints?.critic?.settings["temperature"] == .double(0.2))
        #expect(session.modelThinking == .high)
        #expect(session.errorMessage == nil)
    }

    @Test func downloadedJobTargetDoesNotBecomeTheConfiguredKeyHost() async throws {
        let session = makeTestSession()
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
        let session = makeTestSession(preferences: preferences)
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
        // The dataset destination belongs to each project; an app-wide value never seeds it.
        #expect(session.repoID.isEmpty)
        #expect(session.vllmTargetURL == "https://user-server.example/v1")
    }
}
