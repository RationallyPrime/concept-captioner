import SwiftUI

struct WelcomeView: View {
    @Bindable var session: StudioSession
    @State private var showRetainedComputer = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                introduction
                Divider()
                workflow
                Divider()
                if session.recentPaths.isEmpty {
                    StudioSection(title: "Your projects") {
                        Text("Projects you create or open appear here, with their folder locations.")
                            .foregroundStyle(StudioStyle.supportingText)
                    }
                } else { recentProjects }
                if session.busy { ProgressView(session.message) }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .top)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text("ConceptStudio")
                    .font(.system(size: 36, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SettingsLink { Label("Accounts & settings", systemImage: "gearshape") }
                    .help("Connect captioning, publishing and training accounts.")
                Button("Help", systemImage: "questionmark.circle") { openWindow(id: "help") }
                    .help("Read the training explanation or look up a term.")
            }
            Text(
                "Use your photos or clips to teach an image or video model a person, an object, a style or a movement."
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("Each project keeps its examples, captions and training runs in a folder you choose.")
                .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { startButtons }
                VStack(alignment: .leading, spacing: 10) { startButtons }
            }
            .controlSize(.large).disabled(session.busy)
            Text("The demo uses practice photos and simulated training. No account or rented computer is needed.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workflow: some View {
        HStack(alignment: .top, spacing: 24) {
            workflowStage(
                1,
                title: "Prepare examples",
                screens: "Images · Concepts · Mapping",
                detail: "Choose photos or clips and identify the concept you want to train."
            )
            Divider()
            workflowStage(
                2,
                title: "Write captions",
                screens: "Captioning · Review · Publish",
                detail: "Describe the selected examples, review the text and prepare the training data."
            )
            Divider()
            workflowStage(
                3,
                title: "Train and compare",
                screens: "GPU pods · Training · Monitor",
                detail: "Choose a computer and budget, run training, then save and try the model."
            )
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func workflowStage(_ number: Int, title: String, screens: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number). \(title)").font(.headline).accessibilityAddTraits(.isHeader)
            Text(detail).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(StudioStyle.supportingText)
            Text(screens).font(.caption).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
