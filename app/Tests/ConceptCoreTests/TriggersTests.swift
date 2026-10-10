// Whole-token trigger spans and trigger problems. See docs/CORE-SPEC.md, module `triggers`.
// Python counterpart: tests/test_models_and_stages.py::test_trigger_check, extended with the
// boundary and normalization cases the spec lists.

import ConceptCore
import Foundation
import Testing

@Suite("triggers")
struct TriggersTests {
    /// NORA7 mapped, IVAN9 known but unmapped: the `deps` of the Python test.
    private let deps = CaptionDeps(mapping: ["NORA7": "x"], triggers: ["NORA7", "IVAN9"])

    private func spans(_ text: String, _ trigger: String = "NORA7") -> [[Int]] {
        Triggers.exactTriggerSpans(in: text, trigger: trigger).map { [$0.0, $0.1] }
    }

    // MARK: - exactTriggerSpans (test_trigger_check)

    @Test("the Python example: only the whole token counts")
    func pythonExample() {
        #expect(spans("NORA7 and NORA7x and xNORA7") == [[0, 5]])
    }

    @Test("every whole-token occurrence is reported, in order")
    func allOccurrences() {
        #expect(spans("NORA7, NORA7 and NORA7.") == [[0, 5], [7, 12], [17, 22]])
        #expect(spans("NORA7") == [[0, 5]])
        #expect(spans("") == [])
        #expect(spans("IVAN9 only") == [])
    }

    @Test("case-sensitive, no normalization")
    func caseSensitive() {
        #expect(spans("nora7 and Nora7") == [])
        // A decomposed caption is not normalized by this function (triggerProblems does that).
        #expect(spans("NORA\u{0308}7 here", "NOR\u{00C4}7") == [])
    }

    @Test("adjacent letters, marks, numbers and underscores are not boundaries")
    func wordCharactersAreNotBoundaries() {
        // Spec cases.
        #expect(spans("NORA7_x") == [])
        #expect(spans("NORA7\u{00E9}") == [])
        // Each general-category family stages._is_word_char accepts.
        #expect(spans("NORA7a") == [], "lowercase letter (Ll)")
        #expect(spans("NORA7\u{00DF}") == [], "other-script letter (Ll)")
        #expect(spans("NORA7\u{044F}") == [], "Cyrillic letter (Ll)")
        #expect(spans("NORA7\u{4E2D}") == [], "CJK ideograph (Lo)")
        #expect(spans("NORA7\u{02B0}") == [], "modifier letter (Lm)")
        #expect(spans("NORA7\u{0301}") == [], "combining mark (Mn)")
        #expect(spans("NORA7\u{0903}") == [], "spacing mark (Mc)")
        #expect(spans("NORA7\u{20DD}") == [], "enclosing mark (Me)")
        #expect(spans("NORA72") == [], "decimal digit (Nd)")
        #expect(spans("NORA7\u{00B2}") == [], "other number (No)")
        #expect(spans("NORA7\u{2167}") == [], "letter number (Nl)")
        // The left side is checked the same way.
        #expect(spans("_NORA7") == [])
        #expect(spans("2NORA7") == [])
        #expect(spans("\u{00E9}NORA7") == [])
    }

    @Test("punctuation, whitespace and symbols are boundaries")
    func nonWordCharactersAreBoundaries() {
        // Spec cases.
        #expect(spans("NORA7,") == [[0, 5]])
        #expect(spans("(NORA7)") == [[1, 6]])
        #expect(spans("NORA7-style hair") == [[0, 5]])
        #expect(spans("NORA7's coat") == [[0, 5]])
        #expect(spans("\"NORA7\"") == [[1, 6]])
        #expect(spans("NORA7\nnext line") == [[0, 5]])
        #expect(spans("see NORA7\u{2014}there") == [[4, 9]], "em dash (Pd)")
        #expect(spans("NORA7+IVAN9") == [[0, 5]], "math symbol (Sm)")
        #expect(spans("\u{1F600}NORA7") == [[1, 6]], "emoji (So)")
    }

    @Test("offsets count Unicode scalars like Python's str indices")
    func scalarOffsets() {
        // The emoji is one scalar (two UTF-16 units, four UTF-8 bytes); Python reports (2, 7).
        #expect(spans("\u{1F600} NORA7") == [[2, 7]])
        // A decomposed mark before the trigger counts as its own scalar, as in Python.
        #expect(spans("e\u{0301} NORA7") == [[3, 8]])
    }

    @Test("the scan restarts one scalar after every match (Python start = index + 1)")
    func overlappingScan() {
        // Two whole-token hits that overlap are both reported, exactly as Python's loop does.
        #expect(spans("---", "--") == [[0, 2], [1, 3]])
        // Adjacent copies are not whole tokens; the later lone copy is still found.
        #expect(spans("NORA7NORA7 NORA7") == [[11, 16]])
        // The second match is examined even though the first one overlapped it and was rejected.
        #expect(spans("xNORA7 NORA7") == [[7, 12]])
    }

    // MARK: - triggerProblems (test_trigger_check)

    @Test("a caption using exactly the mapped triggers has no problems")
    func cleanCaption() {
        #expect(Triggers.triggerProblems(caption: "A photo of NORA7, a woman.", deps: deps) == [])
    }

    @Test("a missing mapped trigger is reported with the Python message")
    func missingMappedTrigger() {
        #expect(Triggers.triggerProblems(caption: "A photo of a woman.", deps: deps) == [
            "the mapped trigger NORA7 must appear exactly in the caption",
        ])
        #expect(Triggers.triggerProblems(caption: "", deps: deps) == [
            "the mapped trigger NORA7 must appear exactly in the caption",
        ])
        // A near miss is still a miss.
        #expect(Triggers.triggerProblems(caption: "NORA7x and xNORA7 and nora7.", deps: deps) == [
            "the mapped trigger NORA7 must appear exactly in the caption",
        ])
    }

    @Test("an unmapped job trigger in the caption is reported with the Python message")
    func unmappedTriggerUsed() {
        #expect(Triggers.triggerProblems(caption: "NORA7 with IVAN9.", deps: deps) == [
            "IVAN9 is not mapped in this image; do not use that trigger",
        ])
        // Only a whole-token use counts.
        #expect(Triggers.triggerProblems(caption: "NORA7 with IVAN9x.", deps: deps) == [])
    }

    @Test("missing mapped triggers come first (mapping order), then unmapped triggers (job order)")
    func problemOrder() {
        #expect(Triggers.triggerProblems(caption: "IVAN9 alone.", deps: deps) == [
            "the mapped trigger NORA7 must appear exactly in the caption",
            "IVAN9 is not mapped in this image; do not use that trigger",
        ])
        let reversed = CaptionDeps(mapping: ["IVAN9": "right", "NORA7": "left"], triggers: ["NORA7", "IVAN9"])
        #expect(Triggers.triggerProblems(caption: "Two people.", deps: reversed) == [
            "the mapped trigger IVAN9 must appear exactly in the caption",
            "the mapped trigger NORA7 must appear exactly in the caption",
        ])
        #expect(Triggers.triggerProblems(caption: "IVAN9 and NORA7.", deps: reversed) == [])
    }

    @Test("a trigger the job does not know is not checked at all")
    func unknownTriggersIgnored() {
        #expect(Triggers.triggerProblems(caption: "NORA7 next to ZARA3.", deps: deps) == [])
    }

    @Test("the caption is NFC-normalized before the search")
    func captionIsNormalized() {
        // Chosen example: the caption writes the trigger's umlaut as A + combining diaeresis
        // (U+0041 U+0308); the mapped trigger uses the precomposed letter (U+00C4). After NFC
        // they are the same text, so the trigger is found and there is no problem.
        let umlautDeps = CaptionDeps(mapping: ["NOR\u{00C4}7": "x"], triggers: ["NOR\u{00C4}7"])
        #expect(Triggers.triggerProblems(caption: "A photo of NORA\u{0308}7.", deps: umlautDeps) == [])
        // Without normalization the search would miss it.
        #expect(spans("A photo of NORA\u{0308}7.", "NOR\u{00C4}7") == [])
    }

    @Test("the mapped trigger is NFC-normalized for the search; the message quotes it as written")
    func mappedTriggerIsNormalized() {
        let decomposed = "NORA\u{0308}7"
        let decomposedDeps = CaptionDeps(mapping: [decomposed: "x"], triggers: [decomposed])
        #expect(Triggers.triggerProblems(caption: "A photo of NOR\u{00C4}7.", deps: decomposedDeps) == [])
        #expect(Triggers.triggerProblems(caption: "A photo of a woman.", deps: decomposedDeps) == [
            "the mapped trigger \(decomposed) must appear exactly in the caption",
        ])
    }

    @Test("a decomposed letter adjacent to the trigger still fails after NFC")
    func decomposedAdjacentLetterStillFails() {
        // Chosen example: "NORA7" followed by e + combining acute (U+0065 U+0301). NFC composes
        // that to é (U+00E9), a letter, so NORA7 is not a whole token either way and the mapped
        // trigger is reported missing.
        #expect(Triggers.triggerProblems(caption: "A photo of NORA7e\u{0301}.", deps: deps) == [
            "the mapped trigger NORA7 must appear exactly in the caption",
        ])
        // A lone combining mark has no precomposed form with "7"; it is a mark, so still no token.
        #expect(Triggers.triggerProblems(caption: "A photo of NORA7\u{0301}.", deps: deps) == [
            "the mapped trigger NORA7 must appear exactly in the caption",
        ])
    }

    // MARK: - retryMessage (stages.py ModelRetry)

    @Test("the retry message is the Python text with problems joined by '; '")
    func retryMessageText() {
        let expected = "Fix the caption: a; b. If a mapped subject is not actually visible in this image, "
            + "do not invent it: set usable to false, leave the caption empty and say why in note."
        #expect(Triggers.retryMessage(problems: ["a", "b"]) == expected)
        #expect(Triggers.retryMessage(problems: ["only"]).hasPrefix("Fix the caption: only. If a mapped subject"))
    }

    @Test("the retry message for real problems reads as the Python validator sends it")
    func retryMessageFromProblems() {
        let problems = Triggers.triggerProblems(caption: "IVAN9 alone.", deps: deps)
        #expect(Triggers.retryMessage(problems: problems) == "Fix the caption: "
            + "the mapped trigger NORA7 must appear exactly in the caption; "
            + "IVAN9 is not mapped in this image; do not use that trigger. "
            + "If a mapped subject is not actually visible in this image, do not invent it: "
            + "set usable to false, leave the caption empty and say why in note.")
    }

    // MARK: - CaptionDeps

    @Test("CaptionDeps keeps mapping order and is Equatable")
    func captionDepsValue() {
        let first = CaptionDeps(mapping: ["NORA7": "left", "IVAN9": "right"], triggers: ["NORA7", "IVAN9"])
        let second = CaptionDeps(mapping: ["NORA7": "left", "IVAN9": "right"], triggers: ["NORA7", "IVAN9"])
        #expect(first == second)
        #expect(first.mapping.keys == ["NORA7", "IVAN9"])
        #expect(first != CaptionDeps(mapping: ["NORA7": "left"], triggers: ["NORA7", "IVAN9"]))
    }
}
