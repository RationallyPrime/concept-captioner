import SwiftUI

extension GPUJourneyView {
    /// What renting costs and how it stops, set large before anything else on the screen.
    var costFigures: some View {
        let rate = workspace.hasRunningPod
            ? workspace.pod?.cost ?? workspace.quotedHourlyRate
            : workspace.saved?.hourlyRate ?? workspace.quotedHourlyRate
        return HStack(alignment: .top, spacing: 40) {
            PrintFigure(value: rate > 0 ? StudioMoney.perHour(rate) : "–", label: "computer price")
            PrintFigure(
                value: StudioMoney.format(workspace.activeBudget ?? workspace.budget),
                label: "spending limit for this computer"
            )
            PrintFigure(value: "\(workspace.idleMinutes) min", label: "stops when idle")
        }
        .padding(.top, 4)
    }

    /// One line of the plan, set like a receipt: the item, a rule, the value.
    func receiptRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).foregroundStyle(InstantPrint.inkSecondary)
                Spacer(minLength: 12)
                Text(value).fontWeight(.medium).monospacedDigit().multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.system(size: 14)).padding(.vertical, 8)
            Rectangle().fill(InstantPrint.rule).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
