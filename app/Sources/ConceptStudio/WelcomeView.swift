import SwiftUI

struct WelcomeView: View {
    @Bindable var session: StudioSession
    @State private var showRetainedComputer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 48) {
                    introduction.frame(maxWidth: .infinity, alignment: .leading)
                    example.frame(width: 280)
                }
                Divider()
                if !session.recentPaths.isEmpty { recentProjects }
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(StudioStyle.accent)
                    Text("Your project stays on your Mac. You choose when to send photos to a service.")
                        .foregroundStyle(StudioStyle.supportingText)
                }.font(.callout)
                if session.busy { ProgressView(session.message) }
                SettingsLink { Label("Accounts & settings", systemImage: "gearshape") }
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(48)
            .frame(maxWidth: .infinity, minHeight: 650, alignment: .center)
        }
        .background(StudioStyle.canvas)
        .safeAreaInset(edge: .top, spacing: 0) {
            if session.gpu.hasRunningPod || !session.gpu.strayPods.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if session.gpu.hasRunningPod { retainedComputer.padding(24) }
                    if !session.gpu.strayPods.isEmpty { reconciledComputers.padding(24) }
                    Divider()
                }.background(StudioStyle.surface)
            }
        }
        .sheet(isPresented: $showRetainedComputer) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Retained rented computer").font(.title2.bold())
                GPUJourneyView(session: session, step: .pods)
                Button("Close controls") { showRetainedComputer = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(28).frame(minWidth: 850, minHeight: 650)
                .tint(StudioStyle.accent)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("ConceptStudio", systemImage: "square.stack.3d.up")
                .font(.title3.weight(.semibold))
            Text("Teach your model\nwhat matters.")
                .font(.system(size: 36, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Start with your photos. Choose what should stay recognizable and what you want to change. "
                + "We’ll help you describe the difference, then train a model on a rented computer.")
                .font(.title3).foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { startButtons }
                VStack(alignment: .leading, spacing: 10) { startButtons }
            }
            .controlSize(.large).disabled(session.busy)
            Text("The demo walks through every step with practice photos. No accounts, no uploads, no charges.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var startButtons: some View {
        Button("New project…") { session.createProject() }
            .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
        Button("Try the demo", systemImage: "play.circle") { session.useDemo() }
            .disabled(session.gpu.hasRunningPod || session.gpu.isBusy)
            .help(session.gpu.hasRunningPod ? "Stop the rented computer first." : "Practice every step offline.")
        Button("Open project…") { session.openProject() }
    }

    private var example: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let url = Bundle.module.url(forResource: "Demo", withExtension: nil)?
                .appendingPathComponent("images/garden.png") {
                PhotoView(url: url).frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("A learning word, like NORA7").font(.headline)
                Text("Use it for the identity you want your model to recognize.")
                    .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Label("Keep the person recognizable", systemImage: "person.crop.circle")
            Label("Change the clothes, light and setting", systemImage: "slider.horizontal.3")
            Text("Illustrated example from the offline demo")
                .font(.caption).foregroundStyle(StudioStyle.supportingText)
        }
        .padding(20)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var retainedComputer: some View {
        StudioSection(title: "A rented computer is still running") {
            HStack {
                Text(retainedCost).font(.headline).monospacedDigit()
                Spacer()
                Button("Manage retained computer") { showRetainedComputer = true }
                Button(session.gpu.isStopping ? "Stopping…" : "Stop everything", systemImage: "stop.circle") {
                    session.requestStopEverything()
                }.disabled(session.gpu.isStopping)
            }
            Text(session.gpu.message).font(.callout)
            Text("Stop this computer before starting a different project or demo.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
        }
    }

    /// Computers this app created that the provider still lists, though this Mac had lost their record.
    private var reconciledComputers: some View {
        StudioSection(
            title: "Found running computers from an earlier session",
            subtitle: "ConceptStudio created these, but this Mac had lost track of them. They are still billing."
        ) {
            ForEach(session.gpu.strayPods) { pod in
                HStack(spacing: 12) {
                    Image(systemName: "server.rack").foregroundStyle(StudioStyle.accent)
                    Text(pod.id).fontWeight(.medium).textSelection(.enabled)
                    Text("\(pod.status.capitalized) · \(StudioStyle.money(pod.cost)) per hour")
                        .foregroundStyle(StudioStyle.supportingText).monospacedDigit()
                    Spacer()
                    Button("Stop", systemImage: "stop.circle") { Task { await session.gpu.stopStrayPod(id: pod.id) } }
                        .disabled(session.gpu.isStopping)
                }
            }
        }
    }

    private var retainedCost: String {
        let spent = "\(StudioStyle.money(session.gpu.elapsedCost)) estimated since creation"
        guard let rate = session.gpu.pod?.cost, rate > 0 else { return spent }
        return "\(StudioStyle.money(rate)) per hour · \(spent)"
    }

    private var recentProjects: some View {
        StudioSection(title: "Pick up where you left off") {
            VStack(spacing: 0) {
                ForEach(session.recentPaths, id: \.self) { path in
                    Button { session.openRecent(path) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder").foregroundStyle(StudioStyle.accent)
                            Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                                .foregroundStyle(StudioStyle.supportingText)
                        }.padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(path).disabled(session.busy)
                }
            }
        }
    }
}
