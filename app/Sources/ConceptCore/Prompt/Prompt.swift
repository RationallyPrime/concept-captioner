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
    public static let userTurn = "Inspect this exact training target and return the configured JSON object."

    public static let captionerTask = """
    RESPONSE
    Return one JSON object. `caption` is the training text only, in the profile's format, with
    line breaks as JSON escapes. Keep uncertainty out of it. Apply the mapped triggers according
    to each concept's target_concept and boundary. For person, object or character concepts, bind
    the trigger to the correct visible subject. For style, apply it to the declared whole target
    or region and describe subject matter without verbalizing the style being learned. For
    motion, bind it to the observed movement and describe the performer and scene outside that
    movement concept. Describe unrelated people and objects ordinarily. If the mapped concept is
    absent, obscured or cannot be identified from the supplied evidence, set `usable` false, leave
    `caption` empty and explain in `note`. Do not guess. For single_subject_only person jobs any
    second identity makes the sample unusable. Do not quote readable text (labels, logos, signs)
    verbatim; describe it generically.
    """

    public static let criticTask = """
    REVIEW TASK (replaces the captioning task above)
    Review the proposed caption against the supplied training target and ACTIVE JOB CONFIGURATION.
    Approve only if every statement is supported by the target, each trigger is applied to the
    correct person, object, character, style or motion, and no defining trait reserved for that
    concept is described, including through synonyms. A whole-image style does not require a
    visible person. Do not infer age, biography, sound or motion from a still. For a video, assess
    only observed changes and inspected audio; never infer sound from thumbnails. No readable text
    may be quoted verbatim. Otherwise reject with short, specific notes the captioner can act on.
    """

    /// The task text for regularization images: the same response, with no trigger to apply.
    public static let regularizationTask = """
    RESPONSE
    Return one JSON object. `caption` is the training text only, in the profile's format, with
    line breaks as JSON escapes. Keep uncertainty out of it. This job has no trigger: name each
    subject by its class noun as the regularization instructions say, and describe the rest of the
    picture ordinarily. If the picture is blank, damaged or cannot be described, set `usable`
    false, leave `caption` empty and explain in `note`. Do not guess. Do not quote readable text
    (labels, logos, signs) verbatim; describe it generically.
    """

    /// The heading that introduces the job view; the runner's tests parse the line after it.
    static let jobConfigurationHeading = "ACTIVE JOB CONFIGURATION"

    /// The skill's guidance for regularization images (`references/regularization.md`).
    static let regularizationReference = "regularization.md"

    /// skill instructions, profile, policy overrides, ACTIVE JOB CONFIGURATION, captioner task.
    public static func captionerInstructions(
        skill: Skill,
        profileText: String,
        job: Job,
        mapping: Job.Mapping,
        isVideo: Bool = false
    ) throws -> String {
        try join(sections(skill: skill, profileText: profileText, job: job, mapping: mapping, isVideo: isVideo)
            + [captionerTask])
    }

    /// For regularization images: skill instructions, profile, the skill's regularization guidance,
    /// a job view that holds the class nouns and no trigger, and the regularization task. A skill
    /// without the guidance (a copy made before it existed) uses the bundled skill's.
    public static func regularizationInstructions(
        skill: Skill, profile: String, profileText: String, classNouns: [String]
    ) throws -> String {
        let guidance = try (try? skill.reference(regularizationReference))
            ?? Skills.load().reference(regularizationReference)
        let view = JSONValue.object([
            "training": .object(["profile": .string(profile), "trigger_handling": .string("none")]),
            "regularization": .object(["class_nouns": .array(classNouns.map(JSONValue.string))]),
            "inputs": .object(["evidence": .string("attached_target_image")]),
            "output": .object(["caption_language": .string("English"), "delivery": .string("json_caption_field")]),
        ])
        let configuration = "\(jobConfigurationHeading)\n" + view.pythonDumps()
        return try join([skill.instructions(), profileText, guidance, configuration, regularizationTask])
    }

    /// Same sections, ending with the critic task.
    public static func criticInstructions(
        skill: Skill,
        profileText: String,
        job: Job,
        mapping: Job.Mapping,
        isVideo: Bool = false
    ) throws -> String {
        try join(sections(skill: skill, profileText: profileText, job: job, mapping: mapping, isVideo: isVideo)
            + [criticTask])
    }

    public static func criticUserTurn(caption: String) -> String {
        "Review this proposed caption against the attached training target:\n\n" + caption
    }

    // MARK: - Assembly (prompt.py::_assemble)

    /// The sections every stage shares, in order: the skill's instructions (body plus inlined
    /// references), the profile text, one override section per `policy_overrides` entry in job
    /// order, then the heading plus the single-line JSON job view for this mapping.
    static func sections(
        skill: Skill, profileText: String, job: Job, mapping: Job.Mapping, isVideo: Bool = false
    ) throws -> [String] {
        var sections = try [skill.instructions(), profileText]
        for (key, text) in job.policyOverrides {
            sections.append("# Job policy override: \(key)\n\n\(trimmed(text))\n")
        }
        var view = job.sampleView(mapping: mapping)
        if isVideo, var object = view.objectValue, var inputs = object["inputs"]?.objectValue {
            inputs["evidence"] = .string("attached_target_video")
            inputs["audio_status"] = .string("uninspected")
            object["inputs"] = .object(inputs)
            view = .object(object)
        }
        sections.append("\(jobConfigurationHeading)\n" + view.pythonDumps())
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
