import AppKit
@testable import ConceptStudio
import Testing

@Suite("Contextual term definitions")
@MainActor
struct StudioTermCatalogTests {
    @Test func searchFindsNamesAndOperationalMeaningWithoutAProject() {
        #expect(StudioTerm.search("  VRAM  ").contains(.vram))
        #expect(StudioTerm.search("optimizer").contains(.checkpoint))
        #expect(StudioTerm.search("already completed steps").contains(.resume))
        #expect(StudioTerm.search("h3").contains(.fps))
        #expect(StudioTerm.search("no-such-definition-837").isEmpty)
        #expect(StudioTerm.search(" ").contains(.apiKey))
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
