import AppKit
@testable import ConceptStudio
import CryptoKit
import Foundation
import Testing

@Suite("Owner explanation and glossary")
@MainActor
struct StudioExplanationTests {
    @Test func narrowSizingProbesCannotChangeTheDisplayedParagraphContainer() throws {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 712, height: 400))
        view.textContainerInset = .zero
        let container = try #require(view.textContainer)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        view.textStorage?.setAttributedString(StudioGlossaryParagraph.attributed(StudioIntroduction.ownerParagraphs[0]))
        let displayedWidth = container.containerSize.width
        let narrow = StudioGlossaryParagraph.measuredSize(of: view, proposedWidth: 0)
        let actual = StudioGlossaryParagraph.measuredSize(of: view, proposedWidth: 712)
        _ = StudioGlossaryParagraph.measuredSize(of: view, proposedWidth: 1)
        #expect(container.containerSize.width == displayedWidth)
        #expect(view.bounds.width == 712)
        #expect(narrow.height > actual.height)
        #expect(actual.width == 712 && actual.height > 0 && actual.height < 400)
    }

    @Test func introductionPreservesTheOwnersThreeParagraphs() {
        // Independently computed from the owner's recorded prose, including the glossary italics.
        let expected = [
            "2751a2314d3d906f3a22324bde41070cd47d800ab6f8746b1c153ce883b56d0c",
            "c36c49816d4316dcf814b99f772d57f42175cbeb417e9bf69914cf4a8a6f6d33",
            "6170f5d917cea0e47dd5234b763b7b3f9b29b0afab075100e72529bb245c73ea",
        ]
        #expect(StudioIntroduction.ownerParagraphs.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        } == expected)
    }

    @Test func everyIntroducedTermHasAnIndividualHoverDefinitionAndLocalLink() {
        var linked: Set<StudioTerm> = []
        for paragraph in StudioIntroduction.ownerParagraphs + StudioIntroduction.continuation {
            let native = StudioGlossaryParagraph.attributed(paragraph)
            #expect(native.string == paragraph.replacingOccurrences(of: "*", with: ""))
            native.enumerateAttribute(.link, in: NSRange(location: 0, length: native.length)) { value, range, _ in
                guard let url = value as? URL, let term = StudioTerm(rawValue: url.lastPathComponent) else { return }
                #expect(url.scheme == "conceptstudio-definition" && url.host() == "term")
                #expect(native.attribute(.toolTip, at: range.location, effectiveRange: nil) as? String == term
                    .definition)
                linked.insert(term)
            }
            let storage = NSTextStorage(attributedString: native)
            let layout = NSLayoutManager()
            let container = NSTextContainer(containerSize: CGSize(width: 712, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            #expect(layout.glyphRange(for: container).length == layout.numberOfGlyphs)
            #expect(layout.usedRect(for: container).height > 0)
            #expect(layout.usedRect(for: container).maxX <= 712)
        }
        #expect(linked == Set(StudioTerm.introductory))
    }
}
