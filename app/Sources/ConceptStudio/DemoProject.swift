import ConceptCore
import Foundation

enum DemoScenario: String, CaseIterable, Identifiable {
    case success, unusable, rejected, failed
    var id: String {
        rawValue
    }
}

enum DemoProject {
    /// The one place the offline demo lives. "Try the demo" replaces it and closing the demo
    /// removes it, so demo copies never pile up.
    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ConceptStudio-demo", isDirectory: true)
    }

    static func create(at destination: URL = defaultDirectory) async throws -> StudioProject {
        guard let source = Bundle.module.url(forResource: "Demo", withExtension: nil) else {
            throw StudioError.message("The demo resources are missing. Rebuild the app bundle.")
        }
        remove(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("images"),
            to: destination.appendingPathComponent("images")
        )
        var job = try Job(profile: "flux-image", concepts: [Concept(trigger: "NORA7")])
        for name in preparedCaptions.keys.map({ $0 + ".jpg" }) {
            try job.setMapping(["NORA7": "the person shown in this synthetic photograph"], for: name)
        }
        try job.save(to: destination.appendingPathComponent("job.yaml"))
        let project = try await StudioProject.open(at: destination)
        let reference = project.referenceURL(for: "NORA7")
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: project.images[0].url, to: reference)
        return project
    }

    /// One caption per practice photo, after the trigger and class noun: clothing, pose, setting and
    /// light, never the face or hair the trigger stands for.
    static let preparedCaptions: [String: String] = [
        "window": "wearing a burgundy knitted turtleneck, standing beside a window with their body turned to the "
            + "side and face toward the camera. Warm light falls from the left; a bookshelf and plants are softly "
            + "blurred in the background.",
        "cafe": "sitting at a wooden cafe table in a camel wrap cardigan over a cream top, holding a white coffee "
            +
            "cup with both hands. Pendant lights, a chalkboard menu and an espresso machine are softly blurred behind.",
        "studio": "in a plain black long-sleeved top, turned slightly to the side with a slight smile, in a studio "
            + "portrait against a plain grey backdrop under soft, even light.",
        "kitchen": "wearing a grey and white striped apron over a white long-sleeved top in a bright kitchen, open "
            + "shelves of jars and books behind. Soft window light from the left.",
        "beach": "in a black tank top on a sandy beach, the sea and a clear blue sky behind, in bright midday light.",
        "street": "wearing a dark wool coat and a black scarf on a city pavement in front of shop windows, looking "
            + "back toward the camera in overcast daylight.",
        "library": "in a black button-up shirt holding an open book between tall wooden library shelves, in warm, "
            + "low light.",
        "park-cap": "wearing a navy baseball cap and a navy zip jacket in a green park, trees and sunlit grass behind.",
        "looking-down": "in a black V-neck sweater, eyes lowered, against a plain warm grey wall in soft, "
            + "diffuse light.",
        "bed": "lying on a bed in a cream cable-knit sweater, head on a white pillow, looking at the camera in soft "
            + "indoor light.",
        "sunset": "wearing a navy floral sundress with thin straps by the sea at sunset, the sun low over the water.",
        "mirror-selfie": "taking a mirror selfie with a phone in a grey tank top and light jeans, an unmade white bed "
            + "in a bright bedroom behind.",
        "gym": "in a black sports top and black leggings in a gym, weight racks and machines softly blurred behind.",
        "sunglasses": "wearing dark sunglasses and a black tank top on a sunny tree-lined path, smiling, in dappled "
            + "daylight.",
        "flower-market": "in a light denim jacket over a white T-shirt holding a bunch of pink roses at a flower "
            + "market, stalls and shoppers behind.",
        "eyes-closed": "a close-up with eyes closed and a calm expression, in a cream knit top against a plain beige "
            + "background in gentle daylight.",
        "chin-on-hand": "in a black sweater resting their chin on one hand at a cafe window seat, smiling softly in "
            + "daylight from the left.",
        "autumn-park": "wearing a navy wool coat and a grey scarf in a park with golden autumn leaves on the ground "
            + "and trees behind.",
        "brick-wall": "in a black long-sleeved top leaning against a red brick wall, looking at the camera in soft "
            + "daylight.",
        "cat": "in a white T-shirt holding a tabby cat in a sunny living room with a grey sofa behind.",
        "rooftop": "wearing a black leather jacket over a black top on a rooftop terrace, a city skyline behind in "
            + "late afternoon light.",
        "smiling": "in a white linen blouse, smiling broadly at the camera in a bright kitchen with white cabinets.",
        "over-shoulder": "in a grey camisole looking back over their shoulder in a bright room full of green indoor "
            + "plants.",
        "garden": "wearing a dark green cardigan over a burgundy turtleneck, sitting on a weathered wooden garden "
            + "bench with shrubs behind in overcast daylight.",
    ]

    /// Remove a demo copy. Only ever called with a demo directory, never a user's project.
    static func remove(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct DemoModelClient: ModelClient {
    var requestedModel = "demo-captioner"
    var scenario: DemoScenario = .success

    func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ModelReply {
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        if scenario ==
            .failed { throw StudioError.message("Demo connection interrupted. Choose Success and try again.") }
        if output.name == Critique.schemaName {
            return ModelReply(
                text: Critique(
                    approved: scenario != .rejected,
                    notes: scenario == .rejected ?
                        ["Demo critic asks for a clearer description."] : []
                )
                .jsonValue.pythonDumps(),
                servedModel: requestedModel
            )
        }
        let configuration = instructions.components(separatedBy: "ACTIVE JOB CONFIGURATION\n")
            .last?.components(separatedBy: "\n").first ?? "{}"
        let view = try JSONValue(parsing: configuration)
        let concepts = view.objectValue?["concepts"]?.arrayValue ?? []
        guard concepts.count == 1,
              concepts.first?.objectValue?["target_concept"]?.stringValue == "facial_identity" else {
            throw StudioError.message("The demo captions demonstrate one person's facial identity. "
                + "Reopen the demo to restore that concept, or create a real project for another category.")
        }
        let mapping = view.objectValue?["inputs"]?.objectValue?["subject_mapping"]?.objectValue ?? [:]
        let words = mapping.keys.joined(separator: " and ")
        let caption = try scenario == .unusable
            ? Caption(caption: "", usable: false, note: "Demo: the subject is too obscured. Choose a clearer photo.")
            : Caption(caption: Self.preparedCaption(words: words, messages: messages))
        return ModelReply(text: caption.jsonValue.pythonDumps(), servedModel: requestedModel)
    }

    /// Prepared text matched to the actual demo asset; this is an offline walkthrough, not model inference.
    private static func preparedCaption(words: String, messages: [ChatMessage]) throws -> String {
        let inputs = messages.flatMap(\.content)
        guard let directory = Bundle.module.url(forResource: "Demo", withExtension: nil) else {
            throw StudioError.message("The prepared demo resources are missing.")
        }
        for (name, caption) in DemoProject.preparedCaptions {
            let url = directory.appendingPathComponent("images/\(name).jpg")
            let media = try MediaInput.content(data: Data(contentsOf: url), suffix: ".jpg")
            if inputs.contains(media) { return "\(words), a person, " + caption }
        }
        throw StudioError.message("The offline demo has prepared captions for its own practice photos. "
            + "Reopen the demo to restore them, or use a real project and captioning provider for edited targets.")
    }
}
