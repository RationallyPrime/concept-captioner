import AppKit
import SwiftUI

struct StudioDefinitionView: View {
    let term: StudioTerm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(term.title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(term.definition).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 340, alignment: .leading)
    }
}

/// Contextual terms reuse the same native hover, click and keyboard definitions as the introduction.
struct StudioTermsHelp: View {
    let terms: [StudioTerm]
    let title: String
    @FocusState private var focusedTerm: StudioTerm?
    private let columns = [GridItem(.adaptive(minimum: 180), alignment: .leading)]

    init(terms: [StudioTerm], title: String = "Definitions") {
        self.terms = terms
        self.title = title
    }

    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hover for a definition, or select a term to open it. Keyboard focus shows "
                    + "the definition below; Space or Return opens it, and Escape closes it.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(terms) { term in StudioTermButton(term, focusedTerm: $focusedTerm) }
                }
                if let focusedTerm, terms.contains(focusedTerm) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(focusedTerm.title).font(.headline)
                        Text(focusedTerm.definition).foregroundStyle(StudioStyle.supportingText)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 4)
                }
            }.padding(.vertical, 8)
        }
    }
}

/// An ordinary focusable button gives definitions a keyboard and VoiceOver path as well as hover help.
struct StudioTermButton: View {
    let term: StudioTerm
    let focusedTerm: FocusState<StudioTerm?>.Binding
    @State private var showingDefinition = false

    init(_ term: StudioTerm, focusedTerm: FocusState<StudioTerm?>.Binding) {
        self.term = term
        self.focusedTerm = focusedTerm
    }

    var body: some View {
        Button(term.title, systemImage: "questionmark.circle") { showingDefinition = true }
            // Definitions are readable on focus even when macOS restricts ordinary
            // button navigation. The default includes editing as well as activation focus.
            .focusable()
            .focused(focusedTerm, equals: term)
            .onKeyPress(keys: [.space, .return, .escape], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                if press.key == .escape {
                    guard showingDefinition else { return .ignored }
                    showingDefinition = false
                } else {
                    showingDefinition = true
                }
                return .handled
            }
            .help(term.definition)
            .accessibilityLabel("Define \(term.title)")
            .accessibilityHint(term.definition)
            .popover(isPresented: $showingDefinition) { StudioDefinitionView(term: term) }
    }
}

/// Native rich text keeps connected prose selectable and gives each italic term an AppKit tooltip.
struct StudioGlossaryParagraph: NSViewRepresentable {
    let markdown: String
    let define: (StudioTerm) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(define: define)
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor(StudioStyle.accent), .underlineStyle: 0]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.define = define
        view.textStorage?.setAttributedString(Self.attributed(markdown))
        view.setAccessibilityLabel(markdown.replacingOccurrences(of: "*", with: ""))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        Self.measuredSize(of: nsView, proposedWidth: proposal.width ?? 760)
    }

    static func measuredSize(of textView: NSTextView, proposedWidth: CGFloat) -> CGSize {
        let width = max(1, proposedWidth)
        // SwiftUI probes several widths, including zero. Measure independently so a probe
        // cannot leave the displayed paragraph's container narrower than its actual view.
        let storage = NSTextStorage(attributedString: textView.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    static func attributed(_ markdown: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 16)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let result = NSMutableAttributedString(string: "")
        for (index, text) in markdown.components(separatedBy: "*").enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            if index % 2 == 1, let term = StudioTerm.matching(text) {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                attributes[.link] = URL(string: "conceptstudio-definition://term/\(term.rawValue)")!
                attributes[.toolTip] = term.definition
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var define: (StudioTerm) -> Void
        init(define: @escaping (StudioTerm) -> Void) {
            self.define = define
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "conceptstudio-definition",
                  url.host() == "term", let term = StudioTerm(rawValue: url.lastPathComponent) else { return false }
            define(term)
            return true
        }
    }
}
