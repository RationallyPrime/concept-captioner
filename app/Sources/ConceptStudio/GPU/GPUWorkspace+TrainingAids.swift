import ConceptCore
import Foundation

// The two optional training aids a model row can offer: regularisation images and representation alignment
// (docs/model-table.md, `regularization` and `repa`). The row says what a model supports and its default values;
// the person chooses whether to use them and how many images. Everything the pod needs travels in run.json
// as explicit values, so a saved run repeats the same way after the table changes.

/// A class noun as it reads in a sentence: "a woman", "an object".
enum ClassNounPhrase {
    static func withArticle(_ noun: String) -> String {
        let trimmed = noun.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.lowercased().first else { return trimmed }
        return ("aeiou".contains(first) ? "an " : "a ") + trimmed
    }

    /// "a woman", "a woman and a man", "a woman, a man and an object": each noun once, in the order given.
    static func list(_ nouns: [String]) -> String {
        var seen = Set<String>()
        let distinct = nouns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return ModelTable.sentenceList(distinct.map(withArticle), conjunction: "and")
    }
}

/// How long drawing the regularisation images takes and what it costs, shown before the person turns them on.
struct RegularizationEstimate: Equatable {
    let minutes: Int
    /// Nil until a computer has a quoted price: the price is shown before it is spent (ADR-0003).
    let cost: Double?

    init(images: Int, secondsPerImage: Double, hourlyRate: Double?) {
        let minutes = Int((Double(max(0, images)) * secondsPerImage / 60).rounded(.up))
        self.minutes = minutes
        cost = hourlyRate.flatMap { $0 > 0 ? Double(minutes) * $0 / 60 : nil }
    }

    var sentence: String {
        let duration = "About \(minutes) minute\(minutes == 1 ? "" : "s") the first time"
        guard let cost else { return duration + "." }
        return duration + ", about \(StudioMoney.format(cost)) at this computer's price."
    }
}

/// How far the pod has got drawing regularisation images before the trainer starts.
struct RegularizationProgress: Equatable {
    static let plannedTag = "regularization/planned"
    static let readyTag = "regularization/ready"

    let planned: Int
    let ready: Int

    var text: String {
        "Drawing regularisation images: \(ready) of \(planned)"
    }

    /// Reads a run's events (the agent's `GET /runs/{id}/events`). The launcher writes the two scalars at step 0, so
    /// their step says nothing about training; the answer is nil once every image is ready or the trainer has written
    /// any scalar of its own.
    init?(events: JSONValue) {
        guard let scalars = events.objectValue?["scalars"]?.objectValue,
              let planned = Self.count(scalars[Self.plannedTag]), planned > 0,
              let ready = Self.count(scalars[Self.readyTag]), ready < planned,
              scalars.keys.allSatisfy({ $0.hasPrefix("regularization/") }) else { return nil }
        self.planned = planned
        self.ready = max(0, ready)
    }

    private static func count(_ point: JSONValue?) -> Int? {
        point?.objectValue?["value"]?.doubleValue.map { Int($0.rounded()) }
    }
}

extension GPUWorkspace {
    /// What the selected model offers; nil when its row does not have the field.
    var regularizationOffer: ModelRow.Regularization? {
        exactModelRow?.regularization
    }

    var repaOffer: ModelRow.Repa? {
        exactModelRow?.repa
    }

    /// Whether the next run draws regularisation images: the model offers them and the person turned them on.
    var usesRegularization: Bool {
        regularizationOffer != nil && regularizationOn
    }

    var usesRepa: Bool {
        repaOffer != nil && repaOn
    }

    /// The triggers of the next run in the order the Triggers field lists them.
    var triggerList: [String] {
        triggerWords.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    /// Each of the next run's triggers with the class noun of the concept it belongs to, if the project has one.
    var triggerClassNouns: [(trigger: String, noun: String?)] {
        triggerList.map { trigger in
            let noun = conceptClassNouns[trigger]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trigger, noun?.isEmpty == false ? noun : nil)
        }
    }

    /// "a woman and a man": what the regularisation images show.
    var regularizationSubjects: String {
        ClassNounPhrase.list(triggerClassNouns.compactMap(\.noun))
    }

    /// The price of the computer the images would be drawn on: the running computer's, else the selected offer's.
    var regularizationHourlyRate: Double? {
        let rate = hasRunningPod ? (saved?.hourlyRate ?? pod?.cost ?? quotedHourlyRate) : quotedHourlyRate
        return rate > 0 ? rate : nil
    }

    var regularizationEstimate: RegularizationEstimate? {
        regularizationOffer.map {
            RegularizationEstimate(
                images: regularizationImages, secondsPerImage: $0.secondsPerImage, hourlyRate: regularizationHourlyRate
            )
        }
    }

    /// The trainer's steps for the next run. With regularisation images on, every even step looks at one of them,
    /// so a length in epochs doubles: "epochs" keeps meaning passes over the person's own images.
    func trainerSteps(items: Int) -> Int {
        let steps = optimizerSteps(items: items)
        return usesRegularization && effectiveModelRow.recipe.lengthUnit == .epochs ? steps * 2 : steps
    }

    // MARK: Choosing and repeating

    /// Applies a newly chosen model's defaults: both toggles take the row's `default_on`, and the image count and
    /// strength move to the new row's values unless the person changed them. A model with no regularisation leaves
    /// them alone, so an edit survives a visit to one.
    func adoptTrainingAidDefaults(to new: ModelRow) {
        regularizationOn = new.regularization?.defaultOn ?? false
        repaOn = new.repa?.defaultOn ?? false
        guard let target = new.regularization else { return }
        if let aligned = regularizationAligned {
            if regularizationImages == aligned.images { regularizationImages = target.images }
            if regularizationWeight == aligned.weight { regularizationWeight = target.weight }
        } else {
            regularizationImages = target.images
            regularizationWeight = target.weight
        }
        regularizationAligned = target
    }

    /// Restores the toggles, image count and strength from a saved run's `regularization` and `repa` blocks.
    /// Generated regularisation images are the only kind the app offers, so a run that used a folder of the
    /// person's own images repeats without regularisation.
    func restoreTrainingAids(from run: TrainingRun) {
        let offered = run.modelRow(in: modelTable)
        let regularization = run.params["regularization"]?.objectValue
        regularizationOn = offered?.regularization != nil && regularization?["source"]?.stringValue == "generate"
        regularizationImages = regularization?["images"]?.intValue
            ?? offered?.regularization?.images ?? regularizationImages
        regularizationWeight = regularization?["weight"]?.doubleValue
            ?? offered?.regularization?.weight ?? regularizationWeight
        for pair in regularization?["class_nouns"]?.objectValue?.pairs ?? [] {
            if let noun = pair.value.stringValue { conceptClassNouns[pair.key] = noun }
        }
        repaOn = offered?.repa != nil && run.params["repa"]?.objectValue != nil
    }

    // MARK: run.json

    /// The `regularization` block for the next run, or nil when it is off or the model does not offer it.
    func regularizationBlock(triggers: [String]) -> JSONObject? {
        guard let offer = regularizationOffer, regularizationOn else { return nil }
        var nouns = JSONObject()
        for trigger in triggers {
            if let noun = conceptClassNouns[trigger] { nouns[trigger] = .string(noun) }
        }
        let generation = repeatedBlock("regularization")?["generation"]?.objectValue ?? [
            "steps": .int(offer.generationSteps), "guidance_scale": .double(offer.guidanceScale), "seed": .int(0),
        ]
        return [
            "source": .string("generate"), "images": .int(regularizationImages),
            "weight": .double(regularizationWeight), "class_nouns": .object(nouns), "generation": .object(generation),
        ]
    }

    /// The `repa` block: the row's six AI Toolkit keys and nothing else. A run being repeated passes on its own.
    func repaBlock() -> JSONObject? {
        guard let offer = repaOffer, repaOn else { return nil }
        return repeatedBlock("repa") ?? [
            "encoder": .string(offer.encoder), "block_index": .int(offer.blockIndex),
            "weight": .double(offer.weight), "projector": .string(offer.projector),
            "projector_dim": .int(offer.projectorDim), "encoder_resolution": .int(offer.encoderResolution),
        ]
    }

    /// A block of the run being repeated, so its explicit values repeat even after the table changed. Only for the
    /// model that run used.
    private func repeatedBlock(_ key: String) -> JSONObject? {
        guard let run = runHistory.first(where: { $0.runID == repeatSourceRunID }),
              run.trainer == trainer, run.baseModel == baseModel else { return nil }
        return run.params[key]?.objectValue
    }

    // MARK: Validation

    func validateTrainingAids() throws {
        guard usesRegularization else { return }
        if let missing = triggerClassNouns.first(where: { $0.noun == nil }) {
            throw StudioError.message(
                "Define a class noun for \(missing.trigger) in Concepts before training with regularisation images."
            )
        }
    }

    // MARK: Progress

    /// Whether the current run draws regularisation images before it trains.
    var runDrawsRegularization: Bool {
        let run = runHistory.first { $0.runID == runID } ?? saved?.run.flatMap { $0.runID == runID ? $0 : nil }
        return run?.params["regularization"]?.objectValue != nil
    }

    /// Asks the pod how many regularisation images are ready, until the trainer reports its first measurement.
    func refreshRegularizationProgress(_ agent: any PodAgent) async {
        guard points.isEmpty, runDrawsRegularization else {
            regularizationProgress = nil
            return
        }
        regularizationProgress = try? await agent.regularizationProgress(runID: runID)
    }
}

// MARK: - Saved runs

extension TrainingRun {
    /// One line per training aid the run used, read from its run.json blocks.
    var trainingAidSummary: [String] {
        var lines: [String] = []
        if let block = params["regularization"]?.objectValue {
            if block["source"]?.stringValue == "folder" {
                let folder = block["path"]?.stringValue ?? "a folder on the computer"
                lines.append("Regularisation: your images (\(folder))")
            } else {
                let nouns = block["class_nouns"]?.objectValue?.pairs.compactMap(\.value.stringValue) ?? []
                let subject = nouns.isEmpty ? "" : " of " + ClassNounPhrase.list(nouns)
                let images = block["images"]?.intValue ?? 0
                let strength = block["weight"]?.doubleValue.map { ", strength " + Self.plain($0) } ?? ""
                lines.append("Regularisation: \(images) drawn images\(subject)\(strength)")
            }
        }
        if let block = params["repa"]?.objectValue {
            let encoder = Self.encoderName(block["encoder"]?.stringValue ?? "")
            let details = [
                encoder.isEmpty ? nil : encoder,
                block["block_index"]?.intValue.map { "block \($0)" },
                block["weight"]?.doubleValue.map { "weight " + Self.plain($0) },
            ].compactMap(\.self)
            lines.append("Representation alignment: on (" + details.joined(separator: ", ") + ")")
        }
        return lines
    }

    /// "DINOv2 giant" for `facebook/dinov2-giant`; any other encoder by its model name.
    static func encoderName(_ id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return name.lowercased().hasPrefix("dinov2-") ? "DINOv2 " + name.dropFirst("dinov2-".count) : name
    }

    /// A number the way people write it: `1` and `0.5`, whatever the Mac's region.
    private static func plain(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
