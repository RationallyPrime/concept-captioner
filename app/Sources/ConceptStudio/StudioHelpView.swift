import SwiftUI

struct StudioHelpView: View {
    @State private var query = ""
    @State private var selectedTerm: StudioTerm? = .train

    private var matchingTerms: [StudioTerm] {
        StudioTerm.search(query)
    }

    private var displayedTerm: StudioTerm? {
        matchingTerms.first { $0 == selectedTerm } ?? matchingTerms.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                Text("ConceptStudio help").font(.title.bold()).accessibilityAddTraits(.isHeader)
                StudioSection(title: "Find a term", subtitle: "Search a name or a word in its explanation.") {
                    TextField("Search definitions", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search definitions")
                    if matchingTerms.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(minHeight: 160)
                    } else {
                        HStack(alignment: .top, spacing: 24) {
                            List(matchingTerms, selection: $selectedTerm) { term in
                                Text(term.title).tag(term)
                            }.frame(width: 220, height: 300)
                                .accessibilityLabel("Matching definitions")
                            if let term = displayedTerm {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(term.title).font(.headline).accessibilityAddTraits(.isHeader)
                                    Text(term.definition).foregroundStyle(StudioStyle.supportingText)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Divider()
                StudioSection(title: "How diffusion training works") { StudioExplanationContent() }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(StudioStyle.canvas)
    }
}
