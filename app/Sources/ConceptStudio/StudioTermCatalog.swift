import Foundation

struct GlossaryEntry: Decodable, Sendable {
    let id: String
    let term: String
    let sectionId: String
    let aliases: [String]
    let plainLanguage: String
    let goodStuff: String
    let relatedTerms: [String]
    let sourceIds: [String]
    let definitionScope: String
    let displayOrder: Int
}

struct GlossarySection: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
}

struct GlossarySource: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let url: URL
}

/// Supplied educational wording is preserved; separate entries explain operations specific to this app.
struct StudioGlossaryCatalog: Decodable, Sendable {
    struct ModeLabels: Decodable, Sendable {
        let plainLanguage: String
        let goodStuff: String
    }

    let entryCount: Int
    let modeLabels: ModeLabels
    let scopeNote: String
    let sourceNote: String
    let aliasNote: String
    let sections: [GlossarySection]
    let entries: [GlossaryEntry]
    let sources: [GlossarySource]

    static let supplied: StudioGlossaryCatalog = decode("concept-studio-glossary")
    static let operations: [GlossaryEntry] = decode("conceptstudio-operations")
    static let allEntries = supplied.entries + operations
    static let byID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
    static let allSections = supplied.sections + [GlossarySection(
        id: "using-conceptstudio", title: "Using ConceptStudio",
        description: "Accounts, project settings and rented computers in this application."
    )]

    private static func decode<T: Decodable>(_ name: String) -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Glossary") else {
            preconditionFailure("Missing bundled glossary: \(name)")
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("Invalid bundled glossary \(name): \(error)")
        }
    }
}

/// Source IDs identify contextual help, search results and links to related entries.
struct StudioTerm: RawRepresentable, Hashable, Identifiable, CaseIterable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard StudioGlossaryCatalog.byID[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(_ id: String) {
        rawValue = id
    }

    static let train = Self("training")
    static let diffusionModels = Self("diffusion-model")
    static let baseModel = Self("base-model")
    static let concept = Self("concept")
    static let trainingData = Self("dataset")
    static let caption = Self("caption")
    static let conceptBoundary = Self("concept-boundary")
    static let trigger = Self("trigger-word")
    static let classNoun = Self("class-word")
    static let lora = Self("lora")
    static let mapping = Self("subject-mapping")
    static let locator = Self("locator")
    static let captionFormat = Self("caption-format")
    static let provider = Self("provider")
    static let apiKey = Self("api-key")
    static let keychain = Self("keychain")
    static let gateway = Self("gateway")
    static let reviewer = Self("reviewer")
    static let tokens = Self("token")
    static let thinking = Self("thinking")
    static let structuredOutput = Self("structured-output")
    static let datasetRevision = Self("dataset-revision")
    static let gpu = Self("gpu")
    static let vram = Self("gpu-memory")
    static let pod = Self("pod")
    static let networkStorage = Self("network-storage")
    static let containerImage = Self("container-image")
    static let budget = Self("budget")
    static let checkpoint = Self("checkpoint")
    static let resume = Self("resume-training")
    static let warmStart = Self("warm-start")
    static let seed = Self("seed")
    static let prompt = Self("prompt")
    static let trainingSteps = Self("training-step")
    static let learningRate = Self("learning-rate")
    static let rank = Self("rank")
    static let alpha = Self("alpha")
    static let batchSize = Self("batch-size")
    static let gradientAccumulation = Self("gradient-accumulation")
    static let resolution = Self("resolution")
    static let fps = Self("frame-rate")
    static let loss = Self("loss")
    static let precision = Self("precision")
    static let trainingRecipe = Self("training-recipe")
    static let dataset = Self("dataset")
    static let guidancePreservation = Self("guidance-preservation")

    static let introductory: [Self] = [
        .train, .diffusionModels, .baseModel, .concept, .trainingData,
        .caption, .conceptBoundary, .trigger, .classNoun, .lora,
    ]
    static let allCases: [Self] = StudioGlossaryCatalog.allEntries.map { Self($0.id) }

    var id: String {
        rawValue
    }

    var entry: GlossaryEntry {
        StudioGlossaryCatalog.byID[rawValue]!
    }

    var title: String {
        entry.term
    }

    var definition: String {
        entry.plainLanguage
    }

    var technicalDefinition: String {
        entry.goodStuff
    }

    var related: [Self] {
        entry.relatedTerms.compactMap(Self.init(rawValue:))
    }

    var sources: [GlossarySource] {
        entry.sourceIds.compactMap { id in StudioGlossaryCatalog.supplied.sources.first { $0.id == id } }
    }

    /// The owner's original introductory prose keeps its wording while linking to canonical terms.
    private static let introductoryNames: [String: Self] = [
        "train": .train, "diffusion models": .diffusionModels, "training data": .trainingData,
        "trigger": .trigger, "class noun": .classNoun,
    ]

    static func matching(_ text: String) -> Self? {
        if let term = introductoryNames[text.lowercased()] { return term }
        return allCases.first { term in
            ([term.title] + term.entry.aliases).contains { $0.localizedCaseInsensitiveCompare(text) == .orderedSame }
        }
    }

    static func search(_ text: String) -> [Self] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func relevance(_ term: Self) -> Int {
            let names = [term.title] + term.entry.aliases + introductoryNames.filter { $0.value == term }.map(\.key)
            if names.contains(where: { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }) { return 0 }
            if names.contains(where: { $0.localizedStandardContains(query) }) { return 1 }
            return 2
        }
        return allCases.filter { term in
            query.isEmpty || relevance(term) < 2
                || [term.definition, term.technicalDefinition, term.rawValue]
                .contains { $0.localizedStandardContains(query) }
        }.sorted {
            let left = query.isEmpty ? 0 : relevance($0)
            let right = query.isEmpty ? 0 : relevance($1)
            return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left < right
        }
    }
}

enum GlossaryReadingLevel: String, CaseIterable, Identifiable {
    case plain, technical
    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .plain: StudioGlossaryCatalog.supplied.modeLabels.plainLanguage
        case .technical: StudioGlossaryCatalog.supplied.modeLabels.goodStuff
        }
    }
}
