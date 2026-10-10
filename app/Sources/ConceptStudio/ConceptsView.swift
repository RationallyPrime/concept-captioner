import ConceptCore
import SwiftUI

struct ConceptsView: View {
    @Bindable var session: StudioSession
    @State private var editing: Concept?
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "A learning word (trigger) represents the traits your model should hold. "
                        + "Captions describe everything you want to change later."
                )
                ForEach(session.project?.job.concepts ?? [], id: \.trigger) { concept in
                    GroupBox {
                        HStack(alignment: .top, spacing: 20) {
                            if let reference = session.references[concept.trigger] {
                                PhotoView(url: reference).frame(width: 100, height: 100)
                            } else {
                                Image(systemName: "person.crop.square").font(.system(size: 56))
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(concept.trigger) · \(concept.classNoun)").font(.title3.bold())
                                Text("Learn: " + concept.traitsToLearn.joined(separator: "; "))
                                Text("Describe: " + concept.attributesToDescribe.joined(separator: "; "))
                                    .foregroundStyle(.secondary)
                                ForEach(concept.explicitBoundaryDecisions.keys, id: \.self) { key in
                                    Text("\(key): \(concept.explicitBoundaryDecisions[key] ?? "")").font(.callout)
                                }
                                HStack {
                                    Button("Edit boundary") { editing = concept; showEditor = true }
                                    Button("Choose reference face…") {
                                        session.chooseReference(trigger: concept.trigger)
                                    }
                                }
                            }
                            Spacer()
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Button("Add another concept", systemImage: "plus") { editing = nil; showEditor = true }
                    .disabled(session.busy)
                Text(
                    "Use one clear reference face per person for mapping suggestions. "
                        + "Suggestions need your confirmation."
                )
                .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showEditor) { ConceptEditor(session: session, existing: editing) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Define a concept" : "Edit your learning boundary").font(.title2.bold())
            Form {
                TextField("Learning word", text: $trigger)
                    .help("A distinct token such as NORA7; use the same word in training and generation.")
                TextField("Ordinary category", text: $classNoun).help("For example person, dog, sculpture or style.")
                Picker("What should be learned?", selection: $target) {
                    ForEach(TargetConcept.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(
                        of: "_",
                        with: " "
                    )).tag($0) }
                }
                TextField("Your intended result", text: $intent, axis: .vertical)
                Button("Draft the boundary from my description") {
                    session.draftBoundary(description: intent) { draft in
                        learn = draft.learn.joined(separator: "\n")
                        describe = draft.describe.joined(separator: "\n")
                        decisions = draft.decisions.map { "\($0.detail): \($0.decision)" }
                            .joined(separator: "\n")
                    }
                }.disabled(intent.isEmpty || session.busy)
                Text("Learn these traits · one per line").font(.headline)
                TextEditor(text: $learn).frame(height: 65).border(.quaternary)
                Text("Describe these changeable details · one per line").font(.headline)
                TextEditor(text: $describe).frame(height: 110).border(.quaternary)
                Text("Boundary decisions · detail: decision, one per line").font(.headline)
                TextEditor(text: $decisions).frame(height: 65).border(.quaternary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save concept") { save() }.buttonStyle(.borderedProminent).disabled(session.busy)
            }
        }.padding(28).frame(width: 620)
            .onAppear {
                guard let existing else { trigger = "CONCEPT\((session.project?.job.concepts.count ?? 0) + 1)"; return }
                trigger = existing.trigger; classNoun = existing.classNoun; target = existing.targetConcept
                learn = existing.traitsToLearn.joined(separator: "\n")
                describe = existing.attributesToDescribe.joined(separator: "\n")
                decisions = existing.explicitBoundaryDecisions.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            }
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
            dismiss()
        } catch { self.error = StudioSession.describe(error) }
    }
}
