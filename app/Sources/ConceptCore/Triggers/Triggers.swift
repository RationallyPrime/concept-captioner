// The one mechanical check: every mapped trigger appears as an exact token, no unmapped one does.
// Python counterpart: stages.py (exact_trigger_spans, trigger_problems, the ModelRetry text).

import Foundation

public struct CaptionDeps: Sendable, Equatable {
    public let mapping: Job.Mapping
    /// Every trigger the job knows.
    public let triggers: [String]

    public init(mapping: Job.Mapping, triggers: [String]) {
        self.mapping = mapping
        self.triggers = triggers
    }
}

public enum Triggers {
    /// Whole-token occurrences of `trigger` in `text` as (start, end) offsets, case-sensitive.
    ///
    /// Offsets count Unicode scalars (code points), which is exactly what Python's `str.find` and
    /// `len` count, so a span here equals the span `exact_trigger_spans` reports. A boundary is
    /// anything that is not a letter (L*), mark (M*), number (N*) or `_`. The scan is the Python
    /// one: after every match, whether or not it was a whole token, the search restarts one
    /// scalar later, so overlapping matches are examined too. Neither input is normalized here.
    public static func exactTriggerSpans(in text: String, trigger: String) -> [(Int, Int)] {
        let haystack = Array(text.unicodeScalars)
        let needle = Array(trigger.unicodeScalars)
        var spans: [(Int, Int)] = []
        var start = 0
        while let index = find(needle, in: haystack, from: start) {
            let end = index + needle.count
            let left = index == 0 || !isWordCharacter(haystack[index - 1])
            let right = end == haystack.count || !isWordCharacter(haystack[end])
            if left, right {
                spans.append((index, end))
            }
            start = index + 1
        }
        return spans
    }

    /// NFC-normalizes the caption; one message per missing mapped trigger, then per unmapped trigger used.
    ///
    /// Like `stages.trigger_problems`: the mapped trigger is NFC-normalized for its search (the
    /// message quotes it as written); an unmapped trigger is searched as written. The messages
    /// are the Python strings byte for byte.
    public static func triggerProblems(caption: String, deps: CaptionDeps) -> [String] {
        let text = caption.precomposedStringWithCanonicalMapping
        var problems: [String] = []
        for trigger in deps.mapping.keys {
            let normalized = trigger.precomposedStringWithCanonicalMapping
            if exactTriggerSpans(in: text, trigger: normalized).isEmpty {
                problems.append("the mapped trigger \(trigger) must appear exactly in the caption")
            }
        }
        for trigger in deps.triggers where deps.mapping[trigger] == nil {
            if !exactTriggerSpans(in: text, trigger: trigger).isEmpty {
                problems.append("\(trigger) is not mapped in this image; do not use that trigger")
            }
        }
        return problems
    }

    /// The retry text sent back to the model (stages.py ModelRetry).
    public static func retryMessage(problems: [String]) -> String {
        "Fix the caption: " + problems.joined(separator: "; ")
            + ". If a mapped subject is not actually visible in this image, do not invent it: "
            + "set usable to false, leave the caption empty and say why in note."
    }

    // MARK: - Helpers

    /// `stages._is_word_char`: `_` or a general category starting with L, M or N.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" {
            return true
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// Python `text.find(needle, start)`: the first index at or after `start` where `needle`
    /// occurs, or nil. An empty needle is found at `start` while `start <= count`.
    private static func find(_ needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], from start: Int) -> Int? {
        let last = haystack.count - needle.count
        guard start <= haystack.count, start <= last else {
            return nil
        }
        for index in start ... last where haystack[index ..< index + needle.count].elementsEqual(needle) {
            return index
        }
        return nil
    }
}
