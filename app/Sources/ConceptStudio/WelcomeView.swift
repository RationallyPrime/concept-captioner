import SwiftUI

struct WelcomeView: View {
    @Bindable var session: StudioSession
    @State private var showRetainedComputer = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                introduction
                Divider()
                if !session.recentPaths.isEmpty { recentProjects }
                if session.busy { ProgressView(session.message) }
            }
            .frame(maxWidth: 820, alignment: .leading)
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
                Text("Running rented computer").font(.title2.bold())
                GPUJourneyView(session: session, step: .pods)
                Button("Close controls") { showRetainedComputer = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(28).frame(minWidth: 850, minHeight: 650)
                .tint(StudioStyle.accent)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("ConceptStudio")
                .font(.system(size: 36, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Use your photos or clips to teach an image or video model a person, an object, a style or a movement."
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("Create a project folder to keep its training data, captions and saved runs together, "
                + "or open a project you have already started. The Images screen explains the training process.")
                .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { startButtons }
                VStack(alignment: .leading, spacing: 10) { startButtons }
            }
            .controlSize(.large).disabled(session.busy)
            Text("The demo walks through every step with practice photos. No accounts, no uploads, no charges.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink { Label("Accounts & settings", systemImage: "gearshape") }
                .help("Opens account authorization, saved keys and model connection settings.")
            Button("ConceptStudio Help", systemImage: "questionmark.circle") { openWindow(id: "help") }
                .help("Open the training explanation and definitions without opening a project.")
        }
    }

    @ViewBuilder private var startButtons: some View {
        Button("New project…") {
            if let url = ProjectAccess.chooseFolder(prompt: "Create project here") { session.createProject(at: url) }
        }
        .buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
        .help("Creates a project in a folder you choose. You then import its photos or video clips.")
        Button("Open project…") {
            if let url = ProjectAccess.chooseFolder(prompt: "Open project") { session.openProject(url: url) }
        }
        .help("Opens a project folder containing its images, captions and job configuration.")
        Button("Try the demo", systemImage: "play.circle") { session.useDemo() }
            .disabled(session.gpu.hasRunningPod || session.gpu.isBusy)
            .help(session.gpu.hasRunningPod ? "Stop the rented computer first." : "Opens a simulated project offline.")
    }

    private var retainedComputer: some View {
        StudioSection(title: "A rented computer is still running") {
            HStack {
                Text(retainedCost).font(.headline).monospacedDigit()
                Spacer()
                Button("Open computer controls") { showRetainedComputer = true }
                    .help("Shows the provider status, hourly cost and stop controls for this running computer.")
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
                    Text(pod.name ?? pod.id).fontWeight(.medium).textSelection(.enabled)
                    Text("\(pod.status.capitalized) · \(StudioMoney.perHour(pod.cost))")
                        .foregroundStyle(StudioStyle.supportingText).monospacedDigit()
                    Spacer()
                    Button("Stop", systemImage: "stop.circle") { Task { await session.gpu.stopStrayPod(id: pod.id) } }
                        .disabled(session.gpu.isStopping)
                }
            }
        }
    }

    private var retainedCost: String {
        let spent = "\(StudioMoney.format(session.gpu.elapsedCost)) estimated since creation"
        guard let rate = session.gpu.pod?.cost, rate > 0 else { return spent }
        return "\(StudioMoney.perHour(rate)) · \(spent)"
    }

    private var recentProjects: some View {
        StudioSection(title: "Recent projects") {
            VStack(spacing: 0) {
                ForEach(session.recentPaths, id: \.self) { path in
                    HStack(spacing: 12) {
                        Button { session.openRecent(path) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(StudioStyle.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                                    Text(RecentProjects.parentLabel(path))
                                        .font(.caption).foregroundStyle(StudioStyle.supportingText)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                                    .foregroundStyle(StudioStyle.supportingText)
                            }.padding(.vertical, 10).contentShape(Rectangle())
                                .accessibilityElement(children: .combine)
                        }.buttonStyle(.plain).help(path).disabled(session.busy)
                        Button("Remove from recent projects", systemImage: "xmark") {
                            session.forgetRecent(path)
                        }
                        .labelStyle(.iconOnly)
                        .help("Remove from recent projects")
                        .accessibilityLabel(
                            "Remove \(URL(fileURLWithPath: path).lastPathComponent) from recent projects"
                        )
                    }
                }
            }
        }
    }
}
