@testable import ConceptCore
import Testing

@Suite("Display-only caption text projection")
struct PartialCaptionTests {
    @Test(arguments: [
        ("{\"caption\":\"NORA7 moves", "NORA7 moves"),
        ("{\"note\":\"caption: wrong\",\"caption\":\"NORA7", "NORA7"),
        ("{\"caption\":\"NORA7 \\", "NORA7 "),
        ("{\"caption\":\"NORA7 \\uD83D", "NORA7 "),
        ("{\"caption\":\"NORA7 \\uD83D\\uDE00", "NORA7 😀"),
        ("{\"caption\":\"NORA7 says \\\"hello\\\"\"}", "NORA7 says \"hello\""),
        ("{\"note\":{\"caption\":\"nested\"}}", ""),
        ("{\"caption\":null}", ""),
    ])
    func onlyTopLevelCaptionIsProjected(pair: (String, String)) {
        #expect(PartialCaption.text(from: pair.0) == pair.1)
    }
}
