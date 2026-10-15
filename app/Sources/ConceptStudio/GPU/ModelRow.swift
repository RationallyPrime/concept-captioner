import ConceptCore
import Foundation

/// One supported training model: a row of the model table (docs/model-table.md). Every field is read
/// from `Resources/Training/model-table.json`; nothing here names a model.
struct ModelRow: Sendable, Identifiable, Equatable {
    struct Source: Sendable, Equatable {
        let revision: String?
        let gated: Bool
        let firstDownloadGB: Double
        let downloadNote: String
    }

    struct Architecture: Sendable, Equatable {
        let arch: String?
        let dtype: String
        let quantize: Bool
        let quantizeTextEncoder: Bool?
        let gradientCheckpointing: Bool
        /// Further AI Toolkit `model` keys, in the order the table lists them.
        let modelExtra: JSONObject
    }

    /// Legacy matching of custom base models, used by the pod only.
    struct FamilyMatch: Sendable, Equatable {
        let substrings: [String]
        let tokens: [String]
    }

    struct Resolution: Sendable, Equatable {
        let choices: [Int]
        let defaults: [Int]
        /// One toggle per bucket (true) instead of a single-resolution picker (false).
        let multiple: Bool
    }

    /// Whether a training length counts optimizer steps or passes over each item.
    enum LengthUnit: String, Sendable {
        case steps, epochs

        /// The optimizer steps a run of `length` in this unit takes: steps as given, or passes of `batches` batches
        /// each, which is `ceil(epochs × batches / accumulation)`.
        func optimizerSteps(length: Int, batches: Int, accumulation: Int) -> Int {
            guard self == .epochs else { return length }
            let perStep = max(1, accumulation)
            let passes = length.multipliedReportingOverflow(by: batches)
            guard !passes.overflow else { return Int.max / perStep }
            return passes.partialValue / perStep + (passes.partialValue % perStep == 0 ? 0 : 1)
        }
    }

    struct Checkpoints: Sendable, Equatable {
        let every: Int
        let keep: Int
        let dtype: String?
        /// Advanced shows the three checkpoint controls and the app sends their values.
        let editable: Bool
    }

    struct Recipe: Sendable, Equatable {
        let lengthUnit: LengthUnit
        let length: Int
        let learningRate: Double
        let optimizer: String
        /// AI Toolkit's learning-rate schedule and its warmup steps; nil where the trainer takes them elsewhere (LTX).
        let lrScheduler: String?
        let lrWarmupSteps: Int?
        let rank: Int
        let alpha: Int
        let batchSize: Int
        let gradientAccumulation: Int
        /// The share of training images seen without their caption; nil where the trainer has none (LTX).
        let captionDropout: Double?
        let checkpoints: Checkpoints
    }

    struct GPU: Sendable, Equatable {
        let minVRAMGB: Int
        let verifyOnPod: Bool
        let note: String
        let verifyMessage: String?
    }

    /// Clip training support: valid frame counts are `first + k × step`.
    struct Video: Sendable, Equatable {
        let title: String
        let first: Int
        let step: Int
        let fixedFPS: Int?
        let minFrames: Int
        let initialFrames: Int
        let durationChoices: [Int]?
        let selectWholeClip: Bool
    }

    struct PreviewClips: Sendable, Equatable {
        let minFrames: Int
        let maxFrames: Int
        let choices: [Int]
        let defaultFrames: Int
    }

    struct Preview: Sendable, Equatable {
        let trainingSamples: Bool
        let still: Bool
        let video: PreviewClips?
    }

    struct CaptionTitle: Sendable, Equatable {
        let profile: String
        let title: String
    }

    struct Captions: Sendable, Equatable {
        let imageProfile: String
        let videoProfile: String?
        let profilePrefix: String?
        /// Display titles of this row's profiles, in the table's order.
        let titles: [CaptionTitle]
    }

    struct License: Sendable, Equatable {
        let id: String
        let name: String
        let url: String
        let notice: String
        let showNotice: Bool
    }

    /// Regularisation images the base model draws before training and the trainer looks at beside the subject's
    /// own (`regularization` in docs/model-table.md). A row without the field does not offer them.
    struct Regularization: Sendable, Equatable {
        let defaultOn: Bool
        let images: Int
        let weight: Double
        let generationSteps: Int
        let guidanceScale: Double
        /// Estimated generation time for one image, for the time shown before the images are drawn.
        let secondsPerImage: Double
        let note: String
    }

    /// Representation alignment (`repa` in docs/model-table.md): an auxiliary loss that ties a transformer block's
    /// image tokens to a frozen vision encoder's features. The six AI Toolkit keys go to the pod as they are.
    struct Repa: Sendable, Equatable {
        let defaultOn: Bool
        let encoder: String
        let encoderDownloadGB: Double
        let blockIndex: Int
        let weight: Double
        let projector: String
        let projectorDim: Int
        let encoderResolution: Int
        let note: String
    }

    enum RecipeStatus: String, Sendable {
        case verified, unverified
    }

    let recipeStatus: RecipeStatus
    let trainingNotice: String?
    let id: String
    let displayName: String
    let shortName: String
    let trainer: String
    let modelRef: String
    let source: Source
    let architecture: Architecture
    let familyMatch: FamilyMatch?
    let resolution: Resolution
    let recipe: Recipe
    /// `trainer_options.run_extra`: the exact `extra` object an LTX run sends, in order.
    let runExtra: JSONObject?
    let gpu: GPU
    let video: Video?
    let preview: Preview
    let captions: Captions
    let followsProjectProfile: Bool
    let license: License
    /// A sentence about using a LoRA trained on this model, shown under the picker and on the model card.
    let usageNote: String?
    let hooks: ModelHooks.Assignment
    let notes: String
    let regularization: Regularization?
    let repa: Repa?

    /// The model picker's label: the name and whether the model trains on video too.
    var pickerTitle: String {
        "\(displayName) · \(video == nil ? "images" : "images and video")"
            + (recipeStatus == .unverified ? " · Unverified recipe" : "")
    }
}

// MARK: - Reading a row

struct ModelTableError: Error, LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        "The model table is invalid: " + message
    }
}

/// An object in the table together with where it is, so a bad field names its place.
struct TableObject {
    let object: JSONObject
    let path: String

    init(_ value: JSONValue, path: String) throws {
        guard let object = value.objectValue else { throw ModelTableError("\(path) must be an object") }
        self.object = object
        self.path = path
    }

    private func fail(_ key: String, _ expected: String) -> ModelTableError {
        ModelTableError("\(path).\(key) must be \(expected)")
    }

    func raw(_ key: String) throws -> JSONValue {
        guard let value = object[key] else { throw ModelTableError("\(path).\(key) is missing") }
        return value
    }

    func string(_ key: String) throws -> String {
        guard let value = try raw(key).stringValue else { throw fail(key, "a string") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        let value = try raw(key)
        if value == .null { return nil }
        guard let text = value.stringValue else { throw fail(key, "a string or null") }
        return text
    }

    func int(_ key: String) throws -> Int {
        guard let value = try raw(key).intValue else { throw fail(key, "an integer") }
        return value
    }

    func double(_ key: String) throws -> Double {
        guard let value = try raw(key).doubleValue else { throw fail(key, "a number") }
        return value
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = try raw(key).boolValue else { throw fail(key, "true or false") }
        return value
    }

    func optionalBool(_ key: String) throws -> Bool? {
        let value = try raw(key)
        if value == .null { return nil }
        guard let flag = value.boolValue else { throw fail(key, "true, false or null") }
        return flag
    }

    func optionalDouble(_ key: String) throws -> Double? {
        let value = try raw(key)
        if value == .null { return nil }
        guard let number = value.doubleValue else { throw fail(key, "a number or null") }
        return number
    }

    func optionalInt(_ key: String) throws -> Int? {
        let value = try raw(key)
        if value == .null { return nil }
        guard let number = value.intValue else { throw fail(key, "an integer or null") }
        return number
    }

    func ints(_ key: String) throws -> [Int] {
        guard let items = try raw(key).arrayValue else { throw fail(key, "a list of integers") }
        let numbers = items.compactMap(\.intValue)
        guard numbers.count == items.count else { throw fail(key, "a list of integers") }
        return numbers
    }

    func optionalInts(_ key: String) throws -> [Int]? {
        try raw(key) == .null ? nil : ints(key)
    }

    func strings(_ key: String) throws -> [String] {
        guard let items = try raw(key).arrayValue else { throw fail(key, "a list of strings") }
        let texts = items.compactMap(\.stringValue)
        guard texts.count == items.count else { throw fail(key, "a list of strings") }
        return texts
    }

    /// A field that may be absent but, when present, is a non-empty string.
    func optionalNote(_ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let text = value.stringValue, !text.isEmpty else { throw fail(key, "a non-empty string") }
        return text
    }

    func child(_ key: String) throws -> TableObject {
        try TableObject(raw(key), path: "\(path).\(key)")
    }

    func optionalChild(_ key: String) throws -> TableObject? {
        try raw(key) == .null ? nil : child(key)
    }

    /// A child an optional field may leave out altogether, where `optionalChild` wants an explicit null.
    func childIfPresent(_ key: String) throws -> TableObject? {
        guard let value = object[key], value != .null else { return nil }
        return try child(key)
    }
}

extension ModelRow {
    init(_ row: TableObject) throws {
        guard let status = try RecipeStatus(rawValue: row.string("recipe_status")) else {
            throw ModelTableError("\(row.path).recipe_status must be verified or unverified")
        }
        recipeStatus = status
        trainingNotice = try row.optionalNote("training_notice")
        id = try row.string("id")
        displayName = try row.string("display_name")
        shortName = try row.string("short_name")
        trainer = try row.string("trainer")
        modelRef = try row.string("model_ref")
        source = try Source(row.child("source"))
        architecture = try Architecture(row.child("architecture"))
        familyMatch = try row.optionalChild("family_match").map(FamilyMatch.init)
        resolution = try Resolution(row.child("resolution"))
        recipe = try Recipe(row.child("recipe"))
        // `trainer_options` holds data for one trainer: `run_extra` is the LTX extra the app sends, while `process`
        // (AI Toolkit keys) is read by the pod alone.
        runExtra = try row.childIfPresent("trainer_options")?.childIfPresent("run_extra")?.object
        gpu = try GPU(row.child("gpu"))
        video = try row.optionalChild("video").map(Video.init)
        preview = try Preview(row.child("preview"))
        captions = try Captions(row.child("captions"))
        followsProjectProfile = try row.child("selection").bool("follows_project_profile")
        license = try License(row.child("license"))
        usageNote = try row.optionalNote("usage_note")
        hooks = try ModelHooks.Assignment(row.child("hooks"))
        notes = try row.string("notes")
        regularization = try row.childIfPresent("regularization").map(Regularization.init)
        repa = try row.childIfPresent("repa").map(Repa.init)
    }
}

extension ModelRow.Source {
    init(_ object: TableObject) throws {
        revision = try object.optionalString("revision")
        gated = try object.bool("gated")
        firstDownloadGB = try object.double("first_download_gb")
        downloadNote = try object.string("download_note")
    }
}

extension ModelRow.Architecture {
    init(_ object: TableObject) throws {
        arch = try object.optionalString("arch")
        dtype = try object.string("dtype")
        quantize = try object.bool("quantize")
        quantizeTextEncoder = try object.optionalBool("quantize_text_encoder")
        gradientCheckpointing = try object.bool("gradient_checkpointing")
        modelExtra = try object.child("model_extra").object
    }
}

extension ModelRow.FamilyMatch {
    init(_ object: TableObject) throws {
        substrings = try object.strings("substrings")
        tokens = try object.strings("tokens")
    }
}

extension ModelRow.Resolution {
    init(_ object: TableObject) throws {
        choices = try object.ints("choices")
        defaults = try object.ints("default")
        multiple = try object.bool("multiple")
    }
}

extension ModelRow.Recipe {
    init(_ object: TableObject) throws {
        let length = try object.child("length")
        guard let unit = try ModelRow.LengthUnit(rawValue: length.string("unit")) else {
            throw ModelTableError("\(length.path).unit must be steps or epochs")
        }
        lengthUnit = unit
        self.length = try length.int("value")
        learningRate = try object.double("learning_rate")
        optimizer = try object.string("optimizer")
        lrScheduler = try object.optionalString("lr_scheduler")
        lrWarmupSteps = try object.optionalInt("lr_warmup_steps")
        rank = try object.int("rank")
        alpha = try object.int("alpha")
        batchSize = try object.int("batch_size")
        gradientAccumulation = try object.int("gradient_accumulation")
        captionDropout = try object.optionalDouble("caption_dropout")
        let saved = try object.child("checkpoints")
        checkpoints = try ModelRow.Checkpoints(
            every: saved.int("every"), keep: saved.int("keep"), dtype: saved.optionalString("dtype"),
            editable: saved.bool("editable")
        )
    }
}

extension ModelRow.GPU {
    init(_ object: TableObject) throws {
        minVRAMGB = try object.int("min_vram_gb")
        verifyOnPod = try object.bool("verify_on_pod")
        note = try object.string("note")
        verifyMessage = try object.optionalString("verify_message")
    }
}

extension ModelRow.Video {
    init(_ object: TableObject) throws {
        title = try object.string("title")
        let law = try object.child("frame_law")
        first = try law.int("first")
        step = try law.int("step")
        fixedFPS = try object.optionalInt("fixed_fps")
        minFrames = try object.int("min_frames")
        initialFrames = try object.int("initial_frames")
        durationChoices = try object.optionalInts("duration_choices")
        selectWholeClip = try object.bool("select_whole_clip")
    }

    /// `8n+1` style description of the law.
    var grid: String {
        "\(step)n+\(first)"
    }
}

extension ModelRow.Preview {
    init(_ object: TableObject) throws {
        trainingSamples = try object.bool("training_samples")
        still = try object.bool("still")
        video = try object.optionalChild("video").map { clips in
            try ModelRow.PreviewClips(
                minFrames: clips.int("min_frames"), maxFrames: clips.int("max_frames"),
                choices: clips.ints("choices"), defaultFrames: clips.int("default_frames")
            )
        }
    }
}

extension ModelRow.Captions {
    init(_ object: TableObject) throws {
        imageProfile = try object.string("image_profile")
        videoProfile = try object.optionalString("video_profile")
        profilePrefix = try object.optionalString("profile_prefix")
        let titles = try object.child("titles")
        self.titles = try titles.object.pairs.map { pair in
            guard let title = pair.value.stringValue else {
                throw ModelTableError("\(titles.path).\(pair.key) must be a string")
            }
            return ModelRow.CaptionTitle(profile: pair.key, title: title)
        }
    }
}

extension ModelRow.License {
    init(_ object: TableObject) throws {
        id = try object.string("id")
        name = try object.string("name")
        url = try object.string("url")
        notice = try object.string("notice")
        showNotice = try object.bool("show_notice")
    }
}

extension ModelRow.Regularization {
    init(_ object: TableObject) throws {
        defaultOn = try object.bool("default_on")
        images = try object.int("images")
        weight = try object.double("weight")
        let generation = try object.child("generation")
        generationSteps = try generation.int("steps")
        guidanceScale = try generation.double("guidance_scale")
        secondsPerImage = try generation.double("seconds_per_image")
        note = try object.string("note")
    }
}

extension ModelRow.Repa {
    init(_ object: TableObject) throws {
        defaultOn = try object.bool("default_on")
        encoder = try object.string("encoder")
        encoderDownloadGB = try object.double("encoder_download_gb")
        blockIndex = try object.int("block_index")
        weight = try object.double("weight")
        projector = try object.string("projector")
        projectorDim = try object.int("projector_dim")
        encoderResolution = try object.int("encoder_resolution")
        note = try object.string("note")
    }
}

// MARK: - The two training-aid fields

extension ModelRow {
    /// The architectures the pinned trainer image can align (docs/model-table.md, `repa`); updated together with the
    /// image's patch series.
    static let repaArchitectures = ["qwen_image_2", "zimage"]

    /// Checks that `regularization` and `repa` sit on a row that can carry them; `path` names the row in a message.
    func validateTrainingAids(path: String) throws {
        if regularization != nil {
            let field = "\(path).regularization"
            guard trainer == "aitoolkit" else { throw ModelTableError("\(field) is only for AI Toolkit rows") }
            guard hooks.generator != nil, hooks.trainerConfig == nil else {
                throw ModelTableError("\(field) needs a generator hook and no trainer_config hook")
            }
        }
        if repa != nil {
            let field = "\(path).repa"
            guard trainer == "aitoolkit" else { throw ModelTableError("\(field) is only for AI Toolkit rows") }
            guard let arch = architecture.arch, Self.repaArchitectures.contains(arch) else {
                throw ModelTableError("\(field) needs an architecture the trainer image aligns: "
                    + Self.repaArchitectures.joined(separator: ", "))
            }
        }
    }
}
