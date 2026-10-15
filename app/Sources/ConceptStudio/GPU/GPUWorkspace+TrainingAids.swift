import ConceptCore
import Foundation

// The two optional training aids a model row can offer: regularisation images and representation alignment
// (docs/model-table.md, `regularization` and `repa`). The row says what a model supports and its default values;
// the person chooses whether to use them and how many images. Everything the pod needs travels in run.json
// as explicit values, so a saved run repeats the same way after the table changes. The regularisation images are
// drawn by the pod, then captioned here by the project's own captioner, and run.json carries the captions.

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
    let planned: Int
    let ready: Int

    var text: String {
        "Drawing regularisation images: \(ready) of \(planned)"
    }

    /// Reads the drawing's log, where `[regularization] ready 12/40` follows each finished image; nil before the first.
    static func parse(log: String) -> RegularizationProgress? {
        let prefix = "[regularization] ready "
        for line in log.split(separator: "\n").reversed() where line.hasPrefix(prefix) {
            let counts = line.dropFirst(prefix.count).split(separator: "/").compactMap { Int($0) }
            if counts.count == 2, counts[1] > 0 { return RegularizationProgress(planned: counts[1], ready: counts[0]) }
        }
        return nil
    }
}

/// The project's captioner, ready to describe regularisation images. It holds the endpoint, skill and profile the
/// project captions with and the class nouns of the subjects, never a trigger. `usesPodCaptionServer` says the
/// endpoint is the rented computer's caption server, which has to be running while it works.
struct RegularizationCaptioning {
    let captioner: RegularizationCaptioner
    let usesPodCaptionServer: Bool
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

    /// The distinct class nouns of the next run's triggers, as the person typed them.
    var regularizationClassNouns: [String] {
        var seen = Set<String>()
        return triggerClassNouns.compactMap(\.noun).filter { seen.insert($0.lowercased()).inserted }
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
                images: regularizationImages, secondsPerImage: $0.secondsPerImage * regularizationAreaScale,
                hourlyRate: regularizationHourlyRate
            )
        }
    }

    /// The pictures are drawn at the largest chosen bucket, and the row's time per picture is for its default size:
    /// the estimate grows with the drawn area.
    var regularizationAreaScale: Double {
        let side = Double(resolution) / Double(max(1, effectiveModelRow.resolution.defaults.max() ?? resolution))
        return side * side
    }

    /// The trainer's steps for the next run. With regularisation images on, every even step looks at one of them,
    /// so a length in epochs doubles: "epochs" keeps meaning passes over the person's own images (at each bucket).
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

    // MARK: Drawing and captioning

    /// The captioner for the next run's regularisation images, or nil when it uses none. Built before anything is
    /// uploaded or drawn, so a missing key or skill is reported first.
    func captioningForRegularization(
        _ make: (@MainActor ([String]) throws -> RegularizationCaptioning)?
    ) throws -> RegularizationCaptioning? {
        guard usesRegularization else { return nil }
        guard let make else {
            throw StudioError.message("Regularisation images are described by the captioner of the open project. "
                + "Open the project and start training from the Training screen.")
        }
        return try make(regularizationClassNouns)
    }

    /// The run's params with captions in their `regularization` block. The computer draws the pictures
    /// (`draw-regularization`), the project's captioner describes each one without being told a trigger, and the
    /// block carries the captions to the trainer, which refuses any that holds a trigger. A picture the captioner
    /// finds unusable is left out.
    func captionedRegularization(
        _ params: JSONObject, plan: TrainingPlan, captioning: RegularizationCaptioning?, agent: any PodAgent
    ) async throws -> JSONObject {
        guard !demoMode, let captioning, let block = params["regularization"]?.objectValue else { return params }
        try await prepareCaptionServerForTraining(agent, plan: plan) // a one-GPU computer frees its GPU to draw
        let drawID = "regularization-" + UUID().uuidString.prefix(12).lowercased()
        message = "Drawing regularisation images."
        try await agent.start("draw-regularization", gpus: [plan.train?.gpus.first ?? 0], params: [
            "run_id": .string(drawID), "dataset": params["dataset"] ?? .null,
            "base_model": params["base_model"] ?? .null, "resolution": params["resolution"] ?? .null,
            "regularization": .object(block),
        ])
        try await waitForService("draw-regularization") {
            guard let log = try? await agent.runLog(runID: drawID),
                  let drawing = RegularizationProgress.parse(log: log) else { return }
            self.regularizationProgress = drawing
            self.message = drawing.text
        }
        regularizationProgress = nil
        let files = try await agent.runFiles(runID: drawID).filter { $0.path.hasSuffix(".png") }
        guard !files.isEmpty else {
            throw StudioError.message("The computer drew no regularisation images. Read the log of run \(drawID).")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-" + drawID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var samples: [Sample] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            message = "Downloading regularisation image \(index + 1) of \(files.count)."
            try await download(file, runID: drawID, into: folder, agent: agent)
            let data = try Data(contentsOf: folder.appendingPathComponent(file.path))
            samples.append(Sample(sampleID: Sources.stem(of: file.path), data: data, suffix: ".png"))
        }
        if captioning.usesPodCaptionServer {
            try await ensureCaptionServer(agent, plan: plan, services: agent.services())
        }
        let captions = try await captioning.captioner.captions(of: samples) { done in
            await MainActor.run { self.message = "Describing regularisation images: \(done) of \(samples.count)" }
        }
        guard !captions.isEmpty else {
            throw StudioError.message("The captioner found none of the regularisation images usable.")
        }
        var captioned = params
        var withCaptions = block
        withCaptions["captions"] = .object(JSONObject(
            captions.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) }
        ))
        captioned["regularization"] = .object(withCaptions)
        return captioned
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
