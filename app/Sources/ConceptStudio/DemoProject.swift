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
        for name in ["garden.png", "studio.png", "window.png"] {
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
        settings: RequestSettings
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
        let samples = [
            "garden": "\(words), a person, wearing a dark green knitted cardigan over a cream top, "
                + "standing in a garden with a stone wall and leafy plants behind them. "
                + "Waist-up front view with a relaxed expression in soft, diffuse daylight.",
            "studio": "\(words), a person, seated at an angle in a blue denim shirt with rolled sleeves, "
                + "looking toward the camera with a slight smile. Upper-body three-quarter view against "
                + "a plain light grey background in soft, even light.",
            "window": "\(words), a person, wearing a burgundy knitted turtleneck, standing beside a window "
                + "with their body turned to the side and face toward the camera. Warm light falls from "
                + "the left; a bookshelf and plants are softly blurred in the background.",
        ]
        let inputs = messages.flatMap(\.content)
        guard let directory = Bundle.module.url(forResource: "Demo", withExtension: nil) else {
            throw StudioError.message("The prepared demo resources are missing.")
        }
        for (name, caption) in samples {
            let url = directory.appendingPathComponent("images/\(name).png")
            let media = try MediaInput.content(data: Data(contentsOf: url), suffix: ".png")
            if inputs.contains(media) { return caption }
        }
        throw StudioError.message("The offline demo has prepared captions for its three original images. "
            + "Reopen the demo to restore them, or use a real project and captioning provider for edited targets.")
    }
}
