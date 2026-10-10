import ConceptCore
import Foundation

enum StudioStep: Int, CaseIterable, Identifiable, Codable {
    case images, concepts, mapping, captioning, review, publish, pods, training, monitor

    var id: Int {
        rawValue
    }

    var title: String {
        [
            "Images",
            "Concepts",
            "Mapping",
            "Captioning",
            "Review",
            "Publish",
            "GPU pods",
            "Training",
            "Monitor",
        ][rawValue]
    }

    var explanation: String {
        [
            "Choose the photos that show what you want your model to learn.",
            "Decide what should stay recognizable and what you want to change later.",
            "Confirm who or what each learning word refers to in each photo.",
            "Describe the changeable details so your model can learn the intended concept.",
            "Check the words beside each photo and protect the captions you finish.",
            "Send your dataset to your Hugging Face account so your training computer can read it.",
            "Rent a training computer, with the price and spending limit visible before you start.",
            "Choose how to train, read the plan, and start when you are ready.",
            "Watch your training progress, collect the result, and stop the rented computer.",
        ][rawValue]
    }

    var symbol: String {
        [
            "photo.on.rectangle",
            "sparkles",
            "person.crop.rectangle",
            "text.bubble",
            "checkmark.bubble",
            "arrow.up.doc",
            "server.rack",
            "play.circle",
            "chart.xyaxis.line",
        ][rawValue]
    }
}

struct ProjectImage: Identifiable {
    let url: URL
    var id: String {
        url.lastPathComponent
    }

    var caption = ""
    var status: SampleStatus?
    var notes: [String] = []
    var isFinal = false
}

struct StudioProject {
    let directory: URL
    var job: Job
    var images: [ProjectImage]
    var imagesDirectory: URL {
        directory.appendingPathComponent("images", isDirectory: true)
    }

    var jobURL: URL {
        directory.appendingPathComponent("job.yaml")
    }

    static func create(at directory: URL) throws -> StudioProject {
        let images = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let project = try StudioProject(
            directory: directory,
            job: Job(profile: "flux-image", concepts: [Concept(trigger: "NORA7")]),
            images: []
        )
        guard !FileManager.default.fileExists(atPath: project.jobURL.path) else {
            throw StudioError.message("This folder already contains a project. Choose Open project to continue it.")
        }
        try project.save()
        return project
    }

    static func open(at directory: URL) async throws -> StudioProject {
        let job = try Job.load(contentsOf: directory.appendingPathComponent("job.yaml"))
        let source = try LocalFolderSource(directory: directory.appendingPathComponent("images"))
        let sink = try SidecarSink(directory: source.directory)
        var images: [ProjectImage] = []
        for url in source.files {
            let id = url.lastPathComponent
            let record = try await sink.record(id)
            let caption = (try? String(contentsOf: sink.captionURL(for: id), encoding: .utf8)) ?? ""
            images.append(ProjectImage(
                url: url,
                caption: caption,
                status: record?.status,
                isFinal: record?.isHumanFinal ?? false
            ))
        }
        return StudioProject(directory: directory, job: job, images: images)
    }

    func save() throws {
        try job.save(to: jobURL)
    }

    mutating func importFiles(_ files: [URL]) throws {
        for source in files where Sources.imageSuffixes.contains(source.pathExtension.lowercased().withDot) {
            try Task.checkCancellation()
            var target = imagesDirectory.appendingPathComponent(source.lastPathComponent)
            if images
                .contains(where: {
                    $0.url.deletingPathExtension().lastPathComponent == source.deletingPathExtension().lastPathComponent
                }) {
                target = imagesDirectory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
            }
            try FileManager.default.copyItem(at: source, to: target)
            images.append(ProjectImage(url: target))
            try job.setMapping(nil, for: target.lastPathComponent)
        }
        try save()
    }

    mutating func importData(_ data: Data, name: String) throws -> String {
        var target = imagesDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        if images
            .contains(where: {
                $0.url.deletingPathExtension().lastPathComponent == target.deletingPathExtension().lastPathComponent
            }) {
            target = imagesDirectory.appendingPathComponent("\(UUID().uuidString)-\(target.lastPathComponent)")
        }
        try AtomicFile.write(data, to: target)
        images.append(ProjectImage(url: target))
        try job.setMapping(nil, for: target.lastPathComponent)
        try save()
        return target.lastPathComponent
    }

    func referenceURL(for trigger: String) -> URL {
        let name = trigger.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("references", isDirectory: true).appendingPathComponent(name + ".png")
    }

    mutating func apply(_ outcome: Outcome) {
        guard let index = images.firstIndex(where: { $0.id == outcome.sampleID }) else { return }
        images[index].status = outcome.status
        images[index].notes = outcome.notes
        if let caption = outcome.caption { images[index].caption = caption }
        if let record = outcome.record { images[index].isFinal = record.isHumanFinal }
    }

    mutating func saveCaption(id: String, text: String, final: Bool) async throws {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let sink = try SidecarSink(directory: imagesDirectory)
        var record = try await sink.record(id) ?? ResponseRecord(
            sampleID: id, status: .written, skill: "diffusion-training-captioner", profile: job.profile,
            captioner: ModelNames(requested: "human"), critic: nil
        )
        record.status = .written
        record.source = final ? "human" : "model"
        record.caption = Caption(caption: text)
        try await sink.write(id, caption: text, record: record)
        images[index].caption = text
        images[index].isFinal = final
        images[index].status = .written
    }
}

enum StudioError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

private extension String {
    var withDot: String {
        "." + self
    }
}
