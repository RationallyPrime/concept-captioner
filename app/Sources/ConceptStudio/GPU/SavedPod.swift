import Foundation

/// The local record of the rented pod. Fields added after the first release decode with
/// defaults, so a record written by an older build still restores (and stays under budget).
struct SavedPod: Codable {
    var pod: RentedPod
    var started: Date
    var accruedGPUCostUSD = 0.0
    var hourlyRate: Double
    var budget: Double
    var trainer: String
    var runID: String
    var idleMinutes = 15
    var volumeID = ""
    /// The RunPod secret holding this pod's agent bearer; deleted when the pod is removed.
    var agentSecret = ""
    var points: [TrainingPoint] = []
    var result: TrainingResult?
    var run: TrainingRun?
    var generation: GeneratedComparison?
}

extension SavedPod {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pod = try values.decode(RentedPod.self, forKey: .pod)
        started = try values.decode(Date.self, forKey: .started)
        accruedGPUCostUSD = try values.decodeIfPresent(Double.self, forKey: .accruedGPUCostUSD) ?? 0
        hourlyRate = try values.decode(Double.self, forKey: .hourlyRate)
        budget = try values.decode(Double.self, forKey: .budget)
        trainer = try values.decode(String.self, forKey: .trainer)
        runID = try values.decode(String.self, forKey: .runID)
        idleMinutes = try values.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? 15
        volumeID = try values.decodeIfPresent(String.self, forKey: .volumeID) ?? ""
        agentSecret = try values.decodeIfPresent(String.self, forKey: .agentSecret) ?? ""
        points = try values.decodeIfPresent([TrainingPoint].self, forKey: .points) ?? []
        result = try values.decodeIfPresent(TrainingResult.self, forKey: .result)
        run = try values.decodeIfPresent(TrainingRun.self, forKey: .run)
        generation = try values.decodeIfPresent(GeneratedComparison.self, forKey: .generation)
        if !runID.isEmpty, !RunArtifacts.validRunID(runID) { runID = "" }
        if let result, !RunArtifacts.validRunID(result.runID) { self.result = nil }
        if let run, !RunArtifacts.validRunID(run.runID) { self.run = nil }
        if let generation, !RunArtifacts.validRunID(generation.runID)
            || !RunArtifacts.validRunID(generation.sourceRunID) { self.generation = nil }
    }
}
