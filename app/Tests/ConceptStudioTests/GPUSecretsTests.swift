// Credentials reach a pod as RunPod account secrets, never as literal environment values: the
// pod listing returns `env` verbatim, so a literal token there is readable by anyone who can read
// the account. Split from GPUWorkflowTests.swift for SwiftLint's file length cap.

import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Pod credentials travel as RunPod secrets")
struct GPUSecretsTests {
    private static let livePod = #"{"id":"p1","name":"ConceptStudio-x","status":"EXITED","cost":0,"gpu":{"count":1},"#
        + #""env":{"PODAGENT_TOKEN":"{{ RUNPOD_SECRET_conceptstudio_agent_live }}"}}"#

    @Test
    func placeholdersNameTheirSecretAndLiteralsDoNot() throws {
        #expect(PodSecrets.reference("conceptstudio_hf_token") == "{{ RUNPOD_SECRET_conceptstudio_hf_token }}")
        #expect(PodSecrets.referencedName(in: "{{ RUNPOD_SECRET_conceptstudio_hf_token }}") == "conceptstudio_hf_token")
        #expect(PodSecrets.referencedName(in: "{{RUNPOD_SECRET_x}}") == "x")
        #expect(PodSecrets.referencedName(in: "hf_abcdef") == nil)
        #expect(PodSecrets.referencedName(in: "{{ RUNPOD_SECRET_ }}") == nil)
        #expect(PodSecrets.referencedName(in: "{{ OTHER_x }}") == nil)
        let name = try PodSecrets.newAgentSecretName()
        #expect(name.hasPrefix(PodSecrets.agentPrefix) && name.count == PodSecrets.agentPrefix.count + 24)
        #expect(try PodSecrets.newAgentSecretName() != name)
    }

    @Test
    func storingASecretCreatesItWhenAbsentAndRotatesItWhenPresent() async throws {
        let transport = UnreachableAgentTransport()
        let provider = RunPodProvider(key: "runpod-key", transport: transport)
        try await provider.storeSecret(name: PodSecrets.hubTokenName, value: "hf-one")
        try await provider.storeSecret(name: PodSecrets.hubTokenName, value: "hf-two")
        #expect(await transport.secretRequests == [
            "GET account/secrets?name=conceptstudio_hf_token", "POST account/secrets",
            "GET account/secrets?name=conceptstudio_hf_token", "PATCH account/secrets/sec-1",
        ])
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == "hf-two")
    }

    @Test
    func deletingResolvesTheNameAndIgnoresAMissingSecret() async throws {
        let transport = UnreachableAgentTransport()
        await transport.seedSecret("conceptstudio_agent_gone", value: "a")
        let provider = RunPodProvider(key: "runpod-key", transport: transport)
        try await provider.deleteSecret(name: "conceptstudio_agent_gone")
        try await provider.deleteSecret(name: "conceptstudio_agent_never")
        #expect(await transport.deletedSecrets == ["conceptstudio_agent_gone"])
        #expect(await transport.secretRequests.filter { $0.hasPrefix("DELETE") } == ["DELETE account/secrets/sec-1"])
    }

    @Test
    func orphanedSecretsAreThisAppsAgentSecretsThatNoPodReferences() async throws {
        let transport = UnreachableAgentTransport()
        await transport.seedSecret("conceptstudio_agent_live", value: "a")
        await transport.seedSecret("conceptstudio_agent_stale", value: "b")
        await transport.seedSecret(PodSecrets.hubTokenName, value: "c")
        await transport.seedSecret("hf_token", value: "someone else's")
        await transport.list([Self.livePod, #"{"id":"p2","name":"other","status":"RUNNING","env":{"X":"literal"}}"#])
        let provider = RunPodProvider(key: "runpod-key", transport: transport)
        #expect(try await provider.orphanedSecrets(prefix: PodSecrets.agentPrefix) == ["conceptstudio_agent_stale"])
    }

    @MainActor @Test
    func rentingStoresBothTokensAsSecretsAndPassesOnlyReferences() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-write", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        #expect(workspace.hasRunningPod)
        let body = try #require(await transport.createBodies.first)
        let env = try #require(body["env"]?.objectValue)
        #expect(env["HF_TOKEN"]?.stringValue == PodSecrets.reference(PodSecrets.hubTokenName))
        let agentReference = try #require(env["PODAGENT_TOKEN"]?.stringValue)
        let agentSecret = try #require(PodSecrets.referencedName(in: agentReference))
        #expect(agentSecret.hasPrefix(PodSecrets.agentPrefix))
        #expect(workspace.agentToken.count == 64)
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == "hub-write")
        #expect(await transport.secretValue(agentSecret) == workspace.agentToken)
        let serialized = try #require(String(data: JSONValue.object(body).pythonDumpsData(), encoding: .utf8))
        #expect(!serialized.contains("hub-write") && !serialized.contains(workspace.agentToken))
        // The record remembers the secret so removing the pod can delete it.
        let record = try #require(preferences.data(forKey: GPUWorkspace.activePodKey))
        #expect(try JSONDecoder().decode(SavedPod.self, from: record).agentSecret == agentSecret)
        await workspace.stopEverything()
        await workspace.terminate()
        #expect(workspace.pod == nil)
        #expect(await transport.deletedSecrets == [agentSecret])
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == "hub-write")
    }

    @MainActor @Test
    func withoutAHubTokenNoHubSecretIsWrittenAndTheVariableIsAbsent() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        let env = try #require(await transport.createBodies.first?["env"]?.objectValue)
        #expect(env["HF_TOKEN"] == nil)
        #expect(env["PODAGENT_TOKEN"]?.stringValue?.hasPrefix("{{ RUNPOD_SECRET_conceptstudio_agent_") == true)
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == nil)
        await workspace.stopEverything()
    }

    @MainActor @Test
    func aRentalThatFailsRemovesItsAgentSecretAndKeepsTheHubSecret() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        await transport.failCreate(true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "hub-write", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        #expect(workspace.pod == nil)
        let deleted = await transport.deletedSecrets
        #expect(deleted.count == 1 && deleted.first?.hasPrefix(PodSecrets.agentPrefix) == true)
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == "hub-write")
    }

    @MainActor @Test
    func launchRemovesAgentSecretsThatNoPodReferences() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        await transport.seedSecret("conceptstudio_agent_live", value: "a")
        await transport.seedSecret("conceptstudio_agent_stale", value: "b")
        await transport.seedSecret(PodSecrets.hubTokenName, value: "c")
        await transport.list([Self.livePod])
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "provider-only", hubToken: "", imageName: "test")
        var deleted: [String] = []
        for _ in 0 ..< 200 {
            deleted = await transport.deletedSecrets
            if !deleted.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(deleted == ["conceptstudio_agent_stale"])
        #expect(await transport.secretValue("conceptstudio_agent_live") == "a")
        #expect(await transport.secretValue(PodSecrets.hubTokenName) == "c")
    }
}
