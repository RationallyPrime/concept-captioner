import SwiftUI

/// Training-screen pieces of GPUJourneyView, kept apart for SwiftLint's type and file length caps.
extension GPUJourneyView {
    /// The open project's own training destination; another project's repository never shows here.
    @ViewBuilder var trainingDestinationFields: some View {
        TextField(
            "Save trained model to",
            text: Binding(get: { session.trainingOutputRepo }, set: { session.trainingOutputRepo = $0 }),
            prompt: Text("your-name/model-name")
        )
        Toggle("Keep the trained model private", isOn: Binding(
            get: { session.trainingOutputPrivate }, set: { session.trainingOutputPrivate = $0 }
        ))
    }
}

extension GPUJourneyView {
    /// What is still to do before training, with a way to the step for the first of it. Before renting or
    /// restarting a computer it says why to finish first: the computer bills while it waits.
    @ViewBuilder func prerequisitesNotice(beforeBilling: Bool) -> some View {
        let missing = session.trainingPrerequisites
        if let first = missing.first {
            StudioNotice(
                "Before training, "
                    + ModelTable.sentenceList(missing.map(\.missing), conjunction: "and") + "."
                    + (beforeBilling ? " A running computer bills while it waits, so do this first "
                        + "unless you need it to caption." : ""),
                symbol: "exclamationmark.circle"
            )
            Button("Go to \(first.step.title)") { session.step = first.step }
        }
    }

    /// A stopped computer whose host has no free GPU: say so, and what removing it to rent another loses.
    var restartBlockedNotice: some View {
        StudioNotice(
            "Its host has no free GPU right now, so this computer cannot start. Try again later, or remove it "
                + "and rent a new one. " + workspace.removalLossExplanation,
            symbol: "exclamationmark.triangle"
        )
    }
}

extension GPUJourneyView {
    var trainingDatasetRepo: String {
        workspace.publishedRepeatRun?.datasetRepo ?? datasetRepo
    }

    /// Where the repeated run's inputs come from, told from the dataset training will actually use.
    var repeatNotice: String {
        if workspace.usesLocalDataset {
            return "Saved settings are loaded. Training captures the current included media and saved captions."
        }
        guard let published = workspace.publishedRepeatRun else {
            return "Saved settings are loaded. That run uploaded its inputs directly, so training uses this "
                + "project's published dataset."
        }
        return published.datasetRevision == nil
            ? "Saved settings are loaded. This run did not record a dataset revision; the latest revision of "
            + "its dataset, \(published.datasetRepo), will be used."
            : "The next run repeats a saved dataset revision. Settings above remain editable."
    }

    var trainingDatasetRevision: String? {
        if let published = workspace.publishedRepeatRun { return published.datasetRevision }
        return workspace.datasetRevision.isEmpty ? nil : workspace.datasetRevision
    }
}
