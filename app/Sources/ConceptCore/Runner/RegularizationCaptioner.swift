// Captions for regularization images: ordinary pictures of the subject's class, drawn by the base model and
// written in the project's caption format with no trigger anywhere. The captioner is given the skill, the
// project's profile, the skill's regularization guidance and the class nouns; the job's concepts, triggers and
// mappings never reach it. The Python package has no counterpart: only the app captions these images.

import Foundation

public struct RegularizationCaptioner: Sendable {
    public let concurrency: Int
    private let instructions: String
    private let stage: StructuredStage<Caption>

    /// `ConfigurationError` when the skill cannot supply its instructions or the regularization guidance.
    public init(
        captioner: ResolvedEndpoint, skill: Skill, profile: String, profileText: String, classNouns: [String]
    ) throws {
        instructions = try Prompt.regularizationInstructions(
            skill: skill, profile: profile, profileText: profileText, classNouns: classNouns
        )
        stage = StructuredStage(
            name: "regularization captioner",
            endpoint: captioner,
            schemaName: Caption.schemaName,
            schema: Caption.jsonSchema
        )
        concurrency = captioner.concurrency
    }

    /// The caption of each sample by its id, at most `concurrency` requests at a time; `onCaption` hears how many
    /// samples have settled. A sample the captioner finds unusable has no entry. A failed request throws.
    public func captions(
        of samples: [Sample], onCaption: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> [String: String] {
        var captions: [String: String] = [:]
        var settled = 0
        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            var pending = samples.makeIterator()
            var inFlight = 0
            func settle(_ result: (String, String?)) async {
                settled += 1
                if let text = result.1 { captions[result.0] = text }
                await onCaption?(settled)
            }
            while let sample = pending.next() {
                try Task.checkCancellation()
                if inFlight == concurrency, let result = try await group.next() {
                    inFlight -= 1
                    await settle(result)
                }
                group.addTask { try await (sample.sampleID, caption(sample)) }
                inFlight += 1
            }
            for try await result in group {
                await settle(result)
            }
        }
        return captions
    }

    private func caption(_ sample: Sample) async throws -> String? {
        let image = try MediaInput.content(data: sample.data, suffix: sample.suffix)
        let run = try await stage.run(
            instructions: instructions,
            messages: [.user([.text(Prompt.userTurn), image])]
        )
        let text = run.output.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return run.output.usable && !text.isEmpty ? text : nil
    }
}
