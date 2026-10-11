@testable import ConceptCore
import Foundation
import Synchronization
import Testing

private actor PartialCaptionLog {
    private(set) var texts: [String] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func append(_ text: String) {
        texts.append(text)
        if !text.isEmpty { waiter?.resume(); waiter = nil }
    }

    func waitForText() async {
        if texts.contains(where: { !$0.isEmpty }) { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

extension ChatGPTModelClientTests {
    @Test func realURLSessionDeltasReachRunnerBeforeAnyCaptionIsSaved() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTStreamingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = Self.offlineClient(token: "offline-full-stream", session: session)
        let workspace = try Workspace()
        let sink = try workspace.sink
        let log = PartialCaptionLog()
        let runner = try Runner(job: Fixtures.job(), captioner: ResolvedEndpoint(client: client))
        let summary = try await runner.run(
            source: workspace.source, sink: sink, only: ["solo.png"],
            onPartialCaption: { id, text in
                if !text.isEmpty {
                    #expect(id == "solo.png")
                    do { #expect(try await !sink.exists(id)) } catch { Issue.record(error) }
                }
                await log.append(text)
            }
        )
        let texts = await log.texts
        #expect(texts.contains { $0.contains("NORA7") })
        #expect(texts.last == "")
        #expect(summary.outcomes.first?.status == .written)
        #expect(try workspace.text("solo.txt") == "NORA7 wears a jacket.")
    }

    @Test func failedStreamClearsPreviewAndNeverWritesPartialText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTStreamingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = Self.offlineClient(token: "offline-failed-stream", session: session)
        let workspace = try Workspace()
        let log = PartialCaptionLog()
        let runner = try Runner(job: Fixtures.job(), captioner: ResolvedEndpoint(client: client))
        let summary = try await runner.run(
            source: workspace.source, sink: workspace.sink, only: ["solo.png"],
            onPartialCaption: { _, text in await log.append(text) }
        )
        let texts = await log.texts
        #expect(texts.contains { !$0.isEmpty })
        #expect(texts.last == "")
        #expect(summary.outcomes.first?.status == .failed)
        #expect(!workspace.exists("solo.txt"))
        #expect(!workspace.exists("solo.json"))
    }

    @Test func triggerRetryClearsTheRejectedPreviewBeforeNextActualDelta() async throws {
        let calls = Mutex(0)
        let wire = ChatGPTStreamWire { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            let caption = call == 1 ? "Unmapped person." : "NORA7, a geometric figure."
            let text = "{\"caption\":\"\(caption)\"}"
            let item: JSONValue = .object([
                "type": .string("message"), "role": .string("assistant"), "status": .string("completed"),
                "content": .array([.object(["type": .string("output_text"), "text": .string(text)])]),
            ])
            return ChatGPTWire.response(ChatGPTWire.event(.object([
                "type": .string("response.output_text.delta"), "delta": .string(text),
            ])) + ChatGPTWire.event(ChatGPTWire.completed(output: [item])))
        }
        let client = ChatGPTModelClient(model: "fixture", accessToken: { "fixture" }, transport: wire)
        let workspace = try Workspace()
        let log = PartialCaptionLog()
        let runner = try Runner(job: Fixtures.job(), captioner: ResolvedEndpoint(client: client))
        let summary = try await runner.run(
            source: workspace.source, sink: workspace.sink, only: ["solo.png"],
            onPartialCaption: { _, text in await log.append(text) }
        )
        #expect(await log.texts == ["", "Unmapped person.", "", "NORA7, a geometric figure.", ""])
        #expect(summary.outcomes.first?.record?.requests == 2)
        #expect(summary.outcomes.first?.status == .written)
    }
}

extension ChatGPTModelClientTests {
    @Test func cancellingRunnerSettlesAndClearsAnUnfinishedRealDelta() async throws {
        let log = PartialCaptionLog()
        let cancelled = Mutex(false)
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let wire = ChatGPTStreamWire { _ in
            for line in ChatGPTWire.event(.object([
                "type": .string("response.output_text.delta"),
                "delta": .string("{\"caption\":\"NORA7 is still being written"),
            ])) {
                continuation.yield(Data((line + "\n").utf8))
            }
            return HTTPStreamResponse(status: 200, body: body, cancel: {
                cancelled.withLock { $0 = true }
                continuation.finish()
            })
        }
        let client = ChatGPTModelClient(model: "fixture", accessToken: { "fixture" }, transport: wire)
        let workspace = try Workspace()
        let runner = try Runner(job: Fixtures.job(), captioner: ResolvedEndpoint(client: client))
        let run = Task {
            try await runner.run(
                source: workspace.source, sink: workspace.sink, only: ["solo.png"],
                onPartialCaption: { _, text in await log.append(text) }
            )
        }
        await log.waitForText()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(cancelled.withLock { $0 })
        #expect(await log.texts.last == "")
        #expect(!workspace.exists("solo.txt"))
        #expect(!workspace.exists("solo.json"))
    }
}
