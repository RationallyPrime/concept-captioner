import ConceptCore
import Foundation
import Yams

/// The effective H3 settings from a native AI Toolkit recipe. Paths, job metadata and
/// counters never enter this projection. The pod consumes the same allow-field resource.
struct NativeTrainingRecipe {
    let settings: JSONObject
    let rank: Int
    let alpha: Int
    let learningRate: Double
    let batchSize: Int
    let accumulation: Int
    let resolutions: [Int]
    var resolution: Int {
        resolutions.max() ?? 512
    }

    static func load(_ data: Data) throws -> NativeTrainingRecipe {
        guard let text = String(data: data, encoding: .utf8), let node = try Yams.compose(yaml: text),
              let document = try JSONValue(yamlNode: node).objectValue else {
            throw StudioError.message("Choose a native AI Toolkit YAML or JSON training recipe.")
        }
        let process: JSONObject
        if let processes = document["config"]?.objectValue?["process"]?.arrayValue {
            guard processes.count == 1, let item = processes.first?.objectValue else {
                throw StudioError.message("Choose a recipe containing one AI Toolkit training process.")
            }
            process = item
        } else { process = document }
        guard let model = process["model"]?.objectValue,
              model["arch"]?.stringValue == "minimax_h3",
              model["name_or_path"]?.stringValue == GPUWorkspace.h3BaseModel else {
            throw StudioError.message("This import accepts a MiniMax H3 recipe for Comfy-Org/MiniMax-H3.")
        }
        let datasets = process["datasets"]?.arrayValue
        guard datasets == nil || datasets?.count == 1 else {
            throw StudioError.message("Choose a recipe with one dataset; this project's approved inputs replace it.")
        }
        var effective = process
        effective["dataset"] = datasets?.first ?? process["dataset"] ?? .object([:])
        var sourceModel = model
        sourceModel["use_training_adapter"] = model["use_training_adapter"]
            ?? .bool(model["assistant_lora_path"]?.stringValue?.isEmpty == false)
        effective["model"] = .object(sourceModel)
        let settings = try projectedSettings(effective, model: model)
        let network = process["network"]?.objectValue ?? [:]
        let train = process["train"]?.objectValue ?? [:]
        let dataset = effective["dataset"]?.objectValue ?? [:]
        let rank = network["linear"]?.intValue ?? 16
        let alpha = network["linear_alpha"]?.intValue ?? rank
        let lr = train["lr"]?.doubleValue ?? 0.0001
        let batch = train["batch_size"]?.intValue ?? 1
        let accumulation = train["gradient_accumulation_steps"]?.intValue
            ?? train["gradient_accumulation"]?.intValue ?? 1
        let resolutions: [Int]
        if let scalar = dataset["resolution"]?.intValue {
            resolutions = [scalar]
        } else if let values = dataset["resolution"]?.arrayValue {
            resolutions = values.compactMap(\.intValue)
            guard values.count == resolutions.count else {
                throw StudioError.message("The imported resolutions must be pixel counts.")
            }
        } else { resolutions = [512] }
        guard rank > 0, alpha > 0, lr.isFinite, lr > 0, lr <= 1, batch > 0, accumulation > 0,
              !resolutions.isEmpty, resolutions.allSatisfy(GPUWorkspace.resolutionChoices.contains) else {
            throw StudioError.message("The imported rank, alpha, learning rate, batch or resolution is unsupported.")
        }
        return NativeTrainingRecipe(
            settings: settings,
            rank: rank,
            alpha: alpha,
            learningRate: lr,
            batchSize: batch,
            accumulation: accumulation,
            resolutions: resolutions
        )
    }

    private static func projectedSettings(_ effective: JSONObject, model: JSONObject) throws -> JSONObject {
        guard let policyURL = Bundle.module.url(
            forResource: "h3-recipe-fields",
            withExtension: "json",
            subdirectory: "Training"
        ) else {
            throw StudioError.message("The included H3 recipe policy is missing. Rebuild the app.")
        }
        let policy = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: policyURL))
        try validateAssets(in: model, policy: policy)
        func filtered(_ input: JSONObject, section: String) throws -> JSONObject {
            var result: JSONObject = [:]
            for key in policy[section] ?? [] {
                guard let value = input[key] else { continue }
                let nested = section + "." + key
                if policy[nested] != nil {
                    guard let object = value.objectValue else {
                        throw StudioError.message("\(nested) must contain settings, not a path or scalar value.")
                    }
                    result[key] = try .object(filtered(object, section: nested))
                } else { result[key] = value }
            }
            return result
        }
        var settings: JSONObject = [:]
        for section in ["model", "network", "train", "dataset"] {
            settings[section] = try .object(filtered(effective[section]?.objectValue ?? [:], section: section))
        }
        return settings
    }

    private static func validateAssets(in model: JSONObject, policy: [String: [String]]) throws {
        let kwargs = model["model_kwargs"]?.objectValue ?? [:]
        if let partition = kwargs["partition"]?.stringValue, partition != "fl2va_pruned" {
            throw StudioError.message("This H3 recipe import supports the fl2va_pruned model partition.")
        }
        var knownFields = Set<String>()
        for (key, fields) in policy where key.hasPrefix("asset_fields.") {
            let component = String(key.dropFirst("asset_fields.".count))
            guard let expected = policy["asset." + component]?.first else { continue }
            for field in fields {
                knownFields.insert(field)
                let value: JSONValue? = field.hasPrefix("model.model_kwargs.")
                    ? kwargs[String(field.dropFirst("model.model_kwargs.".count))]
                    : model[String(field.dropFirst("model.".count))]
                guard let value, value != .null else { continue }
                guard let path = value.stringValue,
                      (path as NSString).lastPathComponent == (expected as NSString).lastPathComponent else {
                    throw StudioError.message("\(field) uses unsupported model weights. Choose the documented "
                        + "H3 component \((expected as NSString).lastPathComponent); no replacement was made.")
                }
            }
        }
        for key in kwargs.keys where key.hasSuffix("_path") {
            guard knownFields.contains("model.model_kwargs." + key) else {
                throw StudioError.message("The recipe's model component \(key) is not supported by this H3 image.")
            }
        }
    }
}

/// Private, copied initializer files for a new run. A saved Resume uses its own captured
/// configuration and checkpoint instead of these files.
struct TrainingInitialization {
    let checkpoint: URL
    let recipe: URL
    let originalRecipe: URL
    let loraSHA256: String
    let recipeSHA256: String

    func upload(to agent: any PodAgent) async throws -> JSONObject {
        let name = "init-" + UUID().uuidString.lowercased()
        for (file, expected) in [(checkpoint, loraSHA256), (recipe, recipeSHA256)] {
            try Task.checkCancellation()
            guard try RunArtifacts.sha256(of: file) == expected else {
                throw StudioError.message("The copied initializer changed. Select the recipe and checkpoint again.")
            }
            let size = try Int64(file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            try await agent.upload(name: name, fileName: file.lastPathComponent, from: file, size: size)
        }
        return [
            "name": .string(name),
            "lora_sha256": .string(loraSHA256),
            "recipe_sha256": .string(recipeSHA256),
        ]
    }
}
