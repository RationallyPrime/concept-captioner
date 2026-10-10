import ConceptCore
import Foundation

enum DemoScenario: String, CaseIterable, Identifiable {
    case success, unusable, rejected, failed
    var id: String {
        rawValue
    }
}

enum DemoProject {
    static func create() async throws -> StudioProject {
        guard let source = Bundle.module.url(forResource: "Demo", withExtension: nil) else {
            throw StudioError.message("The demo resources are missing. Rebuild the app bundle.")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConceptStudio-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("images"),
            to: destination.appendingPathComponent("images")
        )
        var job = try Job(profile: "flux-image", concepts: [Concept(trigger: "NORA7")])
        for name in ["garden.png", "studio.png", "window.png"] {
            try job.setMapping(["NORA7": "the illustrated person in the center"], for: name)
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
        let mapping = view.objectValue?["inputs"]?.objectValue?["subject_mapping"]?.objectValue ?? [:]
        let words = mapping.keys.joined(separator: " and ")
        let caption = scenario == .unusable
            ? Caption(caption: "", usable: false, note: "Demo: the subject is too obscured. Choose a clearer photo.")
            : Caption(caption: "\(words) wearing a casual top, centered against a soft background in gentle light.")
        return ModelReply(text: caption.jsonValue.pythonDumps(), servedModel: requestedModel)
    }
}
