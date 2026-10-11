import Foundation

enum TrainingCurveDisplay: Equatable {
    case noRun, waiting, disconnected, ended, stopped, failed, available

    var title: String {
        switch self {
        case .noRun: "No training run yet"
        case .waiting: "Waiting for the first measurement"
        case .disconnected: "This run's current status is unavailable"
        case .ended: "This run ended without a learning curve"
        case .stopped: "Training stopped before a curve was recorded"
        case .failed: "This run ended without a trained model"
        case .available: "Learning curve"
        }
    }

    var explanation: String {
        switch self {
        case .noRun: "Choose your settings on Training and start a run. Its measurements will appear here."
        case .waiting:
            "The run has started. Loading the model and preparing the data can take time before training "
                + "reports its first loss measurement. You can inspect the Training log while you wait."
        case .disconnected:
            "Inspect Saved runs for the recorded settings and checkpoints. A running computer on this run's "
                + "saved storage is needed to check its remote files or continue training."
        case .ended:
            "No loss measurements are available for this run. Inspect its Training log or TensorBoard. "
                + "The trained model's delivery status is shown below."
        case .stopped:
            "No loss measurements were recorded before training stopped. Inspect the Training log and saved runs "
                + "before deciding whether to continue."
        case .failed: "Inspect the Training log for the cause before starting another run."
        case .available: "Loss measures fit to these examples. A lower curve alone does not prove better pictures."
        }
    }
}

@MainActor
extension GPUWorkspace {
    var monitoredRun: TrainingRun? {
        runID.isEmpty ? runHistory.last : runHistory.first { $0.runID == runID }
    }

    var monitoredPoints: [TrainingPoint] {
        points.isEmpty ? monitoredRun?.points ?? [] : points
    }

    var monitoredResultState: TrainingResult.State? {
        let target = runID.isEmpty ? monitoredRun?.runID : runID
        if let result, target == nil || result.runID == target { return result.state }
        return monitoredRun?.result?.state
    }

    var computerStatus: String {
        guard let pod else { return "Not rented" }
        switch pod.status.uppercased() {
        case "RUNNING": return "Running"
        case "EXITED": return "Stopped"
        case "ERROR": return "Unavailable"
        case "TERMINATED": return "Removed"
        default: return pod.status.capitalized
        }
    }

    var trainingStatus: String {
        if monitoredResultState == .failed { return "Ended without a trained model" }
        switch monitoredResultState {
        case .pending?, .pushed?, .saved?: return runID.isEmpty ? "Last run finished" : "Finished"
        default: break
        }
        guard !runID.isEmpty else { return monitoredRun == nil ? "Not started" : "Last run status unavailable" }
        if pod?.isRunning == false { return "Stopped" }
        if pod == nil { return "Not connected" }
        switch trainingState.lowercased() {
        case "running": return "In progress"
        case "stuck": return "Not responding"
        case "exited": return "Ended"
        case "stopped": return "Stopped"
        case "failed": return "Failed"
        case "not started": return "Waiting for status"
        default: return trainingState.capitalized
        }
    }

    var curveDisplay: TrainingCurveDisplay {
        if !monitoredPoints.isEmpty { return .available }
        if monitoredResultState == .failed { return .failed }
        switch monitoredResultState {
        case .pending?, .pushed?, .saved?: return .ended
        default: break
        }
        guard !runID.isEmpty else { return monitoredRun == nil ? .noRun : .disconnected }
        if pod?.isRunning == false || trainingState.lowercased() == "stopped" { return .stopped }
        if trainingState.lowercased() == "failed" { return .failed }
        if trainingState.lowercased() == "exited" { return .ended }
        if pod == nil { return .disconnected }
        return .waiting
    }
}

extension TrainingPlan {
    func explanation(
        captioningOnPod: Bool,
        captionSource: String,
        captionServerActive: Bool?,
        keepServer: Bool
    ) -> String {
        let source = captionSource
        if mode == "sequential" {
            let action = switch captionServerActive {
            case true:
                "A caption model is running on its GPU. Starting training stops that model to free memory."
            case false:
                "No caption model is running on its GPU. Training can use the GPU directly."
            case nil:
                "The app checks its services before training and stops a pod caption model only if one is running."
            }
            return source + " " + action + (captioningOnPod
                ? " Finish captioning or review work on this computer before starting training on its one GPU." : "")
        }
        let allocation = "Training uses \(gpuDescription(train))."
        let captionGPUs = gpuDescription(caption)
        if captionServerActive == true {
            return source + " " + allocation + " The existing pod caption model stays on \(captionGPUs)."
        }
        if keepServer {
            return source + " " + allocation + " The training settings also start a pod caption model on "
                + captionGPUs + " if one is not already running."
        }
        return source + " " + allocation + " No pod caption model is started by these training settings."
            + (captioningOnPod ? " Start its model from Captioning before using it." : "")
    }

    private func gpuDescription(_ assignment: Assignment?) -> String {
        guard let gpus = assignment?.gpus, !gpus.isEmpty else { return "the assigned GPUs" }
        return (gpus.count == 1 ? "GPU " : "GPUs ") + gpus.map(String.init).joined(separator: ", ")
    }
}

@MainActor
extension StudioSession {
    var trainingPlanExplanation: String {
        guard let plan = gpu.plan else {
            return "Rent a computer first. Its control agent will report which GPUs training can use."
        }
        let captionerOnPod = usingPodCaptioner && endpointKind == "vllm"
        let reviewerOnPod = usingPodCaptioner && useCritic && criticKind == "vllm"
        let provider = endpointKind == "vllm" ? "your custom server" : ProviderChoices.title(endpointKind)
        var source = captionerOnPod ? "Captioning is set to use this computer."
            : "Captioning uses \(provider), separately from this training computer."
        if useCritic {
            let reviewer = criticKind == "vllm" ? "your custom server" : ProviderChoices.title(criticKind)
            source += reviewerOnPod ? " The caption reviewer uses this computer."
                : " The caption reviewer uses \(reviewer)."
        }
        return plan.explanation(
            captioningOnPod: captionerOnPod || reviewerOnPod, captionSource: source,
            captionServerActive: gpu.captionServerActive, keepServer: gpu.keepCaptionServer
        )
    }
}

extension TrainingRun {
    var resultExplanation: String {
        switch result?.state {
        case .training?: "Training in progress"
        case .pending?: "Finished; trained model still needs saving"
        case let .pushed(repo)?: "Uploaded to Hugging Face: \(repo)"
        case let .saved(folder)?: "Saved on this Mac: \(URL(fileURLWithPath: folder).lastPathComponent)"
        case .failed?: "Ended without a trained model"
        case nil: "Run submitted; refresh its progress to check the result"
        }
    }

    var newRunExplanation: String {
        if localInputDigest != nil {
            return "A new run uses your current included media and saved captions. "
                + "You can change the training settings before starting it."
        }
        if datasetRevision == nil {
            return "The training data version was not recorded. A new run uses the latest data in this dataset. "
                + "You can change the training settings before starting it."
        }
        return "A new run uses this run's saved version of the published training data. "
            + "You can change the training settings before starting it."
    }
}
