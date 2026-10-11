// Prompt assembly order and byte parity with the Python package. See docs/CORE-SPEC.md, module `prompt`.
// Python counterpart: tests/test_skills_and_prompt.py::test_prompt_assembly.

import ConceptCore
import CryptoKit
import Foundation
import Testing

@Suite("prompt")
struct PromptTests {
    // The reference hashes come from `src/concept_captioner` at the commit that wrote CORE-SPEC.md:
    // bundled skill, profile h3-still, the NORA7/IVAN9 fixture job, the solo mapping. Recompute
    // them when the skill text changes.
    static let captionerSHA256 = "83871f8c9d0db25a084864921e38578baf72c05eddc4af45c75f32c4e623fef1"
    static let criticSHA256 = "b4ac9c6b6719629cabb6f84e413cd4594217dda221e676395db3db3894dbc4ba"
    static let captionerLength = 23627

    struct Inputs {
        let skill: Skill
        let profile: String
        let job: Job
    }

    static func inputs(policyOverrides: OrderedDictionary<String, String> = [:]) throws -> Inputs {
        let skill = try Skills.load()
        var job = try Fixtures.job()
        job.policyOverrides = policyOverrides
        return try Inputs(skill: skill, profile: skill.profile(job.profile), job: job)
    }

    static func captioner(_ inputs: Inputs, mapping: Job.Mapping) throws -> String {
        try Prompt.captionerInstructions(
            skill: inputs.skill,
            profileText: inputs.profile,
            job: inputs.job,
            mapping: mapping
        )
    }

    static func critic(_ inputs: Inputs, mapping: Job.Mapping) throws -> String {
        try Prompt.criticInstructions(
            skill: inputs.skill,
            profileText: inputs.profile,
            job: inputs.job,
            mapping: mapping
        )
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Offset of the first occurrence of `needle`, in unicode scalars (Python `str.index`).
    static func index(of needle: String, in text: String) throws -> Int {
        let range = try #require(text.range(of: needle), "\(needle) is missing")
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
    }

    // MARK: - Ordering and content (test_prompt_assembly)

    @Test("sections come in order: skill, profile, job configuration, task")
    func ordering() throws {
        let inputs = try Self.inputs()
        let text = try Self.captioner(inputs, mapping: ["NORA7": "The only person."])
        let policy = try Self.index(of: "# Core Caption Policy", in: text)
        let shot = try Self.index(of: "[Shot 1]", in: text)
        let configuration = try Self.index(of: "ACTIVE JOB CONFIGURATION", in: text)
        let task = try Self.index(of: "RESPONSE\nReturn one JSON object.", in: text)
        #expect(policy < shot)
        #expect(shot < configuration)
        #expect(configuration < task)
        #expect(text.hasSuffix("describe it generically.\n"))
        #expect(!text.hasSuffix("\n\n"))
    }

    @Test("the job view names only the mapped concepts")
    func jobViewMappedOnly() throws {
        let inputs = try Self.inputs()
        let text = try Self.captioner(inputs, mapping: ["NORA7": "The only person."])
        let jobView = try #require(text.components(separatedBy: "ACTIVE JOB CONFIGURATION").last)
        #expect(jobView.contains("\"NORA7\""))
        #expect(!jobView.contains("IVAN9"))
        #expect(try Fixtures.mappedTriggers(in: text) == ["NORA7"])

        let pair = try Self.captioner(inputs, mapping: Fixtures.pairMapping)
        #expect(try Fixtures.mappedTriggers(in: pair) == ["NORA7", "IVAN9"])
        #expect(pair
            .contains(
                "\"subject_mapping\": {\"NORA7\": \"The woman on the left.\", \"IVAN9\": \"The man on the right.\"}"
            ))
    }

    @Test("the job view is one line, exactly the sample view as Python dumps it")
    func jobViewLine() throws {
        let inputs = try Self.inputs()
        let text = try Self.captioner(inputs, mapping: Fixtures.soloMapping)
        let heading = "\n\nACTIVE JOB CONFIGURATION\n"
        let afterHeading = try #require(text.range(of: heading)).upperBound
        let line = text[afterHeading...].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        #expect(String(line) == inputs.job.sampleView(mapping: Fixtures.soloMapping).pythonDumps())
        #expect(text.hasSuffix(heading + line + "\n\n" + Prompt.captionerTask + "\n"))
    }

    @Test("the critic text ends with the review task instead of the response task")
    func criticTask() throws {
        let inputs = try Self.inputs()
        let review = try Self.critic(inputs, mapping: ["NORA7": "x"])
        #expect(review.contains("REVIEW TASK"))
        #expect(!review.contains("RESPONSE\n"))
        #expect(review.hasSuffix("the captioner can act on.\n"))

        // Everything before the task is shared with the captioner text.
        let caption = try Self.captioner(inputs, mapping: ["NORA7": "x"])
        let sharedCaption = caption.dropLast(Prompt.captionerTask.count + 1)
        let sharedReview = review.dropLast(Prompt.criticTask.count + 1)
        #expect(sharedCaption == sharedReview)
        #expect(sharedCaption.hasSuffix("\n\n"))
    }

    // MARK: - Byte parity with Python

    @Test("captioner and critic text hash to the Python package's output")
    func parityWithPython() throws {
        let inputs = try Self.inputs()
        let caption = try Self.captioner(inputs, mapping: Fixtures.soloMapping)
        let review = try Self.critic(inputs, mapping: Fixtures.soloMapping)
        #expect(Self.sha256Hex(caption) == Self.captionerSHA256)
        #expect(Self.sha256Hex(review) == Self.criticSHA256)
        // Python `len` counts code points.
        #expect(caption.unicodeScalars.count == Self.captionerLength)
    }

    @Test("surrounding whitespace on the profile does not change the text")
    func profileWhitespaceIsTrimmed() throws {
        let inputs = try Self.inputs()
        let padded = Inputs(skill: inputs.skill, profile: "\n\n  \(inputs.profile)\n\t\n", job: inputs.job)
        let plain = try Self.captioner(inputs, mapping: Fixtures.soloMapping)
        #expect(try Self.captioner(padded, mapping: Fixtures.soloMapping) == plain)
    }

    // MARK: - Policy overrides

    @Test("a policy override is its own section between the profile and the job configuration")
    func policyOverride() throws {
        let inputs = try Self.inputs(policyOverrides: ["tone": "Plain."])
        let text = try Self.captioner(inputs, mapping: Fixtures.soloMapping)
        let section = "# Job policy override: tone\n\nPlain."
        let shot = try Self.index(of: "[Shot 1]", in: text)
        let override = try Self.index(of: section, in: text)
        let configuration = try Self.index(of: "ACTIVE JOB CONFIGURATION", in: text)
        #expect(shot < override)
        #expect(override < configuration)
        #expect(text.contains("\n\n\(section)\n\nACTIVE JOB CONFIGURATION\n"))
        #expect(try Self.critic(inputs, mapping: Fixtures.soloMapping).contains("\n\n\(section)\n\n"))
    }

    @Test("overrides keep job order and their text is stripped")
    func policyOverridesOrderAndTrimming() throws {
        let inputs = try Self.inputs(policyOverrides: ["tone": "  Plain.\n", "second": "\nTwo.\n\n"])
        let text = try Self.captioner(inputs, mapping: Fixtures.soloMapping)
        let expected = [
            "# Job policy override: tone\n\nPlain.",
            "# Job policy override: second\n\nTwo.",
            "ACTIVE JOB CONFIGURATION\n",
        ].joined(separator: "\n\n")
        #expect(text.contains("\n\n" + expected))
    }

    @Test("without overrides the profile runs straight into the job configuration")
    func noOverrides() throws {
        let inputs = try Self.inputs()
        let text = try Self.captioner(inputs, mapping: Fixtures.soloMapping)
        #expect(!text.contains("# Job policy override"))
        let profileEnd = inputs.profile.trimmingCharacters(in: .whitespacesAndNewlines).suffix(40)
        #expect(text.contains("\(profileEnd)\n\nACTIVE JOB CONFIGURATION\n"))
    }

    // MARK: - Constants

    @Test("the task texts are the Python constants, verbatim and without a trailing newline")
    func taskTexts() {
        #expect(Prompt.captionerTask.hasPrefix("RESPONSE\nReturn one JSON object. `caption` is the training text only"))
        #expect(Prompt.captionerTask.hasSuffix("verbatim; describe it generically."))
        #expect(Prompt.criticTask
            .hasPrefix("REVIEW TASK (replaces the captioning task above)\nReview the proposed caption"))
        #expect(Prompt.criticTask.hasSuffix("the captioner can act on."))
        #expect(Prompt.userTurn == "Inspect this exact training target and return the configured JSON object.")
    }

    @Test("the critic user turn quotes the caption after a blank line")
    func criticUserTurn() {
        let caption = Fixtures.h3("A photograph frames NORA7, a woman.")
        #expect(
            Prompt.criticUserTurn(caption: caption)
                == "Review this proposed caption against the attached training target:\n\n" + caption
        )
        #expect(Prompt
            .criticUserTurn(caption: "") == "Review this proposed caption against the attached training target:\n\n")
    }
}
