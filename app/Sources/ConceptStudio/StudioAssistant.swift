import ConceptCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// Dataset-level advice: one batch's review, and the merged review across batches.
struct DatasetAdvice: Decodable, Equatable {
    var summary: String
    var suggestions: [String]
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object(["type": .string("string")]),
            "suggestions": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
        ]),
        "required": .array([.string("summary"), .string("suggestions")]),
        "additionalProperties": .bool(false),
    ])

    var text: String {
        ([summary] + suggestions.map { "• " + $0 }).joined(separator: "\n")
    }
}

struct StudioAssistant {
    /// At most this many photos are sent for dataset advice, chosen evenly across the set. Advice is
    /// about variety and repetition, which a sample of this size shows, and it keeps the cost and
    /// request sizes bounded for sets of hundreds of photos.
    static let critiquePhotoLimit = 48
    /// Photos per request. With `critiqueThumbnailPixels` thumbnails a request stays well under
    /// providers' inline image limits (roughly 12 × 60 KB).
    static let critiqueBatchSize = 12
    /// Longest side of the thumbnail sent for each photo; enough to judge framing, clothing,
    /// background and obvious quality problems.
    static let critiqueThumbnailPixels = 512

    let endpoint: ResolvedEndpoint
    let demo: Bool

    func critique(
        _ project: StudioProject,
        warnings: [String: ImageAnalysis],
        progress: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> String {
        if demo {
            try await Task.sleep(for: .milliseconds(200))
            return "These synthetic portraits share one framing. Add real examples with different angles, "
                + "clothing and backgrounds. Remove duplicates and avoid photos with obscured faces "
                + "before renting a computer."
        }
        let sampled = Self.critiqueSample(project.images)
        guard !sampled.isEmpty else { throw StudioError.message("Import photos before asking for dataset advice.") }
        let stage = StructuredStage<DatasetAdvice>(
            name: "dataset advice", endpoint: endpoint, schemaName: "DatasetAdvice", schema: DatasetAdvice.schema
        )
        let concepts = project.job.concepts.map(\.jsonValue)
        var reviews: [DatasetAdvice] = []
        var done = 0
        for batch in stride(from: 0, to: sampled.count, by: Self.critiqueBatchSize).map({
            Array(sampled[$0 ..< min($0 + Self.critiqueBatchSize, sampled.count)])
        }) {
            try Task.checkCancellation()
            let notes = batch.flatMap { image in (warnings[image.id]?.warnings ?? []).map { "\(image.id): \($0)" } }
            var content: [UserContent] = [.text(
                "Intended concepts: " + JSONValue.array(concepts).pythonDumps()
                    + "\nThis request shows \(batch.count) of \(sampled.count) photos reviewed from a set of "
                    + "\(project.images.count).\nOn-device warnings: "
                    + (notes.isEmpty ? "none" : notes.joined(separator: "; "))
            )]
            for image in batch {
                try content += [.text("Photo \(image.id):"), Self.thumbnail(image.url)]
            }
            let reply = try await stage.run(
                instructions: "Inspect these training photos for a diffusion LoRA. Give concise, beginner-friendly "
                    + "advice on repeated clothing, backgrounds, framing, variety and visible quality. summary is "
                    + "two or three sentences; suggestions are at most five specific actions, naming photos where "
                    + "useful. Do not infer biography.",
                messages: [.user(content)]
            )
            reviews.append(reply.output)
            done += batch.count
            await progress(done, sampled.count)
        }
        var advice = reviews[0]
        if reviews.count > 1 {
            let combined = JSONValue.array(reviews.map { review in
                .object([
                    "summary": .string(review.summary),
                    "suggestions": .array(review.suggestions.map(JSONValue.string)),
                ])
            })
            advice = try await stage.run(
                instructions: "These are reviews of consecutive batches of one training photo set. Merge them into "
                    + "one review of the whole set: summary is two or three sentences, suggestions are at most six "
                    + "specific actions. Keep photo names where they help. Drop repetition.",
                messages: [.user(combined.pythonDumps())]
            ).output
        }
        let note = sampled.count < project.images.count
            ? "\n\nReviewed \(sampled.count) of \(project.images.count) photos, chosen evenly across the set."
            : ""
        return advice.text + note
    }

    /// Up to `critiquePhotoLimit` photos spread evenly across the set, in order.
    static func critiqueSample(_ images: [ProjectImage]) -> [ProjectImage] {
        guard images.count > critiquePhotoLimit else { return images }
        return (0 ..< critiquePhotoLimit).map { images[$0 * images.count / critiquePhotoLimit] }
    }

    /// A small JPEG of the photo for dataset advice.
    static func thumbnail(_ url: URL) throws -> UserContent {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: critiqueThumbnailPixels,
              ] as CFDictionary) else {
            throw StudioError.message("\(url.lastPathComponent) could not be read. Remove it or import another copy.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw StudioError.message("A thumbnail could not be prepared for dataset advice.") }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw StudioError.message("A thumbnail could not be prepared for dataset advice.")
        }
        return .image(data: output as Data, mediaType: "image/jpeg")
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
