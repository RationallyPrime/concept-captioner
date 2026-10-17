import SwiftUI

struct WelcomeView: View {
    @Bindable var session: StudioSession
    @State private var showRetainedComputer = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            panel
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if session.gpu.hasRunningPod { retainedComputer }
                    if !session.gpu.strayPods.isEmpty { reconciledComputers }
                    workflow
                    Divider()
                    demoStrip
                    Divider()
                    if session.recentPaths.isEmpty {
                        StudioSection(title: "Your projects") {
                            Text("Projects you create or open appear here, with their folder locations.")
                                .foregroundStyle(StudioStyle.supportingText)
                        }
                    } else { recentProjects }
                    if session.busy { ProgressView(session.message) }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 58).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(InstantPrint.ground)
        }
        .ignoresSafeArea(.container, edges: .top)
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

    /// The film-back panel: the name, what the app does, the three ways in, and Settings and Help.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38).contentShape(Rectangle()).gesture(WindowDragGesture())
            VStack(alignment: .leading, spacing: 16) {
                Text("ConceptStudio").font(InstantPrint.display(size: 30)).foregroundStyle(InstantPrint.frameText)
                    .accessibilityAddTraits(.isHeader)
                Text("Use your photos or clips to teach an image or video model a person, an object, a style "
                    + "or a movement.")
                    .font(.system(size: 14.5)).foregroundStyle(InstantPrint.frameItem)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Each project keeps its examples, captions and training runs in a folder you choose.")
                    .font(.system(size: 13)).foregroundStyle(InstantPrint.frameMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 22)
            VStack(spacing: 10) { startButtons }
                .disabled(session.busy)
                .padding(.horizontal, 28).padding(.top, 30)
            Text("The demo uses practice photos and simulated training. No account or rented computer is needed.")
                .font(.system(size: 12.5)).foregroundStyle(InstantPrint.frameMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28).padding(.top, 12)
            Spacer(minLength: 24)
            Rectangle().fill(InstantPrint.frameRule).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                SettingsLink { panelAction("Accounts & settings", symbol: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Connect captioning, publishing and training accounts.")
                Button { openWindow(id: "help") } label: { panelAction("Help", symbol: "questionmark.circle") }
                    .buttonStyle(.plain)
                    .help("Read the training explanation or look up a term.")
            }
            .padding(.vertical, 10)
        }
        .frame(width: 330)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(InstantPrint.frame)
    }

    private func panelAction(_ title: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16, weight: .light)).frame(width: 26)
            Text(title).font(.system(size: 14))
        }
        .foregroundStyle(InstantPrint.frameItem)
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// A strip of the demo's prints: what a project looks like, one click away.
    private var demoStrip: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The demo project").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("24 synthetic photos of one fictional person, NORA7, with prepared captions and simulated training.")
                .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
            Button { session.useDemo() } label: { HStack(spacing: 12) {
                ForEach(demoPrints, id: \.self) { url in
                    VStack(spacing: 0) {
                        TrainingTargetPreview(url: url, fill: true).frame(height: 118).frame(maxWidth: .infinity)
                            .clipped()
                        Text(url.lastPathComponent).font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(InstantPrint.ink).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 3).padding(.top, 7).padding(.bottom, 9)
                    }
                    .padding([.horizontal, .top], 5)
                    .background(InstantPrint.paper, in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1.5)
                    .environment(\.colorScheme, .light)
                }
            }.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(session.busy || session.gpu.hasRunningPod || session.gpu.isBusy)
                .help("Open the demo project")
                .accessibilityLabel("Open the demo project")
        }
    }

    private var demoPrints: [URL] {
        guard let folder = Bundle.module.url(forResource: "Demo", withExtension: nil)?
            .appendingPathComponent("images")
        else { return [] }
        return ["window", "autumn-park", "cafe", "beach", "brick-wall"]
            .map { folder.appendingPathComponent("\($0).jpg") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
            Text("\(number)").font(InstantPrint.display(size: 34)).foregroundStyle(StudioStyle.supportingText)
                .accessibilityHidden(true)
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
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
        .buttonStyle(PrintButtonStyle(kind: .primary)).frame(height: 40)
        .help("Creates a project in a folder you choose. You then import its photos or video clips.")
        Button("Open project…") {
            if let url = ProjectAccess.chooseFolder(prompt: "Open project") { session.openProject(url: url) }
        }
        .buttonStyle(PrintButtonStyle(kind: .secondary)).frame(height: 40)
        .help("Opens a project folder containing its images, captions and job configuration.")
        Button { session.useDemo() } label: { Label("Try the demo", systemImage: "play.circle") }
            .buttonStyle(PrintButtonStyle(kind: .secondary)).frame(height: 40)
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
