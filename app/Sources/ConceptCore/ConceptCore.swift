// ConceptCore: the captioning pipeline for diffusion LoRA training sets, ported from the
// Python reference implementation `concept_captioner`. See docs/CORE-SPEC.md.

import Foundation

public enum ConceptCore {
    /// Library version; tracks the Python package it mirrors.
    public static let version = "0.2.0"

    /// The bundled default skill directory (Resources/Skills/diffusion-training-captioner).
    public static var defaultSkillURL: URL {
        Skills.defaultSkillURL()
    }
}
