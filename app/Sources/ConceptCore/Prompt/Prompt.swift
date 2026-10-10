// Assemble the instructions for one sample: skill + profile + job view + task text.
// Python counterpart: prompt.py. The task texts are copied verbatim.
//
// The task texts are the pipeline's own. They describe the output schemas; the model client
// supplies the schema itself in whichever output mode is active, so no schema is dumped here.
//
// Byte parity with Python matters: the instructions are what the model sees, so the same job,
// skill and profile must produce the same text in both implementations. `prompt.py` strips each
// section with `str.strip()` and joins with blank lines; `trimmingCharacters(in:
// .whitespacesAndNewlines)` covers the same Unicode whitespace for every text these files hold.

import Foundation

public enum Prompt {
    public static let userTurn = "Inspect this exact target image and return the configured JSON object."

    public static let captionerTask = """
    RESPONSE
    Return one JSON object. `caption` is the training text only, in the profile's format, with
    line breaks as JSON escapes. Keep uncertainty out of it. Apply exactly the mapped triggers to
    exactly the mapped subjects; describe any other people ordinarily. If a mapped subject is
    absent, too small or obscured, or cannot be bound to one visible person, set `usable` false,
    leave `caption` empty and explain in `note`. Do not guess. For single_subject_only jobs any
    second identity makes the sample unusable. Do not quote readable text (labels, logos, signs)
    verbatim; describe it generically.
    """

    public static let criticTask = """
    REVIEW TASK (replaces the captioning task above)
    You are reviewing a proposed caption against the supplied target image and the ACTIVE JOB
    CONFIGURATION. Approve only if every statement in the caption is visible in the image, the
    mapped triggers are bound to the right people, no trait the configuration reserves for a
    trigger is described, nothing is inferred that a still cannot show (age, biography, sound,
    motion), and no readable text is quoted verbatim. Otherwise reject with short, specific notes
    the captioner can act on.
    """

    /// The heading that introduces the job view; the runner's tests parse the line after it.
    static let jobConfigurationHeading = "ACTIVE JOB CONFIGURATION"

    /// skill instructions, profile, policy overrides, ACTIVE JOB CONFIGURATION, captioner task.
    public static func captionerInstructions(
        skill: Skill,
        profileText: String,
        job: Job,
        mapping: Job.Mapping
    ) throws -> String {
        try join(sections(skill: skill, profileText: profileText, job: job, mapping: mapping) + [captionerTask])
    }

    /// Same sections, ending with the critic task.
    public static func criticInstructions(
        skill: Skill,
        profileText: String,
        job: Job,
        mapping: Job.Mapping
    ) throws -> String {
        try join(sections(skill: skill, profileText: profileText, job: job, mapping: mapping) + [criticTask])
    }

    public static func criticUserTurn(caption: String) -> String {
        "Review this proposed caption against the attached image:\n\n" + caption
    }

    // MARK: - Assembly (prompt.py::_assemble)

    /// The sections every stage shares, in order: the skill's instructions (body plus inlined
    /// references), the profile text, one override section per `policy_overrides` entry in job
    /// order, then the heading plus the single-line JSON job view for this mapping.
    static func sections(skill: Skill, profileText: String, job: Job, mapping: Job.Mapping) throws -> [String] {
        var sections = try [skill.instructions(), profileText]
        for (key, text) in job.policyOverrides {
            sections.append("# Job policy override: \(key)\n\n\(trimmed(text))\n")
        }
        sections.append("\(jobConfigurationHeading)\n" + job.sampleView(mapping: mapping).pythonDumps())
        return sections
    }

    /// `"\n\n".join(section.strip() for section in sections) + "\n"`.
    static func join(_ sections: [String]) -> String {
        sections.map(trimmed).joined(separator: "\n\n") + "\n"
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
