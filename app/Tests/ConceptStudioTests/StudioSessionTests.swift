import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("studio offline actions")
@MainActor
struct StudioSessionTests {
    @Test func startupRecoveryOnlyRoutesKnownRunningMetadata() throws {
        #expect(!StudioSession.startupNeedsPodRecovery(nil))
        for status in ["RUNNING", "STARTING", "EXITED", "ERROR", "TERMINATED"] {
            let saved = SavedPod(
                pod: RentedPod(id: "test-pod", status: status, cost: 1, gpu: .init(count: 1)),
                started: Date(),
                hourlyRate: 1,
                budget: 10,
                trainer: "aitoolkit",
                runID: "",
                outputRepo: ""
            )
            let data = try JSONEncoder().encode(saved)
            #expect(StudioSession.startupNeedsPodRecovery(data) == ["RUNNING", "STARTING"].contains(status))
        }
    }

    @Test func demoCompletesNineScreensWithoutCredentials() async throws {
        let session = StudioSession()
        session.useDemo()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.demoMode)
        #expect(session.project?.images.count == 3)
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.datasetCritique()
        await session.task?.value
        #expect(!session.datasetAdvice.isEmpty)
        session.proposeMappings(useModel: true)
        await session.task?.value
        #expect(session.mappingProposals.count == 3)
        for (id, mapping) in session.mappingProposals {
            session.confirmMapping(id: id, mapping: mapping)
        }
        session.caption()
        await session.task?.value
        #expect(session.project?.images.allSatisfy { $0.status == .written } == true)
        let id = try #require(session.project?.images.first?.id)
        session.saveCaption(id: id, text: "NORA7 final user caption.", final: true)
        await session.task?.value
        session.compare(id: id, model: "another-model", kind: "openai")
        await session.task?.value
        #expect(!session.comparison.isEmpty)
        #expect(session.project?.images.first?.caption == "NORA7 final user caption.")
        session.caption(only: [id], overwrite: true)
        await session.task?.value
        #expect(session.project?.images.first?.isFinal == true)
        session.publish()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.message.contains("No upload"))
        session.configureGPU()
        await session.gpu.refreshOffers()
        session.gpu.gpuCount = 2
        await session.gpu.rent()
        #expect(session.gpu.hasRunningPod)
        #expect(session.gpu.triggerWords == "NORA7")
        #expect(session.gpu.profile == "flux-image")
        await session.gpu.train(datasetRepo: session.repoID)
        #expect(!session.gpu.runID.isEmpty)
        for _ in 0 ..< 10 {
            await session.gpu.refresh()
        }
        #expect(!session.gpu.points.isEmpty)
        #expect(session.gpu.trainingState == "exited")
        session.gpu.outputRepo = "demo/result"
        await session.gpu.publishResult()
        #expect(session.gpu.message.contains("uploaded"))
        for _ in 0 ..< 8 {
            session.next()
        }
        #expect(session.step == .monitor)
        await session.closeProject()
        #expect(session.project == nil)
        #expect(!session.gpu.hasRunningPod)
    }

    @Test func cancellationSettlesBeforeProjectClose() async throws {
        let session = StudioSession()
        session.useDemo()
        await session.task?.value
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.caption()
        await session.closeProject()
        #expect(!session.busy)
        #expect(session.task == nil)
        #expect(session.project == nil)
    }

    @Test func ownedPodCaptionKeyIsTrustedWithoutEnteringTheJob() async throws {
        let session = StudioSession()
        session.useDemo()
        await session.task?.value
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await session.gpu.refreshOffers()
        await session.gpu.rent()
        session.usePodCaptionServer()
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.usingPodCaptioner)
        // Keep the fake GPU backend; inspect real resolver construction without sending HTTP or reading Keychain.
        session.demoMode = false
        let endpoint = try session.endpoint()
        let client = try #require(endpoint.client as? OpenAICompatibleClient)
        #expect(client.apiKey == session.gpu.agentToken)
        #expect(client.baseURL == session.gpu.captionEndpoint)
        let job = try session.jobForCaptioning()
        #expect(job.endpoints?.captioner.baseURL == session.gpu.captionEndpoint?.absoluteString)
        #expect(!job.jsonValue.pythonDumps().contains(session.gpu.agentToken))
        await session.gpu.stopEverything()
        #expect(throws: StudioError.self) { try session.endpoint() }
        await session.closeProject()
    }

    @Test func sharedRequestSettingsAndThinkingSurvivePreparation() async throws {
        let session = StudioSession()
        session.project = try await DemoProject.create()
        let directory = try #require(session.project?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        session.project?.job.endpoints = try Endpoints(captioner: EndpointSpec(
            kind: "openrouter",
            model: "m",
            settings: ["temperature": .double(0.2)]
        ))
        session.modelThinking = .low
        session.criticThinking = .high
        let job = try session.jobForCaptioning()
        #expect(job.endpoints?.captioner.settings["temperature"] == .double(0.2))
        #expect(job.captionerThinking == .low)
        #expect(job.criticThinking == .high)
        session.project?.job.skill = "/unselected/skill"
        #expect(throws: StudioError.self) { try session.selectedSkill() }
    }
}
