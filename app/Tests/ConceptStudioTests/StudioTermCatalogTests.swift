import AppKit
@testable import ConceptStudio
import Testing

@Suite("Contextual term definitions")
@MainActor
struct StudioTermCatalogTests {
    @Test func searchFindsNamesAndOperationalMeaningWithoutAProject() {
        #expect(StudioTerm.search("  VRAM  ").first == .vram)
        #expect(StudioTerm.search("LoRA").first == .lora)
        #expect(StudioTerm.search("class noun").first == .classNoun)
        #expect(StudioTerm.search("optimization").contains(.checkpoint))
        #expect(StudioTerm.search("resume").contains(.resume))
        #expect(StudioTerm.search("frames per second").contains(.fps))
        #expect(StudioTerm.search("no-such-definition-837").isEmpty)
        #expect(StudioTerm.search(" ").contains(.apiKey))
    }

    @Test func suppliedGlossaryKeepsBothReadingsAliasesAndValidLearningPaths() throws {
        let glossary = StudioGlossaryCatalog.supplied
        #expect(glossary.entryCount == 178)
        #expect(glossary.entries.count == glossary.entryCount)
        #expect(glossary.sections.count == 11)
        #expect(glossary.sources.count == 82)
        let entryIDs = Set(StudioTerm.allCases.map(\.rawValue))
        let sections = Set(StudioGlossaryCatalog.allSections.map(\.id))
        let sources = Set(glossary.sources.map(\.id))
        #expect(entryIDs.count == StudioGlossaryCatalog.allEntries.count)
        for step in StudioStep.allCases {
            #expect(Set(step.definitionTerms).count == step.definitionTerms.count)
        }
        for entry in StudioGlossaryCatalog.allEntries {
            #expect(!entry.plainLanguage.isEmpty && !entry.goodStuff.isEmpty)
            #expect(sections.contains(entry.sectionId))
            #expect(Set(entry.relatedTerms).isSubset(of: entryIDs))
            #expect(Set(entry.sourceIds).isSubset(of: sources))
        }
        #expect(StudioTerm.search("low-rank adaptation").contains(.lora))
        #expect(StudioTerm.search("trigger token").contains(.trigger))
        #expect(StudioTerm.search("α/√r").contains(.alpha))
        #expect(StudioTerm.checkpoint.related.contains(.resume))
        #expect(StudioTerm(rawValue: "not-a-term") == nil)
        let variant = try #require(StudioTerm(rawValue: "model-variant"))
        #expect(variant.entry.definitionScope == "concept_studio")
        #expect(variant.technicalDefinition.contains("checkpoint"))
        #expect(GlossaryReadingLevel.technical.title == "Show me the good stuff")
    }

    @Test func operationalTermsRenderNativeLinksAndDispatchTheirCatalogIdentity() throws {
        let text = "Keep your *API key* in *Keychain*, then choose a *Caption format*."
        let rendered = StudioGlossaryParagraph.attributed(text)
        #expect(rendered.string == "Keep your API key in Keychain, then choose a Caption format.")
        var activated: [StudioTerm] = []
        let coordinator = StudioGlossaryParagraph.Coordinator { activated.append($0) }
        let view = NSTextView()
        var links: [(URL, NSRange)] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if let link = value as? URL { links.append((link, range)) }
        }
        #expect(links.count == 3)
        for (url, range) in links {
            let term = try #require(StudioTerm(rawValue: url.lastPathComponent))
            #expect(rendered.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String == term.definition)
            #expect(coordinator.textView(view, clickedOnLink: url, at: range.location))
        }
        #expect(activated == [.apiKey, .keychain, .captionFormat])
        #expect(try !coordinator.textView(view, clickedOnLink: #require(URL(string: "https://example.com")), at: 0))
    }
}
