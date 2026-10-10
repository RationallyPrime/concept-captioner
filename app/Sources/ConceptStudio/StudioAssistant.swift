import ConceptCore
import Foundation

struct BoundaryDecision: Decodable {
    let detail: String
    let decision: String
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "detail": .object(["type": .string("string")]),
            "decision": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("detail"), .string("decision")]),
        "additionalProperties": .bool(false),
    ])
}

struct BoundaryDraft: Decodable {
    var learn: [String]
    var describe: [String]
    var decisions: [BoundaryDecision]
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "learn": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "describe": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "decisions": .object(["type": .string("array"), "items": BoundaryDecision.schema]),
        ]),
        "required": .array(["learn", "describe", "decisions"].map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])
}

struct MappingLocator: Decodable {
    let trigger: String
    let locator: String
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "trigger": .object(["type": .string("string")]),
            "locator": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("trigger"), .string("locator")]),
        "additionalProperties": .bool(false),
    ])
}

struct MappingDraft: Decodable {
    let locators: [MappingLocator]
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["locators": .object(["type": .string("array"), "items": MappingLocator.schema])]),
        "required": .array([.string("locators")]), "additionalProperties": .bool(false),
    ])

    func mapping(allowed: Set<String>) -> Job.Mapping {
        var mapping = Job.Mapping()
        for entry in locators where allowed.contains(entry.trigger) && !entry.locator.isEmpty {
            mapping[entry.trigger] = entry.locator
        }
        return mapping
    }
}

struct StudioAssistant {
    let endpoint: ResolvedEndpoint
    let demo: Bool

    func critique(_ project: StudioProject, warnings: [String: ImageAnalysis]) async throws -> String {
        if demo {
            try await Task.sleep(for: .milliseconds(200))
            return "These synthetic portraits share one framing. Add real examples with different angles, "
                + "clothing and backgrounds. Remove duplicates and avoid photos with obscured faces "
                + "before renting a computer."
        }
        let stage = StructuredStage<Caption>(
            name: "dataset advice",
            endpoint: endpoint,
            schemaName: Caption.schemaName,
            schema: Caption.jsonSchema
        )
        var content: [UserContent] = [.text("Intended concepts: " + project.job.jsonValue.pythonDumps()
                + "\nImage warnings: " + warnings.values.flatMap(\.warnings).joined(separator: "; "))]
        for image in project.images {
            try content.append(Self.image(image.url))
        }
        let reply = try await stage.run(
            instructions: "Inspect this training image set. Give concise beginner-friendly advice on repeated "
                + "clothing, backgrounds, variety and visible quality. Put advice in caption; "
                + "this is dataset advice, not a training caption. Do not infer biography.",
            messages: [.user(content)]
        )
        return reply.output.caption
    }

    func draftBoundary(_ description: String) async throws -> BoundaryDraft {
        if demo {
            return BoundaryDraft(
                learn: ["distinctive facial identity"],
                describe: Concept.defaultAttributesToDescribe,
                decisions: [BoundaryDecision(
                    detail: "clothing",
                    decision: "Describe it so it can change in new images."
                )]
            )
        }
        let stage = StructuredStage<BoundaryDraft>(
            name: "boundary draft",
            endpoint: endpoint,
            schemaName: "BoundaryDraft",
            schema: BoundaryDraft.schema
        )
        return try await stage.run(
            instructions: "Help define a diffusion training concept from the user's intended result. "
                + "learn contains only traits the trigger should hold. describe contains things that should stay "
                + "changeable. decisions explains ambiguous boundaries in plain words. "
                + "Treat this as a draft the user must confirm.",
            messages: [.user(description)]
        ).output
    }

    func proposeMapping(image: URL, references: [String: URL]) async throws -> Job.Mapping {
        if demo { return Job.Mapping(references.keys.sorted().map { ($0, "the illustrated person in the center") }) }
        let stage = StructuredStage<MappingDraft>(
            name: "mapping proposal",
            endpoint: endpoint,
            schemaName: "MappingDraft",
            schema: MappingDraft.schema
        )
        var content: [UserContent] = []
        for (trigger, url) in references.sorted(by: { $0.key < $1.key }) {
            try content += [.text("Reference for \(trigger):"), Self.image(url)]
        }
        try content += [.text("Target photo:"), Self.image(image)]
        let reply = try await stage.run(
            instructions: "Compare reference faces to the target. Return locators mapping only supplied triggers "
                + "to visible matching people, using location and clothing to locate each. "
                + "Omit uncertain or absent matches. This is a proposal, not a confirmation.",
            messages: [.user(content)]
        )
        let allowed = Set(references.keys)
        return reply.output.mapping(allowed: allowed)
    }

    private static func image(_ url: URL) throws -> UserContent {
        let encoded = try Images.providerImage(Data(contentsOf: url), suffix: "." + url.pathExtension)
        return .image(data: encoded.data, mediaType: encoded.mediaType)
    }
}
