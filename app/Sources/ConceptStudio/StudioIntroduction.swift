import SwiftUI

/// The owner's explanation is shared by Welcome and Images. Italics identify glossary links,
/// not text to abbreviate or replace with promotional copy.
struct StudioIntroduction: View {
    @State private var definition: StudioTerm?
    @AppStorage private var expanded: Bool

    init(preferences: UserDefaults = .standard) {
        _expanded = AppStorage(wrappedValue: true, "studio.trainingExplanationExpanded", store: preferences)
    }

    static let ownerParagraphs = [
        "ConceptStudio is an application that lets you *train* what are called *Diffusion models*. "
            + "Those are a family of AI models whose primary use case is generating images and videos and the point "
            + "of training them is to expand what sorts of images or videos they are capable of generating. "
            + "You can train them to be able to generate a specific individual, to portray specific art styles or "
            + "even a particular activity that the *base model* either can't do at all or does very poorly. "
            + "We say that the training process teaches them a *concept* which can be any of the examples "
            + "we just listed and more!",
        "In order to train a model on a particular concept you need *training data* the model can learn from. "
            + "For a person that's simply photos or video clips of that person. For a style concept you need "
            + "examples drawn or shot in said style and so on. The more abstract your concept, the trickier it "
            + "will be to assemble your training data.",
        "Fortunately for us, modern diffusion models are already quite smart and contain a lot of knowledge "
            + "about the world. This is important because the trick to teaching them a new concept is pairing "
            + "each element in your training data(an image or a video clip) with a *caption* that describes what "
            + "the image is of or what happens in the clip. There's one trick to it though. You need to describe "
            +
            "everything except the concept you want to teach it. That separation is what we call a *concept boundary*.",
    ]

    static let continuation = [
        "The concept is still named in the caption by its *trigger* and a *class noun*. For example, "
            + "“NORA7 person sitting beside a window, wearing a blue shirt” names the person with NORA7 and person, "
            + "then describes the pose, setting and clothing. The person’s defining appearance is left to the trigger. "
            + "Later, you include NORA7 in a generation prompt to ask for that person.",
        "In this app you import your photos or clips, define one concept, prepare and review its captions, "
            + "then train on a rented GPU computer. Training produces a *LoRA*: a small file you save and use with "
            + "a compatible base model in an image or video generation application. The captions guide learning; "
            + "they do not by themselves guarantee that unrelated details are never learned.",
    ]

    var body: some View {
        DisclosureGroup("How diffusion training works", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Self.ownerParagraphs + Self.continuation, id: \.self) { paragraph in
                    StudioGlossaryParagraph(markdown: paragraph) { definition = $0 }
                }
                DisclosureGroup("Definitions") {
                    Text("Hover over an italic term for a definition, or select it to open the explanation. "
                        + "Keyboard focus on a definition button shows its explanation below the buttons; "
                        + "activate the button to open the same explanation in a popover.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText).padding(.vertical, 8)
                    FlowDefinitions()
                }
            }
            .padding(.top, 16)
        }
        .help(
            "Shows the full training explanation; this Mac remembers your expansion choice across Welcome and Images."
        )
        .frame(maxWidth: 760, alignment: .leading)
        .popover(item: $definition) { StudioDefinitionView(term: $0) }
    }
}

private struct FlowDefinitions: View {
    private let columns = [GridItem(.adaptive(minimum: 180), alignment: .leading)]
    @FocusState private var focusedTerm: StudioTerm?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(StudioTerm.allCases) { term in StudioTermButton(term, focusedTerm: $focusedTerm) }
            }
            if let focusedTerm {
                VStack(alignment: .leading, spacing: 6) {
                    Text(focusedTerm.title).font(.headline)
                    Text(focusedTerm.definition).foregroundStyle(StudioStyle.supportingText)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }
        }.padding(.bottom, 8)
    }
}
