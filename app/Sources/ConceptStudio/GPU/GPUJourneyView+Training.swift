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
    var repeatedRun: TrainingRun? {
        workspace.runHistory.first { $0.runID == workspace.repeatSourceRunID }
    }

    var trainingDatasetRepo: String {
        repeatedRun?.datasetRepo ?? datasetRepo
    }

    var trainingDatasetRevision: String? {
        if let repeatedRun { return repeatedRun.datasetRevision }
        return workspace.datasetRevision.isEmpty ? nil : workspace.datasetRevision
    }
}
