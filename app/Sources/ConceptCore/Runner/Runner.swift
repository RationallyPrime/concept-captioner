// Orchestration: for each sample, caption -> (optional critique, one feedback round) -> write.
// Python counterpart: runner.py. Statuses: written, skipped, needs_mapping, unusable, rejected, failed.
//
// Deviation 1 from runner.py (docs/CORE-SPEC.md): a captioner run that the trigger validator
// rejects twice ends `rejected` with the record written, in both the first round and the
// reviewer-feedback round. Python currently lets that escape as `failed` with no record.

import Foundation

public struct Runner: Sendable {
    public let job: Job
    public let captioner: ResolvedEndpoint
    public let critic: ResolvedEndpoint?
    public let skill: Skill
    public let profileName: String
    public let profileText: String
    public let concurrency: Int
    public var overwrite: Bool

    private let captionerStage: StructuredStage<Caption>
    private let criticStage: StructuredStage<Critique>?

    /// skill nil -> Skills.load(path: job.skill); profile nil -> job.profile; concurrency nil -> captioner.concurrency.
    ///
    /// `ConfigurationError` when the skill cannot be loaded, the profile is unknown to it, or the
    /// concurrency is below 1.
    public init(
        job: Job,
        captioner: ResolvedEndpoint,
        critic: ResolvedEndpoint? = nil,
        skill: Skill? = nil,
        profile: String? = nil,
        concurrency: Int? = nil,
        overwrite: Bool = false
    ) throws {
        let loadedSkill = try skill ?? Skills.load(path: job.skill)
        let profileName = profile ?? job.profile
        let inFlight = concurrency ?? captioner.concurrency
        guard inFlight >= 1 else {
            throw ConfigurationError("concurrency must be at least 1, got \(inFlight)")
        }
        self.job = job
        self.captioner = captioner
        self.critic = critic
        self.skill = loadedSkill
        self.profileName = profileName
        profileText = try loadedSkill.profile(profileName)
        self.concurrency = inFlight
        self.overwrite = overwrite
        captionerStage = StructuredStage(
            name: "captioner",
            endpoint: captioner,
            schemaName: Caption.schemaName,
            schema: Caption.jsonSchema
        )
        criticStage = critic.map {
            StructuredStage(name: "critic", endpoint: $0, schemaName: Critique.schemaName, schema: Critique.jsonSchema)
        }
    }

    // MARK: - Driving a run

    /// Yields each sample's outcome as it completes, at most `concurrency` in flight.
    ///
    /// `only` restricts the run to those sample ids; the source is asked to skip the others
    /// (`ImageSource.samples(only:)`), so excluded images are neither read nor downloaded. A
    /// source iteration error finishes the stream with that error, after the samples already in
    /// flight have settled and their outcomes were yielded. Cancelling the consumer ends the
    /// stream early without an error (as `AsyncThrowingStream` does) and cancels the in-flight
    /// work, which settles in the background; a consumer that must tell cancellation from
    /// completion checks `Task.isCancelled` after the loop, or uses `run`, which does.
    public func stream(
        source: some ImageSource,
        sink: some CaptionSink,
        only: Set<String>? = nil
    ) -> AsyncThrowingStream<Outcome, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Outcome, any Error>.makeStream()
        let driver = Task {
            do {
                try await drive(source: source, sink: sink, only: only) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in driver.cancel() }
        return stream
    }

    /// Runs every sample, then `sink.finalize()`; `elapsed` is wall-clock.
    ///
    /// The work is structured under this call: when the calling task is cancelled the in-flight
    /// samples settle first, then this throws `CancellationError` and the sink is not finalized,
    /// so nothing is pushed or materialized from a partial run and no child can still be writing
    /// into the sink when the caller resumes. A source iteration error propagates the same way,
    /// after the in-flight samples have settled, without finalizing.
    public func run(
        source: some ImageSource,
        sink: some CaptionSink,
        only: Set<String>? = nil
    ) async throws -> RunSummary {
        let clock = ContinuousClock()
        let started = clock.now
        let log = OutcomeLog()
        try await drive(source: source, sink: sink, only: only) { await log.append($0) }
        let summary = try await sink.finalize()
        return await RunSummary(outcomes: log.outcomes, elapsed: Self.seconds(clock.now - started), sink: summary)
    }

    /// Collects outcomes for `run` from the task group's children.
    private actor OutcomeLog {
        private(set) var outcomes: [Outcome] = []

        func append(_ outcome: Outcome) {
            outcomes.append(outcome)
        }
    }

    /// The pipeline proper: pulls samples, keeps at most `concurrency` in flight and hands each
    /// outcome to `yield` as it settles. Every sample in flight settles before this returns or
    /// throws, whether the source fails or the task is cancelled: the source error, or
    /// `CancellationError`, is thrown only once the group has drained.
    private func drive(
        source: some ImageSource,
        sink: some CaptionSink,
        only: Set<String>?,
        yield: @escaping @Sendable (Outcome) async -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var inFlight = 0
            var sourceError: (any Error)?
            do {
                for try await sample in source.samples(only: only) {
                    // The source may have ignored the hint; `only` is the runner's contract.
                    if let only, !only.contains(sample.sampleID) {
                        continue
                    }
                    if Task.isCancelled {
                        break
                    }
                    if inFlight == concurrency, let outcome = try await group.next() {
                        inFlight -= 1
                        await yield(outcome)
                    }
                    group.addTask { await guarded(sample, sink: sink) }
                    inFlight += 1
                }
            } catch {
                sourceError = error
            }
            // Children never throw (`guarded`), so this settles everything still in flight.
            for try await outcome in group {
                await yield(outcome)
            }
            if let sourceError {
                throw sourceError
            }
            try Task.checkCancellation()
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    // MARK: - One sample

    /// `runner.py::_guarded`: any error that escapes `process` becomes a `failed` outcome with no
    /// record, noted as `"<TypeName>: <description>"`.
    private func guarded(_ sample: Sample, sink: some CaptionSink) async -> Outcome {
        do {
            return try await process(sample, sink: sink)
        } catch {
            return Outcome(sampleID: sample.sampleID, status: .failed, notes: [Self.describe(error)])
        }
    }

    static func describe(_ error: any Error) -> String {
        "\(type(of: error)): \(error.localizedDescription)"
    }

    /// The record every captioned sample starts from (`runner.py::_base_record`, status rejected).
    func baseRecord(for sampleID: String) -> ResponseRecord {
        ResponseRecord(
            sampleID: sampleID,
            status: .rejected,
            source: "model",
            skill: skill.name,
            profile: profileName,
            captioner: ModelNames(requested: captioner.requested, served: nil),
            critic: critic.map { ModelNames(requested: $0.requested, served: nil) }
        )
    }

    /// What one sample's stages share: the provider-ready image, the captioner instructions and
    /// the trigger validator (which lets an unusable verdict through untouched).
    private struct SampleContext {
        let sampleID: String
        let mapping: Job.Mapping
        let image: UserContent
        let instructions: String
        let validate: @Sendable (Caption) -> [String]
    }

    private func context(for sample: Sample, mapping: Job.Mapping) throws -> SampleContext {
        let encoded = try Images.providerImage(sample.data, suffix: sample.suffix)
        let deps = CaptionDeps(mapping: mapping, triggers: job.triggers)
        return try SampleContext(
            sampleID: sample.sampleID,
            mapping: mapping,
            image: .image(data: encoded.data, mediaType: encoded.mediaType),
            instructions: Prompt.captionerInstructions(
                skill: skill,
                profileText: profileText,
                job: job,
                mapping: mapping
            ),
            validate: { caption in
                caption.usable ? Triggers.triggerProblems(caption: caption.caption, deps: deps) : []
            }
        )
    }

    /// `runner.py::_process`, step for step, with deviation 1.
    private func process(_ sample: Sample, sink: some CaptionSink) async throws -> Outcome {
        let sampleID = sample.sampleID
        guard let mapping = job.mapping(for: sampleID) else {
            return Outcome(sampleID: sampleID, status: .needsMapping, notes: ["no subject mapping"])
        }
        let existing = try await sink.record(sampleID)
        if let existing, existing.isHumanFinal {
            return Outcome(sampleID: sampleID, status: .skipped, notes: ["human-final"], record: existing)
        }
        if !overwrite, try await sink.exists(sampleID) {
            return Outcome(sampleID: sampleID, status: .skipped, record: existing)
        }

        var record = baseRecord(for: sampleID)
        let context = try context(for: sample, mapping: mapping)
        let opening: [ChatMessage] = [.user([.text(Prompt.userTurn), context.image])]
        var run: StageRun<Caption>
        switch try await captionRound(context, messages: opening, attempt: 1, record: &record, sink: sink) {
        case let .rejected(outcome):
            return outcome
        case let .captioned(first):
            run = first
        }
        if !run.output.usable {
            record.status = .unusable
            let notes = run.output.note.map { [$0] } ?? []
            try await sink.write(sampleID, caption: nil, record: record)
            return Outcome(sampleID: sampleID, status: .unusable, notes: notes, record: record)
        }

        var notes: [String] = []
        if criticStage != nil {
            switch try await review(context, run: &run, record: &record, sink: sink) {
            case let .approved(reviewNotes):
                notes = reviewNotes
            case let .rejected(outcome):
                return outcome
            }
        }

        record.status = .written
        try await sink.write(sampleID, caption: run.output.caption, record: record)
        return Outcome(
            sampleID: sampleID,
            status: .written,
            caption: run.output.caption,
            notes: notes,
            record: record
        )
    }

    private enum CaptionRound {
        case captioned(StageRun<Caption>)
        case rejected(Outcome)
    }

    /// One captioner run (with its own trigger retry). On success the record takes the attempt
    /// number, the requests, the served model and the caption. Deviation 1: a validator rejection
    /// ends the sample `rejected` with the record written; `caption` is the last reply, which did
    /// decode. Any other failure propagates (-> `failed`).
    private func captionRound(
        _ context: SampleContext,
        messages: [ChatMessage],
        attempt: Int,
        record: inout ResponseRecord,
        sink: some CaptionSink
    ) async throws -> CaptionRound {
        let run: StageRun<Caption>
        do {
            run = try await captionerStage.run(
                instructions: context.instructions,
                messages: messages,
                validate: context.validate,
                retryMessage: Triggers.retryMessage
            )
        } catch let StageFailure.rejected(problems, lastReply, requests, servedModel) {
            record.status = .rejected
            record.attempts = attempt
            record.requests += requests
            record.captioner.served = servedModel
            if case let .success(caption) = StructuredStage<Caption>.decode(ReplyText.unfenced(lastReply.text)) {
                record.caption = caption
            }
            try await sink.write(context.sampleID, caption: nil, record: record)
            return .rejected(Outcome(sampleID: context.sampleID, status: .rejected, notes: problems, record: record))
        }
        record.attempts = attempt
        record.requests += run.requests
        record.captioner.served = run.servedModel
        record.caption = run.output
        return .captioned(run)
    }

    private enum Review {
        case approved(notes: [String])
        case rejected(Outcome)
    }

    /// The critic pass: a review, and when it is not approved one feedback round in the same
    /// captioner conversation followed by a second review. `run` ends as the caption to write.
    private func review(
        _ context: SampleContext,
        run: inout StageRun<Caption>,
        record: inout ResponseRecord,
        sink: some CaptionSink
    ) async throws -> Review {
        let instructions = try Prompt.criticInstructions(
            skill: skill,
            profileText: profileText,
            job: job,
            mapping: context.mapping
        )
        var verdict = try await critique(
            run.output.caption,
            context: context,
            instructions: instructions,
            record: &record
        )
        if verdict.approved {
            return .approved(notes: verdict.notes)
        }
        let reasons = verdict.notes.isEmpty ? ["not approved"] : verdict.notes
        let feedback = "Reviewer notes:\n- " + reasons.joined(separator: "\n- ")
        let history = run.messages + [.user(feedback)]
        switch try await captionRound(context, messages: history, attempt: 2, record: &record, sink: sink) {
        case let .rejected(outcome):
            return .rejected(outcome)
        case let .captioned(second):
            run = second
        }
        verdict = try await critique(run.output.caption, context: context, instructions: instructions, record: &record)
        if verdict.approved {
            return .approved(notes: verdict.notes)
        }
        try await sink.write(context.sampleID, caption: nil, record: record)
        return .rejected(Outcome(sampleID: context.sampleID, status: .rejected, notes: verdict.notes, record: record))
    }

    /// `runner.py::_review`: one critic turn over the caption and the image; the record picks up
    /// the request count, the served model and the critique.
    private func critique(
        _ caption: String,
        context: SampleContext,
        instructions: String,
        record: inout ResponseRecord
    ) async throws -> Critique {
        guard let criticStage else {
            preconditionFailure("critique called without a critic")
        }
        let result = try await criticStage.run(
            instructions: instructions,
            messages: [.user([.text(Prompt.criticUserTurn(caption: caption)), context.image])]
        )
        record.requests += result.requests
        record.critic?.served = result.servedModel
        record.critique = result.output
        return result.output
    }
}
