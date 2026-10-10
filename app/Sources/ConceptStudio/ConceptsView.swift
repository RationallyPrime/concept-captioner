import ConceptCore
import SwiftUI

struct ConceptsView: View {
    @Bindable var session: StudioSession
    @State private var editing: Concept?
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.contentSpacing) {
                StudioNotice(
                    "A learning word (trigger) represents the traits your model should hold. "
                        + "Captions describe everything you want to change later."
                )
                ForEach(session.project?.job.concepts ?? [], id: \.trigger) { concept in
                    conceptSummary(concept)
                    Divider()
                }
                Button("Add another concept", systemImage: "plus") { editing = nil; showEditor = true }
                    .disabled(session.busy)
                Text(
                    "Use one clear reference face per person for mapping suggestions. "
                        + "Suggestions need your confirmation."
                )
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
        }
        .sheet(isPresented: $showEditor) { ConceptEditor(session: session, existing: editing) }
    }

    private func conceptSummary(_ concept: Concept) -> some View {
        StudioSection(title: "\(concept.trigger) · \(concept.classNoun)") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    if let reference = session.references[concept.trigger] {
                        PhotoView(url: reference).frame(width: 150, height: 170)
                    } else {
                        Image(systemName: "person.crop.square")
                            .font(.system(size: 56)).foregroundStyle(StudioStyle.supportingText)
                            .frame(width: 150, height: 170)
                            .background(StudioStyle.surface)
                    }
                    Text("Reference photo").font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 28) {
                        traits("Learn", subtitle: "Keep recognizable", values: concept.traitsToLearn)
                        traits("Describe", subtitle: "Keep changeable", values: concept.attributesToDescribe)
                    }
                    if !concept.explicitBoundaryDecisions.isEmpty {
                        DisclosureGroup("Specific boundary decisions") {
                            ForEach(concept.explicitBoundaryDecisions.keys, id: \.self) { key in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key).fontWeight(.medium)
                                    Text(concept.explicitBoundaryDecisions[key] ?? "")
                                        .foregroundStyle(StudioStyle.supportingText)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Edit boundary", systemImage: "slider.horizontal.3") {
                            editing = concept; showEditor = true
                        }
                        Button("Choose reference face…") { session.chooseReference(trigger: concept.trigger) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func traits(_ title: String, subtitle: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.callout).foregroundStyle(StudioStyle.supportingText)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).fixedSize(horizontal: false, vertical: true)
            }
            if values.isEmpty { Text("No traits added yet").foregroundStyle(StudioStyle.supportingText) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConceptEditor: View {
    @Bindable var session: StudioSession
    let existing: Concept?
    @Environment(\.dismiss) private var dismiss
    @State private var trigger = ""
    @State private var classNoun = "person"
    @State private var target = TargetConcept.facialIdentity
    @State private var learn = "distinctive facial identity"
    @State private var describe = Concept.defaultAttributesToDescribe.joined(separator: "\n")
    @State private var decisions = ""
    @State private var intent = ""
    @State private var error = ""
    @State private var draftTask: Task<Void, Never>?
    @State private var editorActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing == nil ? "Define a concept" : "Edit your learning boundary")
                .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    intentSection
                    Divider()
                    identitySection
                    Divider()
                    StudioSection(
                        title: "Learn these traits",
                        subtitle: "The identity or qualities to keep recognizable. One per line."
                    ) {
                        TextEditor(text: $learn).frame(height: 75).border(.quaternary)
                            .accessibilityLabel("Learn these traits")
                    }
                    StudioSection(
                        title: "Describe these changeable details",
                        subtitle: "Clothes, pose, light and other details you want to vary. One per line."
                    ) {
                        TextEditor(text: $describe).frame(height: 110).border(.quaternary)
                            .accessibilityLabel("Describe these changeable details")
                    }
                    DisclosureGroup("Specific boundary decisions (optional)") {
                        Text("For an ambiguous detail, write detail: decision, one per line.")
                            .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        TextEditor(text: $decisions).frame(height: 80).border(.quaternary)
                            .accessibilityLabel("Boundary decisions")
                    }
                }.padding(.trailing, 8)
            }
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save concept") { save() }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .disabled(session.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 660, height: 650).tint(StudioStyle.accent)
            .onAppear {
                editorActive = true
                guard let existing else { trigger = "CONCEPT\((session.project?.job.concepts.count ?? 0) + 1)"; return }
                trigger = existing.trigger; classNoun = existing.classNoun; target = existing.targetConcept
                learn = existing.traitsToLearn.joined(separator: "\n")
                describe = existing.attributesToDescribe.joined(separator: "\n")
                decisions = existing.explicitBoundaryDecisions.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            }
            .onDisappear { editorActive = false; draftTask?.cancel() }
    }

    private var intentSection: some View {
        StudioSection(
            title: "Start with what you want",
            subtitle: "Describe the subject and what should stay recognizable."
        ) {
            TextField("Your intended result", text: $intent, axis: .vertical).lineLimit(2 ... 4)
            Button("Draft the boundary from my description", systemImage: "sparkles") { draft() }
                .disabled(intent.isEmpty || session.busy)
            Text(session.demoMode ? "The demo drafts locally, with no account or charges." :
                "Uses your selected captioning provider and may use account credits. Review the draft before saving.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
        }
    }

    private var identitySection: some View {
        StudioSection(title: "Name your concept") {
            TextField("Learning word", text: $trigger)
            Text("A unique word such as NORA7. Use the same word when training and generating pictures.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            TextField("Ordinary category", text: $classNoun)
            Text("For example: person, dog, sculpture or style.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            Picker("What should be learned?", selection: $target) {
                ForEach(TargetConcept.allCases, id: \.self) {
                    Text($0.rawValue.replacingOccurrences(of: "_", with: " ")).tag($0)
                }
            }
        }
    }

    private func draft() {
        guard !session.busy else { return }
        session.draftBoundary(description: intent) { draft in
            guard editorActive, !Task.isCancelled else { return }
            learn = draft.learn.joined(separator: "\n")
            describe = draft.describe.joined(separator: "\n")
            decisions = draft.decisions.map { "\($0.detail): \($0.decision)" }.joined(separator: "\n")
            draftTask = nil
        }
        draftTask = session.task
    }

    private func close() {
        editorActive = false
        draftTask?.cancel()
        dismiss()
    }

    private func save() {
        do {
            let pairs = try decisions.split(separator: "\n").map { line -> (String, String) in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2
                else { throw StudioError.message("Use detail: decision for each boundary decision.") }
                return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
            }
            let concept = try Concept(
                trigger: trigger,
                classNoun: classNoun,
                targetConcept: target,
                traitsToLearn: learn.split(separator: "\n").map(String.init),
                attributesToDescribe: describe.split(separator: "\n").map(String.init),
                explicitBoundaryDecisions: OrderedDictionary(pairs)
            )
            try session.saveConcept(concept, replacing: existing?.trigger)
            close()
        } catch { self.error = StudioSession.describe(error) }
    }
}
