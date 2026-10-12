import SwiftUI

struct StudioHelpView: View {
    @State private var query = ""
    @State private var selectedTerm: StudioTerm? = .train
    @State private var sectionID = ""
    @State private var page = 0

    private var matchingTerms: [StudioTerm] {
        StudioTerm.search(query).filter { sectionID.isEmpty || $0.entry.sectionId == sectionID }
    }

    private var displayedTerm: StudioTerm? {
        matchingTerms.first { $0 == selectedTerm } ?? matchingTerms.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("ConceptStudio help").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Help topic", selection: $page) {
                    Text("Glossary").tag(0)
                    Text("Training explained").tag(1)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Help topic").frame(width: 280)
            }
            if page == 0 {
                glossary
            } else {
                ScrollView {
                    StudioExplanationContent().padding(.trailing, 12)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480)
        .background(StudioStyle.canvas)
        .onChange(of: query) { _, _ in
            if !query.isEmpty || !matchingTerms.contains(where: { $0 == selectedTerm }) {
                selectedTerm = matchingTerms.first
            }
        }
        .onChange(of: sectionID) { _, _ in
            if !matchingTerms.contains(where: { $0 == selectedTerm }) { selectedTerm = matchingTerms.first }
        }
    }

    private var glossary: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search terms, aliases or definitions", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search definitions")
            Picker("Section", selection: $sectionID) {
                Text("All sections").tag("")
                ForEach(StudioGlossaryCatalog.allSections) { Text($0.title).tag($0.id) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if matchingTerms.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    ScrollViewReader { scroll in
                        List(matchingTerms, selection: $selectedTerm) { term in
                            Text(term.title).tag(term)
                        }
                        .listStyle(.sidebar).accessibilityLabel("Matching definitions")
                        .onAppear { if let selectedTerm { scroll.scrollTo(selectedTerm.id, anchor: .center) } }
                        .onChange(of: selectedTerm) { _, term in
                            if let term { scroll.scrollTo(term.id, anchor: .center) }
                        }
                    }.frame(width: 200)
                    Divider()
                    if let term = displayedTerm {
                        ScrollView {
                            StudioDefinitionContent(term: term) { related in
                                query = ""
                                sectionID = ""
                                selectedTerm = related
                            }.padding(.trailing, 8)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text(StudioGlossaryCatalog.supplied.scopeNote)
                .font(.caption).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
                .help(StudioGlossaryCatalog.supplied.sourceNote + " " + StudioGlossaryCatalog.supplied.aliasNote)
        }
    }
}
