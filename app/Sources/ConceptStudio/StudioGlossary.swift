import AppKit
import SwiftUI

enum StudioTerm: String, CaseIterable, Identifiable {
    case train, diffusionModels, baseModel, concept, trainingData, caption, conceptBoundary, trigger, classNoun, lora

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .train: "Train"
        case .diffusionModels: "Diffusion models"
        case .baseModel: "Base model"
        case .concept: "Concept"
        case .trainingData: "Training data"
        case .caption: "Caption"
        case .conceptBoundary: "Concept boundary"
        case .trigger: "Trigger"
        case .classNoun: "Class noun"
        case .lora: "LoRA"
        }
    }

    var definition: String {
        switch self {
        case .train:
            "Adjust a model using examples so it can generate something it did not previously know well. "
                + "Training here runs on a rented GPU computer, not on your Mac."
        case .diffusionModels:
            "AI models that generate images or videos by turning noise into an image through a series of steps. "
                + "A text prompt guides what they generate."
        case .baseModel:
            "The existing image or video model you start with, before training your concept. "
                + "Your trained LoRA must be used with a compatible base model."
        case .concept:
            "The one thing you want the model to learn: for example, a person’s identity, an object, "
                + "an art style or an activity. It is the subject of this project, not a caption for one photo."
        case .trainingData:
            "The photos or video clips used as examples during training, paired with captions. "
                + "They should show the concept clearly, with enough variation to distinguish it from other details."
        case .caption:
            "Text paired with one training image or clip. It names your concept by its trigger and class noun, "
                + "then describes the other visible details or action. This helps guide what the model learns."
        case .conceptBoundary:
            "The distinction between the concept named by the trigger and everything else described in the caption. "
                + "For a person, defining appearance belongs to the concept. Pose, clothing and setting are described."
        case .trigger:
            "A distinctive identifier such as NORA7. Captions use it to name your concept, "
                + "and you include it in a generation prompt when you want that concept to appear."
        case .classNoun:
            "A general word for the kind of concept, such as person, ceramic vase or painting style. "
                + "It accompanies the trigger so the model knows what the trigger refers to."
        case .lora:
            "LoRA means Low-Rank Adaptation: a small file containing the changes learned during training. "
                + "Load it alongside a compatible base model in an image or video generation application."
        }
    }

    static func matching(_ text: String) -> StudioTerm? {
        allCases.first { $0.title.localizedCaseInsensitiveCompare(text) == .orderedSame }
    }
}

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
