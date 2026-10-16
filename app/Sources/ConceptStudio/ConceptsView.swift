import ConceptCore
import SwiftUI

struct ConceptsView: View {
    @Bindable var session: StudioSession
    @State private var editor: EditorSelection?
    @State private var multipleConcepts = false

    private var concepts: [Concept] {
        session.project?.job.concepts ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                Text("Choose the concept this LoRA will learn")
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("A concept can be a person, an object, a character, a visual style or a movement. "
                    + "Start with one concept. The captions describe everything else in your training data, "
                    + "while a trigger names the concept itself.")
                    .fixedSize(horizontal: false, vertical: true)
                if concepts.isEmpty {
                    Text(
                        "This project is ready for its first concept. "
                            + "Add one before continuing to captioning or training."
                    )
                    .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
                    Button("Add the first concept…", systemImage: "plus") {
                        editor = EditorSelection(existing: nil)
                    }
                    .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .disabled(session.busy || session.editing)
                }
                if session.demoMode {
                    StudioNotice("The demo starts with the facial identity of one fictional adult. "
                        + "Its original trigger is NORA7. The 24 synthetic photos vary the clothes, "
                        + "pose, setting and light.")
                }
                ForEach(concepts, id: \.trigger) { concept in
                    conceptSummary(concept)
                    Divider()
                }
                if !session.advancedUser, !session.advancedConceptOverrides.isEmpty {
                    StudioNotice("Advanced settings still in force: "
                        + session.advancedConceptOverrides.joined(separator: "; ")
                        + ". Turn on Advanced user to edit them.")
                }
                if session.advancedUser {
                    DisclosureGroup("Advanced settings") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Configure multiple concepts in one LoRA", isOn: $multipleConcepts)
                                .disabled(concepts.count > 1)
                            Text(
                                "Each concept needs its own trigger. Confirm locations for people, objects "
                                    + "and characters; "
                                    + "style and motion apply to the whole target automatically. "
                                    + "Use this only when you intend to train the concepts together."
                            )
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                            if multipleConcepts || concepts.count > 1 {
                                Button("Add concept…", systemImage: "plus") { editor = EditorSelection(existing: nil) }
                                    .disabled(session.busy || session.editing)
                            }
                        }.padding(.top, 10)
                    }
                }
            }.frame(maxWidth: 820, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Button(concepts.count == 1 ? "Confirm concept and continue" : "Confirm concepts and continue") {
                    session.confirmConcepts()
                }
                .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save these concepts and open \(session.nextStep?.title ?? "the next step") (⌘↩)")
                .disabled(session.project == nil || concepts.isEmpty || session.busy || session.editing)
            }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioStyle.canvas)
        }
        .sheet(item: $editor) { ConceptEditor(session: session, existing: $0.existing) }
        .onAppear { multipleConcepts = concepts.count > 1 }
    }

    private struct EditorSelection: Identifiable {
        let id = UUID()
        let existing: Concept?
    }

    private func conceptSummary(_ concept: Concept) -> some View {
        StudioSection(title: concept.targetConcept.title) {
            Text(concept.traitsToLearn.joined(separator: "; "))
                .font(.title3).textSelection(.enabled)
            LabeledContent("Trigger", value: concept.trigger)
            LabeledContent("Class noun", value: concept.classNoun)
            Text(concept.targetConcept.captionExplanation)
                .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 20) {
                if concept.targetConcept.requiresLocator,
                   let reference = session.references[concept.trigger] {
                    PhotoView(url: reference).frame(width: 110, height: 120)
                        .accessibilityLabel("Reference for \(concept.trigger)")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button("Edit concept…", systemImage: "pencil") { editor = EditorSelection(existing: concept) }
                        .disabled(session.busy || session.editing)
                    if concept.targetConcept.requiresLocator {
                        Button(concept.targetConcept
                            .isPersonIdentity ? "Choose reference photo…" : "Choose reference image…") {
                                if let url = ProjectAccess.chooseImages(multiple: false).first {
                                    session.chooseReference(trigger: concept.trigger, from: url)
                                }
                            }.disabled(session.busy || session.editing)
                        Text(concept.targetConcept.isPersonIdentity
                            ? "Use a clear reference to help identify the same person in each sample."
                            :
                            "A reference helps the model locate this object or character in each sample.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                }
            }
        }
    }
}

struct ConceptEditor: View {
    @Bindable var session: StudioSession
    let existing: Concept?
    @Environment(\.dismiss) private var dismiss
    @State private var trigger = ""
    @State private var classNoun = "person"
    @State private var target = TargetConcept.facialIdentity
    @State private var intent = ""
    @State private var describe = ""
    @State private var decisions = ""
    @State private var error = ""

    init(session: StudioSession, existing: Concept?) {
        self.session = session
        self.existing = existing
        let category = existing?.targetConcept ?? .facialIdentity
        _trigger = State(initialValue: existing?.trigger ?? "CONCEPT\((session.project?.job.concepts.count ?? 0) + 1)")
        _classNoun = State(initialValue: existing?.classNoun ?? category.defaultClassNoun)
        _target = State(initialValue: category)
        _intent = State(initialValue: existing?.traitsToLearn.joined(separator: "; ") ?? "")
        _describe = State(initialValue: (existing?.attributesToDescribe ?? category.defaultDescribedAttributes)
            .joined(separator: "\n"))
        _decisions = State(initialValue: existing?.explicitBoundaryDecisions
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing == nil ? "Add concept" : "Edit concept")
                .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            StudioTermsHelp(terms: [.concept, .conceptBoundary, .trigger, .classNoun])
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Concept category", selection: $target) {
                        ForEach(choices, id: \.self) { Text($0.title).tag($0) }
                    }
                    StudioSection(
                        title: target.question,
                        subtitle: "Describe the one concept your training examples share."
                    ) {
                        TextField(target.example, text: $intent, axis: .vertical).lineLimit(2 ... 4)
                            .accessibilityLabel(target.question)
                        Text(target.captionExplanation).font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    StudioSection(title: "Trigger", subtitle: "An uncommon name for the concept, such as NORA7.") {
                        TextField("Trigger", text: $trigger)
                        Text(
                            "Captions include this exact name. Use it in generation prompts to request the concept."
                        )
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    if !session.advancedUser {
                        let overrides = (classNoun != target.defaultClassNoun ? ["Class noun: \(classNoun)"] : [])
                            + (describe != target.defaultDescribedAttributes.joined(separator: "\n")
                                ? ["Caption details: \(describe)"] : [])
                            + (!decisions.isEmpty ? ["Boundary exceptions: \(decisions)"] : [])
                            +
                            (!TargetConcept.beginnerChoices
                                .contains(target) ? ["Detailed category: \(target.title)"] : [])
                        if !overrides.isEmpty {
                            StudioNotice("Advanced settings still in force: " + overrides.joined(separator: "; ")
                                + ". Turn on Advanced user to edit them.")
                        }
                    }
                    if session.advancedUser {
                        DisclosureGroup("Advanced settings") {
                            VStack(alignment: .leading, spacing: 14) {
                                TextField("Class noun", text: $classNoun)
                                Text("The ordinary noun used beside the trigger: person, dog, mug, style or motion.")
                                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                                Text("Caption detail overrides").font(.headline)
                                Text("The category supplies these defaults. Change them only to refine which details "
                                    + "the captions should describe; use one per line.").font(.callout)
                                TextEditor(text: $describe).frame(height: 100).border(.quaternary)
                                    .accessibilityLabel("Caption detail overrides")
                                Text("Boundary exceptions").font(.headline)
                                Text("Optional: detail: decision, one per line. For example, explain whether a "
                                    + "character's permanent costume belongs to the concept.").font(.callout)
                                TextEditor(text: $decisions).frame(height: 75).border(.quaternary)
                                    .accessibilityLabel("Boundary exceptions")
                                Picker("Detailed category", selection: $target) {
                                    ForEach(TargetConcept.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                            }.padding(.top, 10)
                        }
                    }
                }.padding(.trailing, 8)
            }
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save concept") { save() }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || trigger.isEmpty)
            }
        }.padding(28).frame(width: 660, height: 650).tint(StudioStyle.accent)
            .onChange(of: target) { old, new in
                guard old != new else { return }
                if classNoun == old.defaultClassNoun { classNoun = new.defaultClassNoun }
                if intent == old.defaultLearningTarget { intent = new.defaultLearningTarget }
                describe = new.defaultDescribedAttributes.joined(separator: "\n")
            }
    }

    private var choices: [TargetConcept] {
        TargetConcept.beginnerChoices.contains(target)
            ? TargetConcept.beginnerChoices : TargetConcept.beginnerChoices + [target]
    }

    private func save() {
        do {
            let pairs = try decisions.split(separator: "\n").map { line -> (String, String) in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2
                else { throw StudioError.message("Use detail: decision for each boundary exception.") }
                return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
            }
            let concept = try Concept(
                trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
                classNoun: classNoun.trimmingCharacters(in: .whitespacesAndNewlines), targetConcept: target,
                traitsToLearn: [intent.trimmingCharacters(in: .whitespacesAndNewlines)],
                attributesToDescribe: describe.split(separator: "\n").map(String.init),
                explicitBoundaryDecisions: OrderedDictionary(pairs)
            )
            try session.saveConcept(concept, replacing: existing?.trigger)
            dismiss()
        } catch { self.error = StudioSession.describe(error) }
    }
}
