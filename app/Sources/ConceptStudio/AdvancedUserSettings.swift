import ConceptCore
import Foundation

@MainActor
extension StudioSession {
    var advancedAccountOverrides: [String] {
        var values: [String] = []
        if !customBaseURL.isEmpty { values.append("Custom caption server: \(customBaseURL)") }
        if !podImageName.isEmpty { values.append("Training image: \(podImageName)") }
        if !volumeID.isEmpty { values.append("Saved storage: \(volumeID)") }
        return values
    }

    var advancedCaptionOverrides: [String] {
        var values: [String] = []
        if modelThinking != .none { values.append("Thinking effort: \(modelThinking.rawValue)") }
        if useCritic, criticThinking != .none { values.append("Reviewer thinking: \(criticThinking.rawValue)") }
        if outputMode != .native { values.append("Response mode: \(outputMode.rawValue)") }
        if concurrency != 4 { values.append("\(concurrency) samples at once") }
        if endpointKind == "vllm", !requestBaseURL.isEmpty {
            values.append("Project caption server: \(requestBaseURL)")
        }
        return values
    }

    var advancedConceptOverrides: [String] {
        guard let concepts = project?.job.concepts else { return [] }
        var values = concepts.count > 1 ? ["\(concepts.count) concepts trained together"] : []
        for concept in concepts {
            if concept.classNoun != concept.targetConcept.defaultClassNoun {
                values.append("\(concept.trigger) class noun: \(concept.classNoun)")
            }
            let attributes = concept.attributesToDescribe
            if attributes != concept.targetConcept.defaultDescribedAttributes {
                values.append("\(concept.trigger) caption details: " + attributes.joined(separator: ", "))
            }
            for decision in concept.explicitBoundaryDecisions {
                values.append("\(concept.trigger) boundary: \(decision.key): \(decision.value)")
            }
            if !TargetConcept.beginnerChoices.contains(concept.targetConcept) {
                values.append("\(concept.trigger) detailed category: \(concept.targetConcept.title)")
            }
        }
        return values
    }
}

@MainActor
extension GPUWorkspace {
    var advancedTrainingOverrides: [String] {
        advancedRecipeOverrides + advancedExecutionOverrides
    }

    private var advancedRecipeOverrides: [String] {
        let row = effectiveModelRow
        let recipe = row.recipe
        var values: [String] = []
        if exactModelRow == nil { values.append("Custom starting model: \(baseModel)") }
        if row.recipeStatus == .unverified { values.append("Active unverified recipe: \(row.displayName)") }
        if rank != recipe.rank { values.append("LoRA rank: \(rank)") }
        if alpha != recipe.alpha { values.append("LoRA alpha: \(alpha)") }
        if batchSize != recipe.batchSize { values.append("Batch size: \(batchSize)") }
        if accumulation != recipe.gradientAccumulation { values.append("Gradient accumulation: \(accumulation)") }
        if learningRate != recipe.learningRate { values.append("Learning rate: \(learningRate)") }
        if Set(trainingResolutions) != Set(row.resolution.defaults) {
            values.append("Image resolutions: " + trainingResolutions.map { "\($0) px" }.joined(separator: ", "))
        }
        values += trainerSettingOverrideLines
        if usesRegularization, regularizationWeight != regularizationOffer?.weight {
            values.append("Regularisation strength: \(regularizationWeight)")
        }
        if recipe.checkpoints.editable {
            if checkpointEvery != recipe.checkpoints.every { values.append("Save every \(checkpointEvery) steps") }
            if checkpointRetention != recipe.checkpoints
                .keep { values.append("Keep \(checkpointRetention) checkpoints") }
            if checkpointPrecision != modelTable.checkpointPrecision(for: row) {
                values.append("Saved precision: \(checkpointPrecision)")
            }
        }
        return values
    }

    private var advancedExecutionOverrides: [String] {
        var values: [String] = []
        if seed != Self.defaultSeed { values.append("Training seed: \(seed)") }
        if nativeRecipeHook != nil {
            if guidanceLoss { values.append("Guidance preservation loss on") }
            if guidanceTargetText != nativeRecipeHook?.defaultGuidanceTarget {
                values.append("Guidance target: \(guidanceTargetText)")
            }
        }
        if keepCaptionServer {
            values.append("Keep caption model on GPU 0: \(captionModel)")
        }
        if let settings = nativeRecipe?.settings,
           let text = String(data: JSONValue.object(settings).pythonDumpsData(), encoding: .utf8) {
            values.append("Imported trainer settings: \(text)")
        } else if let settings = runHistory.first(where: { $0.runID == repeatSourceRunID })?
            .params["extra"]?.objectValue,
            let text = String(data: JSONValue.object(settings).pythonDumpsData(), encoding: .utf8) {
            values.append("Saved-run trainer settings: \(text)")
        }
        return values
    }

    func advancedInputOverrides(expectedTriggers: String, expectedProfile: String) -> [String] {
        var values: [String] = []
        if triggerWords != expectedTriggers { values.append("Training triggers: \(triggerWords)") }
        if profile != expectedProfile { values.append("Training caption profile: \(profile)") }
        return values
    }
}
