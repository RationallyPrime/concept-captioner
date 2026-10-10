import SwiftUI

struct StudioRootView: View {
    @Bindable var session: StudioSession

    var body: some View {
        Group {
            if session.project == nil {
                WelcomeView(session: session)
            } else {
                journey
            }
        }
        .background(WindowCloseGuard(session: session))
        .alert("Something needs your attention", isPresented: Binding(
            get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } }
        )) { Button("OK") { session.errorMessage = nil } } message: { Text(session.errorMessage ?? "") }
    }

    private var journey: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.demoMode ? "Offline demo" : session.project?.directory.lastPathComponent ?? "Project")
                    .font(.headline).padding(.horizontal)
                List(StudioStep.allCases, selection: $session.step) { step in
                    Label(step.title, systemImage: step.symbol).tag(step)
                }
                if session.gpu.hasRunningPod {
                    Text("Computer running · $\(session.gpu.elapsedCost, specifier: "%.2f") so far")
                        .font(.callout).foregroundStyle(.orange).padding(.horizontal)
                }
                Button("Close project") { session.requestClose() }.padding()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text((session.step ?? .images).title).font(.largeTitle.bold())
                        Text((session.step ?? .images).explanation).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if session.demoMode { Text("DEMO · $0").font(.caption.bold()).padding(8).background(
                        .mint.opacity(0.2),
                        in: Capsule()
                    ) }
                }.padding(24)
                Divider()
                screen.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                HStack {
                    if session.busy { ProgressView().controlSize(.small); Button("Cancel") { session.cancel() } }
                    Text(session.message).font(.callout).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    if session.step != .monitor {
                        Button(
                            "Next: \(StudioStep(rawValue: (session.step ?? .images).rawValue + 1)?.title ?? "Monitor")"
                        ) {
                            session.next()
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(16)
            }
            .toolbar {
                ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") } }
                ToolbarItem {
                    Button("Stop everything", systemImage: "stop.circle.fill") {
                        Task { await session.stopEverything() }
                    }.tint(.red)
                }
            }
            .onChange(of: session.step) { _, step in
                if let step, step.rawValue >= StudioStep.pods.rawValue { session.configureGPU() }
            }
        }
    }

    @ViewBuilder private var screen: some View {
        switch session.step ?? .images {
        case .images: ImagesView(session: session)
        case .concepts: ConceptsView(session: session)
        case .mapping: MappingView(session: session)
        case .captioning: CaptioningView(session: session)
        case .review: ReviewView(session: session)
        case .publish: PublishView(session: session)
        case .pods, .training, .monitor:
            GPUJourneyView(workspace: session.gpu, step: session.step ?? .pods, datasetRepo: session.repoID)
        }
    }
}

struct WelcomeView: View {
    @Bindable var session: StudioSession
    @State private var showRetainedComputer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Teach your model what matters.").font(.system(size: 34, weight: .bold))
            Text(
                "Bring photos and choose what should stay recognizable. ConceptStudio helps describe the rest, "
                    + "then trains a model on a computer you rent only when you need it."
            )
            .font(.title3).frame(maxWidth: 630)
            HStack {
                Button("New project…") { session.createProject() }.buttonStyle(.borderedProminent)
                Button("Open project…") { session.openProject() }
                Button("Try the demo") { session.useDemo() }
            }.disabled(session.busy)
            Text("The demo stays on your Mac and spends nothing. Real training shows the price before you rent.")
                .foregroundStyle(.secondary)
            if session.gpu.hasRunningPod {
                GroupBox("A rented computer is still running") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("$\(session.gpu.elapsedCost, specifier: "%.2f") estimated since creation")
                            .foregroundStyle(.orange)
                        Text(session.gpu.message).font(.callout)
                        HStack {
                            Button("Manage retained computer") { showRetainedComputer = true }
                            Button("Stop everything", systemImage: "stop.circle.fill") {
                                Task { await session.stopEverything() }
                            }.tint(.red)
                        }
                        Text("Stop this computer before starting a different project or demo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            if !session.recentPaths.isEmpty {
                Text("Recent projects").font(.headline)
                ForEach(session.recentPaths, id: \.self) { path in
                    Button(URL(fileURLWithPath: path).lastPathComponent) { session.openRecent(path) }
                        .help(path).disabled(session.busy)
                }
            }
            if session.busy { ProgressView(session.message) }
            SettingsLink { Label("Set up an account key", systemImage: "key") }
        }
        .padding(56).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .sheet(isPresented: $showRetainedComputer) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Retained rented computer").font(.title2.bold())
                GPUJourneyView(workspace: session.gpu, step: .pods, datasetRepo: session.repoID)
                Button("Close controls") { showRetainedComputer = false }
            }.padding(28).frame(minWidth: 850, minHeight: 650)
        }
    }
}
