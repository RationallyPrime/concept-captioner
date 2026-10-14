import ConceptCore
import Foundation

/// A named strategy for one concern of a model that the generic behaviour cannot express (docs/model-table.md,
/// "Hooks"). A row names its hooks; the registry is these enums, and a name the app does not know is a load
/// error. Hook names are the only model-specific identifiers allowed outside the table.
enum ModelHooks {
    /// The pod's trainer configuration. The app never reads it; it only has to know the name.
    enum TrainerConfig: String, CaseIterable, Sendable {
        case minimaxH3 = "minimax_h3"
    }

    /// Native recipe import, warm start and the guidance rules that go with them.
    enum NativeRecipe: String, CaseIterable, Sendable {
        case minimaxH3 = "minimax_h3"
    }

    /// How comparison generation runs on the pod. The app only asks whether a row has one.
    enum Generator: String, CaseIterable, Sendable {
        case aitoolkitImage = "aitoolkit_image"
        case aitoolkitArchImage = "aitoolkit_arch_image"
        case ltxOneStage = "ltx_one_stage"
        case minimaxH3 = "minimax_h3"
    }

    /// A change to the trainer's `extra` object depending on the inputs.
    enum RunExtra: String, CaseIterable, Sendable {
        case ltxVideoBuckets = "ltx_video_buckets"
    }

    /// The hooks one row names; an absent concern means the generic behaviour.
    struct Assignment: Sendable, Equatable {
        var trainerConfig: TrainerConfig?
        var nativeRecipe: NativeRecipe?
        var generator: Generator?
        var runExtra: RunExtra?

        init(_ object: TableObject) throws {
            for key in object.object.keys where !["trainer_config", "native_recipe", "generator", "run_extra"]
                .contains(key) {
                throw ModelTableError("\(object.path).\(key) is not a hook concern")
            }
            trainerConfig = try Self.hook(object, "trainer_config")
            nativeRecipe = try Self.hook(object, "native_recipe")
            generator = try Self.hook(object, "generator")
            runExtra = try Self.hook(object, "run_extra")
        }

        private static func hook<Name: RawRepresentable>(_ object: TableObject, _ concern: String) throws -> Name?
            where Name.RawValue == String {
            guard let value = object.object[concern] else { return nil }
            guard let text = value.stringValue, let name = Name(rawValue: text) else {
                throw ModelTableError("\(object.path).\(concern) names a hook this app does not register")
            }
            return name
        }
    }
}

/// The model table: one row per supported training model (docs/model-table.md). Loaded once from the bundled
/// file, which the pod images also carry.
struct ModelTable: Sendable {
    struct Trainer: Sendable, Equatable {
        let name: String
        /// Lowest host CUDA the trainer image needs, as `major.minor`.
        let minimumCUDA: String
        /// The row selected when the trainer changes, and the one a custom base model on it borrows.
        let defaultModel: String
    }

    static let format = "conceptstudio-model-table"
    static let version = 1

    let defaultModelID: String
    let trainers: [Trainer]
    /// In table order: the picker order, the order of video formats and of names in messages.
    let models: [ModelRow]

    /// The bytes of the table bundled with the app.
    static func bundledData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "model-table", withExtension: "json", subdirectory: "Training")
        else { throw ModelTableError("model-table.json is not in the app bundle") }
        return try Data(contentsOf: url)
    }

    /// The table bundled with the app. A table that does not load is a programming error.
    static let shared: ModelTable = {
        do {
            return try ModelTable(parsing: bundledData())
        } catch {
            fatalError("The bundled model table cannot be read: \(error.localizedDescription)")
        }
    }()

    init(parsing data: Data) throws {
        let root = try TableObject(JSONValue(parsing: data), path: "model table")
        guard try root.string("format") == Self.format else {
            throw ModelTableError("format must be \(Self.format)")
        }
        guard try root.int("version") == Self.version else {
            throw ModelTableError("this app reads version \(Self.version) of the table")
        }
        defaultModelID = try root.string("default_model")
        let trainerTable = try root.child("trainers")
        trainers = try trainerTable.object.keys.map { name in
            let trainer = try trainerTable.child(name)
            return try Trainer(
                name: name, minimumCUDA: trainer.string("min_cuda"), defaultModel: trainer.string("default_model")
            )
        }
        guard let rows = try root.raw("models").arrayValue else { throw ModelTableError("models must be a list") }
        models = try rows.enumerated().map { index, row in
            try ModelRow(TableObject(row, path: "models[\(index)]"))
        }
        try validate()
    }

    private func validate() throws {
        guard !models.isEmpty else { throw ModelTableError("the table has no models") }
        guard Set(models.map(\.id)).count == models.count else { throw ModelTableError("row ids must be unique") }
        guard Set(models.map(\.modelRef)).count == models.count else {
            throw ModelTableError("model_ref values must be unique")
        }
        guard models.contains(where: { $0.id == defaultModelID }) else {
            throw ModelTableError("default_model names no row")
        }
        for trainer in trainers {
            guard let row = row(id: trainer.defaultModel), row.trainer == trainer.name else {
                throw ModelTableError("trainers.\(trainer.name).default_model must name a row on that trainer")
            }
        }
    }

    // MARK: Lookups

    var defaultRow: ModelRow {
        guard let row = row(id: defaultModelID) else { fatalError("default_model names no row") }
        return row
    }

    func row(id: String) -> ModelRow? {
        models.first { $0.id == id }
    }

    /// The row whose `model_ref` is `modelRef`; `model_ref` is unique across the table.
    func row(modelRef: String) -> ModelRow? {
        models.first { $0.modelRef == modelRef }
    }

    /// The row for this trainer and base model, if the table has one (case-sensitive).
    func exact(trainer: String, baseModel: String) -> ModelRow? {
        models.first { $0.trainer == trainer && $0.modelRef == baseModel }
    }

    /// The exact row, else the trainer's default row; an unknown trainer uses the table's default model.
    /// This is how a custom base model behaves: like FLUX on AI Toolkit and like LTX-2 on the LTX trainer.
    func effective(trainer: String, baseModel: String) -> ModelRow {
        exact(trainer: trainer, baseModel: baseModel) ?? trainerDefault(trainer)
    }

    func trainerDefault(_ trainer: String) -> ModelRow {
        trainers.first { $0.name == trainer }.flatMap { row(id: $0.defaultModel) } ?? defaultRow
    }

    /// The precision a row saves checkpoints in: its own, else the default model's (LTX has none of its own).
    func checkpointPrecision(for row: ModelRow) -> String {
        row.recipe.checkpoints.dtype ?? defaultRow.recipe.checkpoints.dtype ?? "float16"
    }

    /// Host CUDA floor for a trainer's image; 13.0 for a trainer the table does not know.
    func minimumCUDA(_ trainer: String) -> String {
        trainers.first { $0.name == trainer }?.minimumCUDA ?? "13.0"
    }

    var minimumCUDAByTrainer: [String: String] {
        Dictionary(uniqueKeysWithValues: trainers.map { ($0.name, $0.minimumCUDA) })
    }

    /// The model a caption profile trains by default: the first row whose `profile_prefix` starts it,
    /// else the table's default model.
    func row(forProfile profile: String) -> ModelRow {
        models.first { row in row.captions.profilePrefix.map { profile.hasPrefix($0) } == true } ?? defaultRow
    }

    var videoRows: [ModelRow] {
        models.filter { $0.video != nil }
    }

    func nativeRecipeRow(_ hook: ModelHooks.NativeRecipe) -> ModelRow? {
        models.first { $0.hooks.nativeRecipe == hook }
    }

    var nativeRecipeRows: [ModelRow] {
        models.filter { $0.hooks.nativeRecipe != nil }
    }

    /// Titles of every profile the table names, in table order.
    var captionTitles: [String: String] {
        var titles: [String: String] = [:]
        for row in models {
            for entry in row.captions.titles {
                titles[entry.profile] = entry.title
            }
        }
        return titles
    }

    /// Display names of the models that support comparison generation, as "A, B and C".
    var generationModelList: String {
        Self.sentenceList(models.filter { $0.hooks.generator != nil }.map(\.displayName), conjunction: "and")
    }

    /// "A", "A or B", "A, B or C".
    static func sentenceList(_ names: [String], conjunction: String) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }
}
