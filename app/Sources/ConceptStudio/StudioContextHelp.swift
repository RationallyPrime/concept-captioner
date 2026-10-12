extension StudioStep {
    /// Definitions follow the operation where their terms first affect a choice.
    var definitionTerms: [StudioTerm] {
        switch self {
        case .images: [.trainingData, .caption, .resolution, .fps]
        case .concepts: [.concept, .conceptBoundary, .trigger, .classNoun, .lora]
        case .mapping: [.mapping, .locator, .conceptBoundary]
        case .captioning: [.provider, .captionFormat, .reviewer, .tokens, .thinking, .structuredOutput]
        case .review: [.caption, .reviewer, .conceptBoundary]
        case .publish: [.dataset, .datasetRevision]
        case .pods: [.gpu, .vram, .pod, .networkStorage, .containerImage, .budget]
        case .training: [.baseModel, .lora, .trainingSteps, .learningRate, .rank, .batchSize]
        case .monitor: [.loss, .checkpoint, .seed, .prompt, .budget]
        }
    }
}
