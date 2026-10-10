// Runner flows on FakeModelClient, mirroring tests/test_runner.py. See docs/CORE-SPEC.md, module `runner`.

import ConceptCore
import Foundation
import Testing

// MARK: - Shared helpers (internal: RunnerStreamTests.swift uses them too)

/// A fresh images folder (solo, pair, unmapped) and an output folder for sidecars.
struct Workspace {
    let images: URL
    let out: URL

    init() throws {
        images = try Fixtures.imagesFolder()
        out = try Fixtures.tempDirectory().appendingPathComponent("out")
    }

    var source: LocalFolderSource {
        get throws { try LocalFolderSource(directory: images) }
    }

    var sink: SidecarSink {
        get throws { try SidecarSink(directory: out) }
    }

    func text(_ name: String) throws -> String {
        try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)
    }

    func record(_ name: String) throws -> ResponseRecord {
        try ResponseRecord(json: JSONValue(parsing: Data(contentsOf: out.appendingPathComponent(name))))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path)
    }
}

func runner(
    captioner: FakeModelClient,
    critic: FakeModelClient? = nil,
    concurrency: Int? = nil,
    job: Job? = nil
) throws -> Runner {
    try Runner(
        job: job ?? Fixtures.job(),
        captioner: Fixtures.endpoint(captioner),
        critic: critic.map { Fixtures.endpoint($0) },
        concurrency: concurrency
    )
}

func statuses(_ summary: RunSummary) -> [String: SampleStatus] {
    Dictionary(uniqueKeysWithValues: summary.outcomes.map { ($0.sampleID, $0.status) })
}

private func caption(_ body: String) throws -> FakeModelClient.Reply {
    try FakeModelClient.Reply(encoding: Caption(caption: Fixtures.h3(body)))
}

private func critique(_ critique: Critique) throws -> FakeModelClient.Reply {
    try FakeModelClient.Reply(encoding: critique)
}

/// A captioner that answers well, after `delay`, so in-flight counts overlap measurably.
func slowCaptioner(_ delay: Duration) -> FakeModelClient {
    FakeModelClient { request in
        try await Task.sleep(for: delay)
        return try FakeModelClient.Reply(encoding: Caption(caption: Fixtures.goodCaption(for: request.instructions)))
    }
}

/// A source whose stream fails after yielding `before` samples.
struct FailingSource: ImageSource {
    let name = "failing"
    let before: [Sample]
    let error: any Error

    func samples() -> AsyncThrowingStream<Sample, any Error> {
        AsyncThrowingStream { continuation in
            for sample in before {
                continuation.yield(sample)
            }
            continuation.finish(throwing: error)
        }
    }

    func count() async throws -> Int {
        before.count
    }

    func sampleIDs() async throws -> [String] {
        before.map(\.sampleID)
    }
}

/// Everyone who arrives waits until `party` callers have arrived, then all continue.
actor Rendezvous {
    private let party: Int
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(party: Int) {
        self.party = party
    }

    func arrive() async {
        arrived += 1
        guard arrived < party else {
            for waiter in waiting {
                waiter.resume()
            }
            waiting.removeAll()
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}

// MARK: - Flows

@Suite("runner")
struct RunnerTests {
    // MARK: Construction

    @Test func initResolvesDefaultsFromTheJob() throws {
        let captioner = Fixtures.captionerOK()
        let runner = try Runner(job: Fixtures.job(), captioner: Fixtures.endpoint(captioner, concurrency: 7))
        #expect(runner.skill.name == Skills.defaultSkillName)
        #expect(runner.profileName == "h3-still")
        #expect(runner.profileText.contains("[Shot 1]"))
        #expect(runner.concurrency == 7)
        #expect(runner.critic == nil)
        #expect(runner.overwrite == false)

        let explicit = try Runner(
            job: Fixtures.job(),
            captioner: Fixtures.endpoint(captioner),
            profile: "plain",
            concurrency: 2,
            overwrite: true
        )
        #expect(explicit.profileName == "plain")
        #expect(!explicit.profileText.contains("[Shot 1]"))
        #expect(explicit.concurrency == 2)
        #expect(explicit.overwrite)
    }

    @Test func initRejectsUnknownProfileAndBadConcurrency() throws {
        let endpoint = Fixtures.endpoint(Fixtures.captionerOK())
        #expect(throws: ConfigurationError.self) {
            try Runner(job: Fixtures.job(), captioner: endpoint, profile: "nope")
        }
        #expect(throws: ConfigurationError.self) {
            try Runner(job: Fixtures.job(), captioner: endpoint, concurrency: 0)
        }
    }

    // MARK: test_happy_path_with_critic_writes_mapped_samples

    @Test func happyPathWithCriticWritesMappedSamples() async throws {
        let space = try Workspace()
        let captioner = Fixtures.captionerOK(model: "cap-1")
        let critic = Fixtures.criticOK(model: "crit-1")
        var runner = try runner(captioner: captioner, critic: critic)

        let summary = try await runner.run(source: space.source, sink: space.sink)
        #expect(summary.counts() == [.written: 2, .needsMapping: 1])
        #expect(summary.sink == ["directory": .string(space.out.standardizedFileURL.path)])
        #expect(summary.elapsed >= 0)

        // The image is attached exactly once to every call, captioner and critic alike.
        let captionerRequests = await captioner.requests
        let criticRequests = await critic.requests
        #expect(captionerRequests.count == 2)
        #expect(criticRequests.count == 2)
        #expect((captionerRequests + criticRequests).allSatisfy { $0.images.count == 1 })
        #expect(captionerRequests.allSatisfy { $0.output.name == Caption.schemaName })
        #expect(criticRequests.allSatisfy { $0.output.name == Critique.schemaName })
        #expect(captionerRequests.allSatisfy { $0.messages.first?.content.first == .text(Prompt.userTurn) })
        #expect(criticRequests.allSatisfy { $0.lastText.hasPrefix("Review this proposed caption") })

        #expect(try space.text("solo.txt").contains("NORA7"))
        let record = try space.record("pair.json")
        #expect(record.status == .written)
        #expect(record.source == "model")
        #expect(record.skill == Skills.defaultSkillName)
        #expect(record.profile == "h3-still")
        #expect(record.captioner == ModelNames(requested: "cap-1", served: "cap-1"))
        #expect(record.critic?.served == "crit-1")
        #expect(record.critique?.approved == true)
        #expect(record.attempts == 1)
        #expect(record.requests == 2)
        #expect(try space.text("pair.txt").contains("IVAN9"))
        #expect(!space.exists("unmapped.json"))

        let unmapped = try #require(summary.outcomes.first { $0.sampleID == "unmapped.png" })
        #expect(unmapped.notes == ["no subject mapping"])
        #expect(unmapped.record == nil)
        let written = try #require(summary.outcomes.first { $0.sampleID == "pair.png" })
        #expect(written.caption?.contains("IVAN9") == true)
        #expect(written.notes == ["looks right"])
        #expect(written.record == record)

        // Rerun: everything already captioned is skipped without a model call.
        let rerun = try await runner.run(source: space.source, sink: space.sink)
        #expect(rerun.counts() == [.skipped: 2, .needsMapping: 1])
        #expect(await captioner.requests.count == 2)
        #expect(await critic.requests.count == 2)
        let skipped = try #require(rerun.outcomes.first { $0.sampleID == "pair.png" })
        #expect(skipped.notes.isEmpty)
        #expect(skipped.record == record)

        // A human-final caption survives overwrite; the model-sourced one is redone.
        let pairJSON = space.out.appendingPathComponent("pair.json")
        var json = try #require(JSONValue(parsing: Data(contentsOf: pairJSON)).objectValue)
        json["source"] = .string("human")
        try JSONValue.object(json).pythonDumpsData().write(to: pairJSON)
        runner.overwrite = true
        let third = try await runner.run(source: space.source, sink: space.sink, only: ["pair.png", "solo.png"])
        #expect(statuses(third) == ["pair.png": .skipped, "solo.png": .written])
        let humanFinal = try #require(third.outcomes.first { $0.sampleID == "pair.png" })
        #expect(humanFinal.notes == ["human-final"])
        #expect(humanFinal.record?.source == "human")
        #expect(await captioner.requests.count == 3)
        #expect(try space.record("pair.json").source == "human")
    }

    @Test("a hand-edited human record with an unexpected shape is honoured under overwrite")
    func handEditedHumanRecordSurvivesOverwrite() async throws {
        let space = try Workspace()
        let sink = try space.sink
        // What a user writes by hand: no sample_id, an invented status, a quoted number, a bare
        // caption object. Python's runner reads `source` off the raw dict and skips it as human-final.
        let recordText = #"{"source": "human", "status": "approved", "attempts": "1", "#
            + #""caption": {"caption": "A photo of IVAN9, by hand."}}"#
        let recordURL = space.out.appendingPathComponent("pair.json")
        let captionURL = space.out.appendingPathComponent("pair.txt")
        try Data(recordText.utf8).write(to: recordURL)
        try Data("A photo of IVAN9, by hand.".utf8).write(to: captionURL)

        let captioner = Fixtures.captionerOK(model: "cap-1")
        var runner = try runner(captioner: captioner, critic: Fixtures.criticOK(model: "crit-1"))
        runner.overwrite = true
        let summary = try await runner.run(source: space.source, sink: sink, only: ["pair.png", "solo.png"])

        #expect(statuses(summary) == ["pair.png": .skipped, "solo.png": .written])
        let humanFinal = try #require(summary.outcomes.first { $0.sampleID == "pair.png" })
        #expect(humanFinal.notes == ["human-final"])
        #expect(humanFinal.record?.isHumanFinal == true)
        #expect(humanFinal.record?.sampleID == "pair.png")
        #expect(humanFinal.record?.status == .written && humanFinal.record?.attempts == 0)
        #expect(await captioner.requests.count == 1, "only solo.png reaches the model")
        #expect(try Data(contentsOf: recordURL) == Data(recordText.utf8), "the human record is untouched")
        #expect(try space.text("pair.txt") == "A photo of IVAN9, by hand.")
    }

    // MARK: test_trigger_retry_and_critic_feedback

    @Test func triggerRetryThenCriticFeedback() async throws {
        let space = try Workspace()
        let captioner = FakeModelClient { request in
            if request.messages.count == 1 {
                return try caption("A photograph of a woman by a window.") // no trigger
            }
            if request.lastText.hasPrefix("Validation feedback:\nFix the caption:") {
                return try caption("A photograph of NORA7, a woman, by a window.")
            }
            // Reviewer feedback arrives as a plain user turn carrying the notes.
            #expect(request.lastText.contains("Reviewer notes"))
            return try caption("A photograph of NORA7, a woman, by a window, in a red coat.")
        }
        let critic = FakeModelClient { request in
            if request.lastText.contains("red coat") {
                return try critique(Critique(approved: true))
            }
            return try critique(Critique(approved: false, notes: ["the red coat is not described"]))
        }
        let runner = try runner(captioner: captioner, critic: critic)

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(summary.outcomes.count == 1)
        #expect(outcome.status == .written)
        #expect(outcome.caption?.contains("red coat") == true)
        #expect(outcome.notes.isEmpty)
        #expect(await captioner.requests.count == 3) // trigger retry + one feedback round
        #expect(await critic.requests.count == 2)
        let record = try #require(outcome.record)
        #expect(record.attempts == 2)
        #expect(record.requests == 5)
        #expect(record.critique == Critique(approved: true))
        #expect(record.caption?.caption.contains("red coat") == true)
        #expect(try space.record("solo.json") == record)
        #expect(try space.text("solo.txt").contains("red coat"))

        // The conversation: the retry turn names the trigger problem, the feedback round carries
        // the whole history plus the reviewer notes, and the image appears exactly once each time.
        let requests = await captioner.requests
        let retry = requests[1]
        #expect(retry.messages.count == 3)
        #expect(retry.messages[1].role == .assistant)
        let problem = "the mapped trigger NORA7 must appear exactly in the caption"
        // Native output carries no tool name, so pydantic-ai prefixes the validator's text.
        #expect(retry.lastText.hasPrefix("Validation feedback:\nFix the caption: \(problem)"))
        #expect(retry.lastText.hasSuffix("Fix the errors and try again."))
        let feedback = requests[2]
        #expect(feedback.messages.count == 5)
        #expect(feedback.messages.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(feedback.lastText == "Reviewer notes:\n- the red coat is not described")
        #expect(requests.allSatisfy { $0.images.count == 1 })
        #expect(requests.allSatisfy { $0.instructions == requests[0].instructions })
    }

    @Test func criticWithoutNotesFeedsBackNotApproved() async throws {
        let space = try Workspace()
        let captioner = Fixtures.captionerOK()
        let critic = FakeModelClient.critique(Critique(approved: false)) // no notes at all
        let runner = try runner(captioner: captioner, critic: critic)
        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        #expect(summary.outcomes.first?.status == .rejected)
        #expect(summary.outcomes.first?.notes == [])
        let feedback = await captioner.requests[1]
        #expect(feedback.lastText == "Reviewer notes:\n- not approved")
    }

    // MARK: test_unusable_and_rejected_write_records_but_no_caption

    @Test func unusableWritesTheRecordButNoCaption() async throws {
        let space = try Workspace()
        let captioner = FakeModelClient.caption(Caption(caption: "", usable: false, note: "face too small"))
        let critic = Fixtures.criticOK()
        let runner = try runner(captioner: captioner, critic: critic)

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .unusable)
        #expect(outcome.notes == ["face too small"])
        #expect(outcome.caption == nil)
        #expect(!space.exists("solo.txt"))
        let record = try space.record("solo.json")
        #expect(record == outcome.record)
        #expect(record.status == .unusable)
        #expect(record.attempts == 1)
        #expect(record.requests == 1)
        #expect(record.caption == Caption(caption: "", usable: false, note: "face too small"))
        #expect(record.critique == nil)
        #expect(record.critic == ModelNames(requested: "fake", served: nil))
        #expect(await critic.requests.isEmpty) // no review of an unusable sample
    }

    @Test func unusableWithoutNoteHasNoNotes() async throws {
        let space = try Workspace()
        let runner = try runner(captioner: FakeModelClient.caption(Caption(caption: "", usable: false)))
        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .unusable)
        #expect(outcome.notes.isEmpty)
        #expect(outcome.record?.critic == nil)
    }

    @Test func neverApprovingCriticRejects() async throws {
        let space = try Workspace()
        let captioner = Fixtures.captionerOK()
        let critic = FakeModelClient.critique(Critique(approved: false, notes: ["still wrong"]))
        let runner = try runner(captioner: captioner, critic: critic)

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .rejected)
        #expect(outcome.notes == ["still wrong"])
        #expect(outcome.caption == nil)
        #expect(!space.exists("solo.txt"))
        let record = try space.record("solo.json")
        #expect(record == outcome.record)
        #expect(record.status == .rejected)
        #expect(record.attempts == 2)
        #expect(record.requests == 4)
        #expect(record.critique == Critique(approved: false, notes: ["still wrong"]))
        #expect(record.caption?.caption.contains("NORA7") == true)
        #expect(await captioner.requests.count == 2)
        #expect(await critic.requests.count == 2)
    }

    // MARK: Deviation 1: a double trigger failure is `rejected`, with a record

    @Test func doubleTriggerFailureIsRejectedWithARecord() async throws {
        let space = try Workspace()
        let captioner = FakeModelClient { _ in try caption("A photograph of a woman by a window.") }
        let critic = Fixtures.criticOK()
        let runner = try runner(captioner: captioner, critic: critic)

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .rejected)
        #expect(outcome.notes == ["the mapped trigger NORA7 must appear exactly in the caption"])
        #expect(outcome.caption == nil)
        let record = try space.record("solo.json")
        #expect(record == outcome.record)
        #expect(record.status == .rejected)
        #expect(record.attempts == 1)
        #expect(record.requests == 2)
        #expect(record.captioner == ModelNames(requested: "fake", served: "fake"))
        #expect(record.caption?.caption.contains("woman by a window") == true)
        #expect(record.critique == nil)
        #expect(!space.exists("solo.txt"))
        #expect(await critic.requests.isEmpty)
    }

    @Test func doubleTriggerFailureInTheFeedbackRoundIsRejected() async throws {
        let space = try Workspace()
        let captioner = FakeModelClient { request in
            if request.messages.count == 1 {
                return try caption("A photograph of NORA7, a woman, by a window.")
            }
            return try caption("A photograph of a woman by a window.") // drops the trigger after feedback
        }
        let critic = FakeModelClient.critique(Critique(approved: false, notes: ["more detail"]))
        let runner = try runner(captioner: captioner, critic: critic)

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .rejected)
        #expect(outcome.notes == ["the mapped trigger NORA7 must appear exactly in the caption"])
        let record = try space.record("solo.json")
        #expect(record.attempts == 2)
        #expect(record.requests == 4) // captioner 1, critic 1, captioner 2
        #expect(record.critique == Critique(approved: false, notes: ["more detail"]))
        #expect(record.caption?.caption.contains("NORA7") == false)
        #expect(!space.exists("solo.txt"))
    }

    // MARK: failed

    @Test func providerErrorIsFailedWithoutARecord() async throws {
        let space = try Workspace()
        let captioner = FakeModelClient { _ in throw ModelError.http(status: 500, body: "boom") }
        let runner = try runner(captioner: captioner, critic: Fixtures.criticOK())

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .failed)
        #expect(outcome.notes == ["ModelError: HTTP 500: boom"])
        #expect(outcome.record == nil)
        #expect(!space.exists("solo.json"))
        #expect(!space.exists("solo.txt"))
        #expect(summary.counts() == [.failed: 1])
    }

    @Test func undecodableRepliesAreFailed() async throws {
        let space = try Workspace()
        let captioner = FakeModelClient { _ in FakeModelClient.Reply(text: "not json") }
        let runner = try runner(captioner: captioner)

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .failed)
        #expect(outcome.notes.count == 1)
        #expect(outcome.notes.first?.hasPrefix("StageFailure: output undecodable after 2 requests") == true)
        #expect(!space.exists("solo.json"))
    }

    @Test func criticErrorIsFailedAndOtherSamplesStillRun() async throws {
        let space = try Workspace()
        let critic = FakeModelClient { request in
            if request.lastText.contains("IVAN9") { throw ModelError.transport("socket closed") }
            return try critique(Critique(approved: true))
        }
        let runner = try runner(captioner: Fixtures.captionerOK(), critic: critic)

        let summary = try await runner.run(source: space.source, sink: space.sink)
        #expect(statuses(summary) == ["solo.png": .written, "pair.png": .failed, "unmapped.png": .needsMapping])
        let failed = try #require(summary.outcomes.first { $0.sampleID == "pair.png" })
        #expect(failed.notes == ["ModelError: transport: socket closed"])
        #expect(!space.exists("pair.json"))
        #expect(space.exists("solo.txt"))
    }

    @Test func unreadableImageIsFailed() async throws {
        let space = try Workspace()
        try Data("not an image".utf8).write(to: space.images.appendingPathComponent("solo.png"))
        let captioner = Fixtures.captionerOK()
        let runner = try runner(captioner: captioner)

        let summary = try await runner.run(source: space.source, sink: space.sink, only: ["solo.png"])
        let outcome = try #require(summary.outcomes.first)
        #expect(outcome.status == .failed)
        #expect(outcome.notes.first?.hasPrefix("ConfigurationError: ") == true)
        #expect(await captioner.requests.isEmpty)
    }

    @Test func reportMirrorsTheCLISummary() async throws {
        let space = try Workspace()
        let runner = try runner(captioner: Fixtures.captionerOK())
        let summary = try await runner.run(source: space.source, sink: space.sink)
        let report = try #require(summary.report.objectValue)
        #expect(report.keys == ["counts", "elapsed_s", "sink", "samples"])
        let counts = try #require(report["counts"]?.objectValue)
        #expect(counts["written"] == .int(2))
        #expect(counts["needs_mapping"] == .int(1))
        #expect(report["samples"]?.arrayValue?.count == 3)
    }
}

// MARK: - Concurrency

@Suite("runner concurrency")
struct RunnerConcurrencyTests {
    /// The fixture job with every sample mapped, so three captioner calls can overlap.
    private func allMappedJob() throws -> Job {
        try Job(
            concepts: [Concept(trigger: "NORA7", classNoun: "woman"), Concept(trigger: "IVAN9", classNoun: "man")],
            samples: [
                "solo.png": Fixtures.soloMapping,
                "pair.png": Fixtures.pairMapping,
                "unmapped.png": Fixtures.soloMapping,
            ]
        )
    }

    @Test func concurrencyOneIsStrictlySequential() async throws {
        let space = try Workspace()
        let captioner = slowCaptioner(.milliseconds(20))
        let runner = try runner(captioner: captioner, concurrency: 1, job: allMappedJob())
        let summary = try await runner.run(source: space.source, sink: space.sink)
        #expect(summary.counts() == [.written: 3])
        #expect(await captioner.maxInFlight == 1)
        #expect(await captioner.requests.count == 3)
    }

    @Test(.timeLimit(.minutes(1))) func concurrencyThreeOverlapsThreeSamples() async throws {
        let space = try Workspace()
        let gate = Rendezvous(party: 3)
        let captioner = FakeModelClient { request in
            await gate.arrive()
            return try FakeModelClient
                .Reply(encoding: Caption(caption: Fixtures.goodCaption(for: request.instructions)))
        }
        let runner = try runner(captioner: captioner, concurrency: 3, job: allMappedJob())
        let summary = try await runner.run(source: space.source, sink: space.sink)
        #expect(summary.counts() == [.written: 3])
        #expect(await captioner.maxInFlight == 3)
    }

    @Test(.timeLimit(.minutes(1))) func concurrencyCapsInFlightBelowTheSampleCount() async throws {
        let space = try Workspace()
        let gate = Rendezvous(party: 2)
        let captioner = FakeModelClient { request in
            await gate.arrive()
            try await Task.sleep(for: .milliseconds(10))
            return try FakeModelClient
                .Reply(encoding: Caption(caption: Fixtures.goodCaption(for: request.instructions)))
        }
        let runner = try runner(captioner: captioner, concurrency: 2, job: allMappedJob())
        let summary = try await runner.run(source: space.source, sink: space.sink)
        #expect(summary.counts() == [.written: 3])
        #expect(await captioner.maxInFlight == 2)
    }
}
