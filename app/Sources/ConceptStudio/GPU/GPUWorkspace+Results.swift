import ConceptCore
import CryptoKit
import Foundation

/// Where a training run's result ended up. Persisted with the pod record, under its own key so it
/// outlives Remove (the run stays on the network volume), and in the project's app file.
struct TrainingResult: Codable, Equatable {
    enum Destination: String, Codable {
        /// Pushed by the trainer on finish (`hub.push_on_finish`) to a private model repo.
        case hub
        /// Downloaded through the agent into `<project>/results/<run-id>/`.
        case download
    }

    enum State: Codable, Equatable {
        case training
        /// Finished with a LoRA on the volume that is neither pushed nor downloaded.
        case pending
        case pushed(repo: String)
        case saved(folder: String)
        /// Ended without producing a LoRA.
        case failed
    }

    let runID: String
    var outputRepo: String
    var destination: Destination
    /// The network volume holding `/workspace/runs/<run-id>`.
    let volumeID: String
    var state: State

    var summary: String {
        switch state {
        case .training: "Training"
        case .pending: "Finished; not yet saved"
        case let .pushed(repo): "Pushed to \(repo)"
        case let .saved(folder): "Saved to \(folder)"
        case .failed: "Ended without a trained model"
        }
    }
}

enum RunArtifacts {
    static func validRunID(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\z", options: .regularExpression) != nil
    }

    private static let keptExtensions: Set = ["safetensors", "yaml", "yml", "json", "txt", "log"]
    private static let sampleExtensions: Set = ["png", "jpg", "jpeg", "webp", "mp4", "gif"]

    /// What a user keeps from a run: the final LoRA (newest when several checkpoints exist), the
    /// trainer's emitted config and run files, and any samples. Event files and LTX's preprocessed
    /// latents stay on the volume.
    static func selection(_ files: [RunFile]) -> [RunFile] {
        let usable = files.filter { file in
            let parts = file.path.split(separator: "/")
            return !parts.contains("..") && !file.path.hasPrefix("/")
                && !parts.contains("tensorboard") && !parts.contains("preprocessed")
        }
        let weights = usable.filter { $0.path.hasSuffix(".safetensors") }
        guard let final = newest(weights) else { return [] }
        let others = usable.filter { file in
            let ext = (file.path as NSString).pathExtension.lowercased()
            let isSample = file.path.split(separator: "/").contains("samples") && sampleExtensions.contains(ext)
            return ext != "safetensors" && (keptExtensions.contains(ext) || isSample)
        }
        return [final] + others
    }

    /// Newest by modification time (the agent's `modified_at`); on a tie, or when a time is
    /// missing, the un-numbered final file beats a checkpoint and a later step beats an earlier one.
    /// Run ids end in hex digits (`concept-1a2b3c4d-567`), so only an `_`-separated run of digits
    /// (ai-toolkit's `<name>_000001750`) counts as a step number.
    static func newest(_ weights: [RunFile]) -> RunFile? {
        let timed = weights.allSatisfy { $0.modifiedAt != nil }
        return weights.max { left, right in
            if timed, left.modifiedAt != right.modifiedAt { return left.modifiedAt! < right.modifiedAt! }
            return rank(left) < rank(right)
        }
    }

    /// `(1, 0)` for an un-numbered file, `(0, step)` for `<name>_<step>` with three or more digits.
    private static func rank(_ file: RunFile) -> (Int, Int) {
        let stem = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let separator = stem.lastIndex(of: "_") else { return (1, 0) }
        let digits = stem[stem.index(after: separator)...]
        let isStep = digits.count >= 3 && digits.allSatisfy { $0.isASCII && $0.isNumber }
        guard isStep, let step = Int(digits) else { return (1, 0) }
        return (0, step)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The app-only training file inside a project folder, `<project>/.conceptstudio/training.json`:
/// the project's training results only. It is never published and is not part of job.yaml. The
/// output repo and its privacy live in the project's app state (`ProjectAppState.trainingOutput`),
/// which the session hands to `outputRepo` and `privateResult`.
struct ProjectTrainingRecord: Codable, Equatable {
    var results: [TrainingResult] = []
    var runs: [TrainingRun] = []
    var comparisons: [GeneratedComparison] = []

    init(results: [TrainingResult] = []) {
        self.results = results
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        results = try (values.decodeIfPresent([TrainingResult].self, forKey: .results) ?? [])
            .filter { RunArtifacts.validRunID($0.runID) }
        runs = try (values.decodeIfPresent([TrainingRun].self, forKey: .runs) ?? [])
            .filter { RunArtifacts.validRunID($0.runID) }
        comparisons = try (values.decodeIfPresent([GeneratedComparison].self, forKey: .comparisons) ?? [])
            .filter { RunArtifacts.validRunID($0.runID) && RunArtifacts.validRunID($0.sourceRunID) }
    }

    static func url(in project: URL) -> URL {
        project.appendingPathComponent(".conceptstudio/training.json")
    }

    static func load(from project: URL) -> ProjectTrainingRecord {
        guard let data = try? Data(contentsOf: url(in: project)) else { return ProjectTrainingRecord() }
        guard var record = try? JSONDecoder().decode(Self.self, from: data) else { return ProjectTrainingRecord() }
        func confined(_ folder: String, runID: String) -> Bool {
            let expected = project.resolvingSymlinksInPath().appendingPathComponent("results/\(runID)")
            let actual = URL(fileURLWithPath: folder).standardizedFileURL
            return actual.resolvingSymlinksInPath().path == expected.path
        }
        func checked(_ result: TrainingResult) -> TrainingResult {
            var result = result
            if case let .saved(folder) = result.state, !confined(folder, runID: result.runID) {
                result.state = .pending
            }
            return result
        }
        record.results = record.results.map(checked)
        for index in record.runs.indices {
            if let folder = record.runs[index].localFolder, !confined(folder, runID: record.runs[index].runID) {
                record.runs[index].localFolder = nil
            }
            record.runs[index].result = record.runs[index].result.map(checked)
        }
        for index in record.comparisons.indices {
            if let folder = record.comparisons[index].folder,
               !confined(folder, runID: record.comparisons[index].runID) {
                record.comparisons[index].folder = nil
                if record.comparisons[index].state == .saved { record.comparisons[index].state = .pending }
            }
        }
        return record
    }

    func save(to project: URL) throws {
        let url = Self.url(in: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Keeps the Mac out of idle sleep (and the app out of App Nap) while a pod bills, so the budget
/// and idle guards keep running. Closing the lid without an external display still sleeps the Mac.
@MainActor
final class SleepAssertion {
    private let begin: () -> any NSObjectProtocol
    private let end: (any NSObjectProtocol) -> Void
    private var activity: (any NSObjectProtocol)?

    init(begin: @escaping () -> any NSObjectProtocol, end: @escaping (any NSObjectProtocol) -> Void) {
        self.begin = begin
        self.end = end
    }

    static func system() -> SleepAssertion {
        SleepAssertion(
            begin: {
                ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "A rented GPU is billing; its spending limit and idle stop need this Mac awake."
                )
            },
            end: { ProcessInfo.processInfo.endActivity($0) }
        )
    }

    var isHeld: Bool {
        activity != nil
    }

    func hold(_ wanted: Bool) {
        if wanted, activity == nil {
            activity = begin()
        } else if !wanted, let activity {
            end(activity)
            self.activity = nil
        }
    }
}

extension GPUWorkspace {
    /// Finds running pods this app created that the local record does not know about (a record
    /// lost to a crash between create and save, reset defaults, another Mac) and puts the newest
    /// under the budget and idle guards; the rest are listed in `strayPods`.
    func reconcile() async {
        guard let provider else { return }
        let found: [RentedPod]
        do {
            found = try await provider.list()
        } catch {
            reconciled = false // the next configure (key or settings change) tries again
            let warning = "Could not check your RunPod account for computers this app left running "
                + "(\(error.localizedDescription)). Open the RunPod console to make sure nothing is billing."
            message = warning
            failure = warning
            return
        }
        let running = found.filter(\.isRunning)
        if pod == nil, let adopted = running.first {
            saved = SavedPod(
                pod: adopted, started: Date(), hourlyRate: adopted.cost, budget: budget, trainer: trainer,
                runID: "", outputRepo: outputRepo, idleMinutes: idleMinutes, volumeID: adopted.volumeID ?? ""
            )
            pod = adopted
            restoreAgentToken(podID: adopted.id)
            connectAgent(adopted)
            lastActivity = Date()
            persist()
            watch()
            message = "Found a running computer this app created (\(adopted.name ?? adopted.id)) that this Mac "
                + "had lost track of. Its spending limit and idle stop apply from now; stop it if you do not need it."
        }
        strayPods = running.filter { $0.id != pod?.id }
        if !strayPods.isEmpty {
            message = "\(strayPods.count) more running computer(s) from this app are billing on your RunPod "
                + "account. Stop them below or in RunPod."
        }
    }

    func stopStrayPod(id: String) async {
        guard let provider else { return }
        do {
            try await provider.stop(id: id)
            strayPods.removeAll { $0.id == id }
            message = "Stop was sent to that computer. Its saved storage remains."
        } catch { message = error.localizedDescription }
    }

    /// Moves the latest run's result on once its trainer has stopped: a run pushed on finish is
    /// done; anything else with weights on the volume is pending and retrieved automatically.
    func settleResult(_ agent: any PodAgent, services: [AgentService]) async throws {
        guard let result, resultIsOnThisPod(result) else { return }
        switch result.state {
        case .training:
            let trainers = services.filter { $0.name.hasPrefix("trainer-") }
            let own = trainers.first { $0.runID == result.runID }
            if own?.active == true { return }
            // No trainer reports the run when the agent restarted (its state is in memory only);
            // the files on the volume then decide.
            if own == nil, trainers.contains(where: \.active) { return }
            if own?.state == "exited", result.destination == .hub {
                updateResult(.pushed(repo: result.outputRepo))
                message = "Training finished and the LoRA was pushed to \(result.outputRepo)."
                return
            }
            guard try await !RunArtifacts.selection(agent.runFiles(runID: result.runID)).isEmpty else {
                updateResult(.failed)
                message = "The training run ended without a trained model. Read its log for the cause."
                return
            }
            updateResult(.pending)
            message = "Training finished. Saving the LoRA before the computer can be stopped."
            startAutomaticRetrieval()
        case .pending:
            startAutomaticRetrieval()
        default:
            return
        }
    }

    /// True when a finished LoRA sits on this pod's volume and has been neither pushed nor saved.
    var resultNeedsSaving: Bool {
        if let generation, generation.state == .pending, hasRunningPod,
           generation.volumeID == currentVolumeID { return true }
        guard let result, result.state == .pending, hasRunningPod else { return false }
        return resultIsOnThisPod(result)
    }

    /// True while the latest run on this pod's volume has not been settled (still training, or its
    /// trainer exited and the check of its files has not succeeded yet).
    var resultUnsettled: Bool {
        if let generation, generation.state == .generating, hasRunningPod,
           generation.volumeID == currentVolumeID { return true }
        guard let result, result.state == .training, hasRunningPod else { return false }
        return resultIsOnThisPod(result)
    }

    func resultIsOnThisPod(_ result: TrainingResult) -> Bool {
        result.volumeID.isEmpty || currentVolumeID.isEmpty || result.volumeID == currentVolumeID
    }

    func startAutomaticRetrieval() {
        guard retrievalTask == nil, !isBusy, !isStopping,
              Date().timeIntervalSince(lastAutomaticRetrieval) >= automaticRetrievalInterval else { return }
        lastAutomaticRetrieval = Date()
        retrievalTask = Task {
            await self.retrieveResult()
            self.retrievalTask = nil
        }
    }

    /// Saves a pending result: pushes it when it was meant for the Hub (falling back to a download
    /// if the push fails), else downloads it through the agent and verifies every file's sha256.
    func retrieveResult() async {
        await perform {
            if self.generation?.state == .pending { try await self.retrieveGeneration() }
            if self.result?.state == .pending { try await self.retrievePendingResult() }
        }
    }

    private func retrievePendingResult() async throws {
        guard let result, result.state == .pending else {
            throw StudioError.message("There is no finished training result waiting to be saved.")
        }
        guard projectFolder == nil || projectOwnsRun(result.runID) else {
            throw StudioError.message("Open this training run's original project before retrieving its outputs.")
        }
        guard let agent, hasRunningPod, resultIsOnThisPod(result) else {
            throw StudioError.message(
                "Rent a computer on the storage that holds run \(result.runID), then retrieve it."
            )
        }
        if result.destination == .hub, canPushToHub, !result.outputRepo.isEmpty {
            do {
                message = "Pushing the LoRA to \(result.outputRepo)…"
                try await agent.start("push-lora", gpus: [], params: [
                    "run_id": .string(result.runID), "repo_id": .string(result.outputRepo),
                    "private": .bool(privateResult),
                ])
                try await waitForService("push-lora")
                updateResult(.pushed(repo: result.outputRepo))
                message = "Your LoRA was pushed to \(result.outputRepo)."
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                message = "The push to \(result.outputRepo) failed; saving the LoRA to this Mac instead."
            }
        }
        let folder = try resultsFolder(for: result.runID)
        let files = try await RunArtifacts.selection(agent.runFiles(runID: result.runID))
        guard !files.isEmpty else {
            throw StudioError.message("No trained model was found for run \(result.runID).")
        }
        for file in files {
            try Task.checkCancellation()
            message = "Downloading \(file.path)…"
            try await download(file, runID: result.runID, into: folder, agent: agent)
        }
        updateResult(.saved(folder: folder.path))
        message = "Your LoRA was saved to \(folder.path)."
    }

    func download(_ file: RunFile, runID: String, into folder: URL, agent: any PodAgent) async throws {
        let manager = FileManager.default
        guard RunArtifacts.validRunID(runID) else { throw StudioError.message("Invalid saved run identifier.") }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let destination = root.appendingPathComponent(file.path).standardizedFileURL
        // Foundation can leave a nonexistent leaf unresolved. Inspect every existing parent
        // before creating directories, so a nested symlink cannot redirect that creation.
        let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { ["", ".", ".."].contains(String($0)) }) else {
            throw StudioError.message("The computer listed an invalid run file: \(file.path).")
        }
        var parent = root
        for part in parts.dropLast() {
            parent.appendPathComponent(String(part))
            if (try? manager.destinationOfSymbolicLink(atPath: parent.path)) != nil {
                throw StudioError.message("The run file's parent is a symbolic link: \(file.path).")
            }
        }
        guard destination.path.hasPrefix(root.path + "/"),
              destination.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
              || destination.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path,
              destination.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw StudioError.message("The computer listed a file outside the run: \(file.path).")
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        // A stale partial is disposable; remove it before the downloader opens it.
        try? manager.removeItem(at: partial)
        defer { try? manager.removeItem(at: partial) }
        try await agent.download(runID: runID, path: file.path, to: partial)
        guard try RunArtifacts.sha256(of: partial) == file.sha256.lowercased() else {
            throw StudioError.message("\(file.path) arrived damaged (checksum mismatch). Retrieve it again.")
        }
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: partial, to: destination)
    }

    /// Keeps an unfinished or unsaved result under its own key so it outlives Remove: the run stays
    /// on the network volume and the next computer on that volume retrieves it.
    func persistResult() {
        guard !demoMode else { return }
        if let result, [.training, .pending].contains(result.state),
           let data = try? JSONEncoder().encode(result) {
            preferences.set(data, forKey: Self.pendingResultKey)
        } else {
            preferences.removeObject(forKey: Self.pendingResultKey)
        }
    }

    /// Stops tracking the latest result; its files stay on the network volume.
    func forgetResult() {
        result = nil
        persist()
        persistResult()
    }

    func updateResult(_ state: TrainingResult.State) {
        guard var result else { return }
        result.state = state
        self.result = result
        persist()
        persistResult()
        saveProjectRecord()
    }

    func resultsFolder(for runID: String) throws -> URL {
        guard RunArtifacts.validRunID(runID) else { throw StudioError.message("Invalid saved run identifier.") }
        let base: URL = if let projectFolder {
            projectFolder.appendingPathComponent("results")
        } else if demoMode {
            FileManager.default.temporaryDirectory.appendingPathComponent("ConceptStudio-demo-results")
        } else {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("ConceptStudio/results")
        }
        let parent = base.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = parent.appendingPathComponent(base.lastPathComponent).standardizedFileURL
        let folder = root.appendingPathComponent(runID, isDirectory: true).standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path,
              folder.resolvingSymlinksInPath().path == folder.path else {
            throw StudioError.message("The project results folder points outside its saved location.")
        }
        return folder
    }

    func loadProjectRecord() {
        runHistory = []
        generations = []
        selectedHistoryRunID = ""
        repeatSourceRunID = ""
        guard let projectFolder else { return }
        let record = ProjectTrainingRecord.load(from: projectFolder)
        runHistory = record.runs
        generations = record.comparisons
        selectedHistoryRunID = runHistory.last?.runID ?? ""
        if generation == nil {
            generation = generations.last { [.generating, .pending].contains($0.state) }
        }
        if result == nil {
            result = record.results.last { [.training, .pending].contains($0.state) }
        }
    }

    @discardableResult
    func saveProjectRecord() -> Bool {
        guard !demoMode, let projectFolder else { return false }
        var record = ProjectTrainingRecord.load(from: projectFolder)
        if let result, projectOwnsRun(result.runID) {
            record.results.removeAll { $0.runID == result.runID }
            record.results.append(result)
        }
        captureRunProgress()
        record.runs = runHistory
        if let generation, projectOwnsRun(generation.sourceRunID) {
            generations.removeAll { $0.runID == generation.runID }
            generations.append(generation)
        }
        record.comparisons = generations
        do {
            try record.save(to: projectFolder)
            return true
        } catch {
            message = "Could not record the training result in the project folder: \(error.localizedDescription)"
            return false
        }
    }

    /// A global pod restore keeps costs and pending outputs under control; only a project's
    /// existing run/result record authorizes writing those artifacts into that project.
    func projectOwnsRun(_ id: String) -> Bool {
        if runHistory.contains(where: { $0.runID == id }) { return true }
        guard let projectFolder else { return false }
        return ProjectTrainingRecord.load(from: projectFolder).results.contains { $0.runID == id }
    }
}
