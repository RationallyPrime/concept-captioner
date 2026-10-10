// How the runner drives a run: streaming, settling on source errors and cancellation, and the
// `only` hint to the source. The flows themselves are in RunnerTests.swift, whose helpers this
// file shares.

import ConceptCore
import Foundation
import Synchronization
import Testing

// MARK: - Helpers

private func goodReply(_ request: FakeModelClient.Request) throws -> FakeModelClient.Reply {
    try FakeModelClient.Reply(encoding: Caption(caption: Fixtures.goodCaption(for: request.instructions)))
}

/// A fixed list of samples, with only the protocol's required `samples()`: exercises the
/// default `samples(only:)`.
private struct ListSource: ImageSource {
    let name = "list"
    let items: [Sample]

    func samples() -> AsyncThrowingStream<Sample, any Error> {
        AsyncThrowingStream { continuation in
            for sample in items {
                continuation.yield(sample)
            }
            continuation.finish()
        }
    }

    func count() async throws -> Int {
        items.count
    }

    func sampleIDs() async throws -> [String] {
        items.map(\.sampleID)
    }
}

/// Wraps a folder source, records every `only` hint it is given and, when `honoursHint` is
/// false, ignores it (yields the whole folder) the way a naive source might.
private struct SpySource: ImageSource {
    final class Hints: Sendable {
        let seen = Mutex<[Set<String>?]>([])
    }

    let name = "spy"
    let base: LocalFolderSource
    let honoursHint: Bool
    let hints = Hints()

    func samples() -> AsyncThrowingStream<Sample, any Error> {
        base.samples()
    }

    func samples(only ids: Set<String>?) -> AsyncThrowingStream<Sample, any Error> {
        hints.seen.withLock { $0.append(ids) }
        return honoursHint ? base.samples(only: ids) : base.samples()
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func sampleIDs() async throws -> [String] {
        try await base.sampleIDs()
    }

    var hintsSeen: [Set<String>?] {
        hints.seen.withLock { $0 }
    }
}

/// Forwards to a SidecarSink and counts `finalize()` calls.
private struct CountingSink: CaptionSink {
    private actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    let name = "counting"
    let base: SidecarSink
    private let finalizes = Counter()

    init(_ base: SidecarSink) {
        self.base = base
    }

    func exists(_ sampleID: String) async throws -> Bool {
        try await base.exists(sampleID)
    }

    func record(_ sampleID: String) async throws -> ResponseRecord? {
        try await base.record(sampleID)
    }

    func write(_ sampleID: String, caption: String?, record: ResponseRecord) async throws {
        try await base.write(sampleID, caption: caption, record: record)
    }

    func finalize() async throws -> JSONObject {
        await finalizes.increment()
        return try await base.finalize()
    }

    var finalizeCalls: Int {
        get async { await finalizes.value }
    }
}

// MARK: - Driving

@Suite("runner stream")
struct RunnerStreamTests {
    // MARK: Streaming and cancellation

    @Test("run callbacks arrive before the run completes and preserve summary order")
    func runReportsOutcomesDuringTheRun() async throws {
        let space = try Workspace()
        let release = Rendezvous(party: 2)
        let observed = Rendezvous(party: 2)
        let seen = Mutex<[Outcome]>([])
        let captioner = FakeModelClient { request in
            await release.arrive()
            return try goodReply(request)
        }
        let runner = try runner(captioner: captioner)
        let source = try space.source
        let sink = try CountingSink(space.sink)
        let run = Task {
            try await runner.run(source: source, sink: sink, only: ["solo.png", "unmapped.png"]) { outcome in
                seen.withLock { $0.append(outcome) }
                if outcome.sampleID == "unmapped.png" { await observed.arrive() }
            }
        }
        await observed.arrive()
        #expect(seen.withLock { $0.map(\.sampleID) } == ["unmapped.png"])
        #expect(await sink.finalizeCalls == 0)
        await release.arrive()
        let summary = try await run.value
        #expect(summary.outcomes == seen.withLock { $0 })
        #expect(await sink.finalizeCalls == 1)
    }

    @Test("cancelled callback run drains a provider that ignores cancellation before returning")
    func callbackRunWaitsForUncooperativeProvider() async throws {
        let space = try Workspace()
        let entered = Rendezvous(party: 2)
        let release = Rendezvous(party: 2)
        let seen = Mutex<[Outcome]>([])
        let captioner = FakeModelClient { request in
            await entered.arrive()
            await release.arrive() // intentionally ignores task cancellation
            return try goodReply(request)
        }
        let runner = try runner(captioner: captioner)
        let source = try space.source
        let sink = try CountingSink(space.sink)
        let run = Task {
            try await runner.run(source: source, sink: sink, only: ["solo.png"]) { outcome in
                seen.withLock { $0.append(outcome) }
            }
        }
        await entered.arrive()
        run.cancel()
        #expect(await captioner.inFlight == 1)
        await release.arrive()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(await captioner.inFlight == 0, "no child remains to write after the caller releases the folder")
        #expect(await sink.finalizeCalls == 0)
        #expect(seen.withLock { $0.map(\.status) } == [.written], "the draining child's write and callback settled")
        #expect(space.exists("solo.txt") && space.exists("solo.json"))
    }

    @Test func streamYieldsEveryOutcomeAndOnlyFilters() async throws {
        let space = try Workspace()
        let runner = try runner(captioner: Fixtures.captionerOK())
        let stream = try runner.stream(source: space.source, sink: space.sink, only: ["solo.png", "unmapped.png"])
        var seen: [String: SampleStatus] = [:]
        for try await outcome in stream {
            seen[outcome.sampleID] = outcome.status
        }
        #expect(seen == ["solo.png": .written, "unmapped.png": .needsMapping])
        #expect(!space.exists("pair.json"))
    }

    @Test("a source error lets the in-flight samples settle, yields them, then finishes with the error")
    func sourceErrorFinishesTheStreamWithThatError() async throws {
        let space = try Workspace()
        // Slow enough that solo.png is still at the provider when the source fails right after it.
        let captioner = slowCaptioner(.milliseconds(50))
        let runner = try runner(captioner: captioner)
        let solo = Sample(sampleID: "solo.png", data: Fixtures.syntheticPNG(seed: 1), suffix: ".png")
        let source = FailingSource(before: [solo], error: ConfigurationError("disk gone"))
        let sink = try CountingSink(space.sink)

        var outcomes: [Outcome] = []
        await #expect(throws: ConfigurationError("disk gone")) {
            for try await outcome in runner.stream(source: source, sink: sink) {
                outcomes.append(outcome)
            }
        }
        #expect(outcomes.map(\.sampleID) == ["solo.png"], "the in-flight sample is reported")
        #expect(outcomes.first?.status == .written, "and it ran to completion, not cancelled")
        #expect(try space.text("solo.txt").contains("NORA7"))
        #expect(await captioner.requests.count == 1)

        // run(): the same error, after the (now skipped) sample settles, and no finalize.
        await #expect(throws: ConfigurationError("disk gone")) {
            _ = try await runner.run(source: source, sink: sink)
        }
        #expect(await sink.finalizeCalls == 0)
        #expect(await captioner.requests.count == 1)
    }

    @Test("cancelling run() settles the in-flight sample, throws CancellationError and never finalizes")
    func cancellingRunThrowsWithoutFinalizing() async throws {
        let space = try Workspace()
        let gate = Rendezvous(party: 2)
        let captioner = FakeModelClient { request in
            await gate.arrive() // the test cancels once we are here
            try await Task.sleep(for: .seconds(30)) // throws CancellationError promptly
            return try goodReply(request)
        }
        let runner = try runner(captioner: captioner)
        let source = try space.source
        let sink = try CountingSink(space.sink)

        let run = Task { try await runner.run(source: source, sink: sink, only: ["solo.png"]) }
        await gate.arrive()
        run.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
        #expect(await sink.finalizeCalls == 0, "a cancelled run must not push or materialize")
        #expect(await captioner.inFlight == 0, "the in-flight sample settled before run() threw")
        #expect(!space.exists("solo.json") && !space.exists("solo.txt"))
    }

    @Test("cancelling a stream() consumer ends the stream early without an error")
    func cancellingStreamEndsEarly() async throws {
        let space = try Workspace()
        let gate = Rendezvous(party: 2)
        let captioner = FakeModelClient { request in
            await gate.arrive()
            try await Task.sleep(for: .seconds(30))
            return try goodReply(request)
        }
        let runner = try runner(captioner: captioner)
        let source = try space.source
        let sink = try space.sink

        let consumer = Task { () throws -> (outcomes: [Outcome], cancelled: Bool) in
            var outcomes: [Outcome] = []
            for try await outcome in runner.stream(source: source, sink: sink, only: ["solo.png"]) {
                outcomes.append(outcome)
            }
            return (outcomes, Task.isCancelled)
        }
        await gate.arrive()
        consumer.cancel()
        let result = try await consumer.value
        #expect(result.outcomes.isEmpty && result.cancelled, "the loop ends normally; the flag tells")
    }

    // MARK: The `only` hint

    @Test("run passes `only` to the source, and still filters when the source ignores it")
    func onlyIsPassedToTheSourceAndEnforced() async throws {
        let space = try Workspace()
        let honouring = try SpySource(base: space.source, honoursHint: true)
        let runner = try runner(captioner: Fixtures.captionerOK())
        let summary = try await runner.run(source: honouring, sink: space.sink, only: ["solo.png"])
        #expect(honouring.hintsSeen == [["solo.png"]])
        #expect(statuses(summary) == ["solo.png": .written])

        let ignoring = try SpySource(base: space.source, honoursHint: false)
        let rerun = try await runner.run(source: ignoring, sink: space.sink, only: ["unmapped.png"])
        #expect(ignoring.hintsSeen == [["unmapped.png"]])
        #expect(statuses(rerun) == ["unmapped.png": .needsMapping], "pair.png never reaches the pipeline")
        #expect(!space.exists("pair.json"))

        let everything = try await runner.run(source: honouring, sink: space.sink)
        #expect(honouring.hintsSeen == [["solo.png"], nil])
        #expect(everything.counts() == [.skipped: 1, .written: 1, .needsMapping: 1])
    }

    @Test("the default samples(only:) is samples() unchanged")
    func defaultOnlyHintIsIgnored() async throws {
        let solo = Sample(sampleID: "solo.png", data: Data([1]), suffix: ".png")
        let pair = Sample(sampleID: "pair.png", data: Data([2]), suffix: ".png")
        let source = ListSource(items: [solo, pair])
        let hinted = try await source.samples(only: ["solo.png"]).reduce(into: [Sample]()) { $0.append($1) }
        #expect(hinted == [solo, pair])
    }
}
