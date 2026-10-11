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
    /// The caption came from a Hub dataset without a response record of its own. It is kept as a
    /// model caption (`source: model`), so a re-caption with overwrite may replace it unless the
    /// user protects it as final.
    var isImported = false

    static let importedCaptioner = "imported"

    static func isImported(_ record: ResponseRecord?) -> Bool {
        guard let record else { return false }
        return !record.isHumanFinal && record.captioner.requested == importedCaptioner
    }
}

struct StudioProject {
    /// Folder (inside the project) that holds the project's own copy of a custom skill.
    static let skillFolderName = "skill"

    let directory: URL
    var job: Job
    var images: [ProjectImage]
    var imagesDirectory: URL {
        directory.appendingPathComponent("images", isDirectory: true)
    }

    var jobURL: URL {
        directory.appendingPathComponent("job.yaml")
    }

    var skillFolder: URL {
        directory.appendingPathComponent(Self.skillFolderName, isDirectory: true)
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
                isFinal: record?.isHumanFinal ?? false,
                isImported: ProjectImage.isImported(record)
            ))
        }
        return StudioProject(directory: directory, job: job, images: images)
    }

    func save() throws {
        try job.save(to: jobURL)
    }

    /// Write job.yaml only when `updated` differs from what the project already holds.
    /// Returns whether anything was written.
    @discardableResult
    mutating func update(job updated: Job) throws -> Bool {
        guard updated != job else { return false }
        job = updated
        try save()
        return true
    }

    // MARK: Skill

    /// The skill name written into records: the bundled skill's name, or the project skill's folder.
    var skillName: String {
        guard let skill = job.skill else { return Skills.defaultSkillName }
        return URL(fileURLWithPath: skill).lastPathComponent
    }

    /// The project's skill folder: a relative `skill:` resolves against the project directory (the
    /// CLI resolves it against the directory it runs in, which is the project folder); nil for the
    /// bundled skill.
    var skillURL: URL? {
        guard let skill = job.skill else { return nil }
        if skill.hasPrefix("/") || skill.hasPrefix("~") {
            return URL(fileURLWithPath: (skill as NSString).expandingTildeInPath, isDirectory: true)
        }
        return directory.appendingPathComponent(skill, isDirectory: true).standardizedFileURL
    }

    /// True when job.yaml points at a skill outside the project folder, the layout before custom
    /// skills were copied in. The sandbox cannot read such a folder without the user choosing it.
    var skillIsOutsideProject: Bool {
        guard let url = skillURL else { return false }
        return !url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    /// Copy a user-chosen skill into `<project>/skill/<name>/` and point job.yaml at it with a path
    /// relative to the project (`./skill/<name>`), so the project and its published job file carry
    /// the skill with them. The folder is named after the skill because the Agent Skills spec
    /// requires the directory name to match the skill's `name`. Any earlier copy is replaced.
    /// The caller must already have access to `source` (it comes from an open panel).
    @discardableResult
    mutating func adoptSkill(from source: URL) throws -> Skill {
        let chosen = try Skills.load(source)
        let destination = skillFolder.appendingPathComponent(chosen.name, isDirectory: true)
        let relative = "./\(Self.skillFolderName)/\(chosen.name)"
        if source.standardizedFileURL.resolvingSymlinksInPath().path
            == destination.standardizedFileURL.resolvingSymlinksInPath().path {
            try selectSkill(chosen, relativePath: relative)
            return chosen
        }
        let manager = FileManager.default
        let staging = ProjectAppState.folder(in: directory)
            .appendingPathComponent("skill-\(UUID().uuidString)", isDirectory: true)
        let staged = staging.appendingPathComponent(chosen.name, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staged)
        let copied = try Skills.load(staged) // the copy must load on its own, before replacing anything
        if manager.fileExists(atPath: skillFolder.path) { try manager.removeItem(at: skillFolder) }
        try manager.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        try manager.moveItem(at: staged, to: destination)
        try selectSkill(copied, relativePath: relative)
        return try Skills.load(destination)
    }

    /// Go back to the bundled skill: job.yaml gets no `skill` key and the project's copy is removed.
    mutating func useBundledSkill() throws {
        job.skill = nil
        try save()
        if FileManager.default.fileExists(atPath: skillFolder.path) {
            try FileManager.default.removeItem(at: skillFolder)
        }
    }

    private mutating func selectSkill(_ skill: Skill, relativePath: String) throws {
        job.skill = relativePath
        let profiles = skill.profiles()
        if !profiles.contains(job.profile), let first = profiles.first { job.profile = first }
        try save()
    }

    // MARK: Images

    mutating func importFiles(_ files: [URL]) throws {
        for source in files where Sources.imageSuffixes.contains(source.pathExtension.lowercased().withDot) {
            try Task.checkCancellation()
            let target = availableTarget(for: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            images.append(ProjectImage(url: target))
            try job.setMapping(nil, for: target.lastPathComponent)
        }
        try save()
    }

    mutating func importData(_ data: Data, name: String) throws -> String {
        let target = availableTarget(for: URL(fileURLWithPath: name).lastPathComponent)
        try AtomicFile.write(data, to: target)
        images.append(ProjectImage(url: target))
        try job.setMapping(nil, for: target.lastPathComponent)
        try save()
        return target.lastPathComponent
    }

    /// A target in images/ whose stem no existing photo uses (sidecars are named by stem):
    /// `name.ext`, then `name-2.ext`, `name-3.ext`, ...
    func availableTarget(for fileName: String) -> URL {
        let file = URL(fileURLWithPath: fileName)
        let stem = file.deletingPathExtension().lastPathComponent
        let suffix = file.pathExtension
        let taken = Set(images.map { $0.url.deletingPathExtension().lastPathComponent.lowercased() })
        var candidate = stem
        var counter = 1
        while taken.contains(candidate.lowercased())
            || FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent(
                suffix.isEmpty ? candidate : "\(candidate).\(suffix)"
            ).path) {
            counter += 1
            candidate = "\(stem)-\(counter)"
        }
        return imagesDirectory.appendingPathComponent(suffix.isEmpty ? candidate : "\(candidate).\(suffix)")
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
        if let record = outcome.record {
            images[index].isFinal = record.isHumanFinal
            images[index].isImported = ProjectImage.isImported(record)
        }
    }

    mutating func saveCaption(id: String, text: String, final: Bool) async throws {
        try await Self.writeCaption(
            id: id, text: text, final: final, imagesDirectory: imagesDirectory, skill: skillName, profile: job.profile
        )
        applySavedCaption(id: id, text: text, final: final)
    }

    /// Write a caption sidecar and its response record without holding a copy of the project
    /// across the await, so a caption run's results that arrive meanwhile are not lost.
    static func writeCaption(
        id: String, text: String, final: Bool, imagesDirectory: URL, skill: String, profile: String
    ) async throws {
        let sink = try SidecarSink(directory: imagesDirectory)
        var record = try await sink.record(id) ?? ResponseRecord(
            sampleID: id, status: .written, skill: skill, profile: profile,
            captioner: ModelNames(requested: "human"), critic: nil
        )
        record.status = .written
        record.source = final ? "human" : "model"
        record.caption = Caption(caption: text)
        try await sink.write(id, caption: text, record: record)
    }

    mutating func applySavedCaption(id: String, text: String, final: Bool) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].caption = text
        images[index].isFinal = final
        images[index].isImported = images[index].isImported && !final
        images[index].status = .written
    }
}

/// App-only state for one project, kept in `<project>/.conceptstudio/project.json`.
/// It is never published and is not part of job.yaml (the shared contract).
struct HubDestination: Codable, Equatable {
    var repo = ""
    var isPrivate = true

    init(repo: String = "", isPrivate: Bool = true) {
        self.repo = repo
        self.isPrivate = isPrivate
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? ""
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? true
    }
}

struct ProjectAppState: Codable, Equatable {
    static let folderName = ".conceptstudio"
    static let fileName = "project.json"

    /// Where Publish sends the captioned dataset.
    var dataset = HubDestination()
    /// Where the trained LoRA is uploaded (GPU journey).
    var trainingOutput = HubDestination()

    init(dataset: HubDestination = HubDestination(), trainingOutput: HubDestination = HubDestination()) {
        self.dataset = dataset
        self.trainingOutput = trainingOutput
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataset = try container.decodeIfPresent(HubDestination.self, forKey: .dataset) ?? HubDestination()
        trainingOutput = try container.decodeIfPresent(HubDestination.self, forKey: .trainingOutput)
            ?? HubDestination()
    }

    static func folder(in projectDirectory: URL) -> URL {
        projectDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    static func url(in projectDirectory: URL) -> URL {
        folder(in: projectDirectory).appendingPathComponent(fileName)
    }

    /// The saved state, or a blank one when the project has none yet (or it cannot be read).
    static func load(from projectDirectory: URL) -> ProjectAppState {
        guard let data = try? Data(contentsOf: url(in: projectDirectory)),
              let state = try? JSONDecoder().decode(ProjectAppState.self, from: data) else { return ProjectAppState() }
        return state
    }

    func save(to projectDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: Self.folder(in: projectDirectory),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(self), to: Self.url(in: projectDirectory))
    }
}

/// The one way the app shows money. Prices from providers are US dollars; the current locale
/// decides separators and symbol placement.
enum StudioMoney {
    static func format(_ dollars: Double) -> String {
        dollars.formatted(style)
    }

    static func perHour(_ dollars: Double) -> String {
        format(dollars) + "/hour"
    }

    static let style = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(2))
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
