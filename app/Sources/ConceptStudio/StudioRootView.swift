import ConceptCore
import SwiftUI

struct StudioRootView: View {
    @Bindable var session: StudioSession
    @State private var showingDefinitions = false
    var body: some View {
        Group {
            if session.project == nil {
                WelcomeView(session: session)
            } else {
                journey
            }
        }
        .tint(StudioStyle.accent)
        .frame(minWidth: 980, minHeight: 680)
        .background(WindowCloseGuard(session: session))
        .modifier(StudioSessionHooks(session: session))
        .modifier(StudioFailureAlert(session: session))
        .modifier(StudioPromptPresenter(session: session))
    }

    /// The Instant Print frame: a charcoal sidebar of the nine steps, a title strip, and a footer that
    /// carries the project, its progress and the one obvious next action across the whole window.
    private var journey: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                VStack(spacing: 0) {
                    titleStrip
                    Group {
                        if session.step == .review {
                            screen
                        } else {
                            screen.padding(24)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .background(InstantPrint.ground)
                }
            }
            footer
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: session.step, initial: true) { _, step in
            if let step, step.usesRentedComputer { session.prepareGPUStep() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ConceptStudio").font(.system(size: 15.5, weight: .bold)).foregroundStyle(InstantPrint.frameText)
                .padding(.leading, 96).frame(height: 38)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).gesture(WindowDragGesture())
            Rectangle().fill(InstantPrint.frameRule).frame(height: 1).padding(.trailing, 1)
            // A short window tightens the spacing before any step has to scroll out of sight.
            ViewThatFits(in: .vertical) {
                stepList(compact: false)
                stepList(compact: true)
                ScrollView { stepList(compact: true) }.scrollIndicators(.never)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(InstantPrint.frameRule).frame(height: 1).padding(.trailing, 1)
            VStack(alignment: .leading, spacing: 2) {
                SettingsLink { sidebarAction("Settings", symbol: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Accounts and settings (⌘,)")
                Button { session.requestClose() } label: {
                    sidebarAction(
                        session.demoMode ? "Leave the demo" : "Close project",
                        symbol: "rectangle.portrait.and.arrow.right"
                    )
                }
                .buttonStyle(.plain)
                .help(session.demoMode ? "Return to the Welcome screen (⇧⌘W)" : "Close this project (⇧⌘W)")
            }
            .padding(.vertical, 10)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(InstantPrint.frame)
    }

    private func sidebarAction(_ title: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16, weight: .light)).frame(width: 26)
            Text(title).font(.system(size: 14))
        }
        .foregroundStyle(InstantPrint.frameItem)
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func stepList(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stepGroup(
                "Prepare training data",
                session.journeySteps.filter { $0.rawValue < 3 },
                top: compact ? 14 : 22,
                compact: compact
            )
            if session.project?.job.concepts.isEmpty != true {
                stepGroup(
                    "Write captions",
                    Array(StudioStep.allCases.dropFirst(3).prefix(3)),
                    top: compact ? 18 : 36,
                    compact: compact
                )
                stepGroup(
                    "Train your model",
                    Array(StudioStep.allCases.suffix(3)),
                    top: compact ? 18 : 36,
                    compact: compact
                )
            }
        }
        .padding(.bottom, compact ? 8 : 16)
    }

    private func stepGroup(_ title: String, _ steps: [StudioStep], top: CGFloat, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(InstantPrint.frameMuted)
                .padding(.leading, 23).padding(.bottom, compact ? 6 : 10)
                .accessibilityAddTraits(.isHeader)
            ForEach(steps) { step in stepRow(step, height: compact ? 36 : 44) }
        }
        .padding(.top, top)
    }

    private func stepRow(_ step: StudioStep, height: CGFloat) -> some View {
        let selected = (session.step ?? .images) == step
        return Button { session.step = step } label: {
            HStack(spacing: 14) {
                Image(systemName: step.symbol).font(.system(size: 18, weight: .light)).frame(width: 26)
                Text(step.title).font(.system(size: 15))
            }
            .foregroundStyle(selected ? Color.white : InstantPrint.frameItem)
            .padding(.leading, 14)
            .frame(width: 197, height: height, alignment: .leading)
            .background { if selected { RoundedRectangle(cornerRadius: 8).fill(InstantPrint.selectedStep) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            if selected { UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                .fill(InstantPrint.developer).frame(width: 8, height: height)
            }
        }
        .accessibilityLabel("\(step.title), step \(step.rawValue + 1) of \(StudioStep.allCases.count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(step.title) (⌘\(step.rawValue + 1))")
    }

    /// Every screen explains itself here, in one sentence, with its definitions a click away.
    private var titleStrip: some View {
        let step = session.step ?? .images
        return HStack(spacing: 10) {
            Text(step.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(InstantPrint.frameText)
                .accessibilityAddTraits(.isHeader)
            Text(step.explanation).font(.system(size: 13.5)).foregroundStyle(InstantPrint.frameMuted)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if !step.definitionTerms.isEmpty {
                Button("Definitions", systemImage: "questionmark.circle") { showingDefinitions = true }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(InstantPrint.frameItem)
                    .help("Definitions of the terms on this screen")
                    .popover(isPresented: $showingDefinitions, arrowEdge: .bottom) {
                        StudioDefinitionsList(terms: step.definitionTerms)
                    }
                    .padding(.trailing, 6)
            }
            if session.demoMode { DemoBadge() }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(InstantPrint.frame)
        .contentShape(Rectangle()).gesture(WindowDragGesture())
    }

    /// What the footer reports for the open step, beside the project name.
    private var progress: String? {
        guard let project = session.project else { return nil }
        let count = project.images.count
        switch session.step ?? .images {
        case .images:
            return "\(count) samples"
        case .concepts:
            let concepts = project.job.concepts.count
            return concepts == 1 ? "1 concept" : "\(concepts) concepts"
        case .mapping:
            return "\(count - session.unmappedCount) of \(count) confirmed"
        case .captioning:
            return "\(project.images.count(where: { !$0.caption.isEmpty })) of \(count) captioned"
        case .review:
            return "\(project.images.filter(\.isFinal).count) of \(count) final"
        case .publish:
            return "\(count) samples to publish"
        case .pods:
            return session.gpu.computerStatus
        case .training, .monitor:
            return "Training: \(session.gpu.trainingStatus.lowercased())"
        }
    }

    private var projectTitle: String {
        if session.demoMode, let trigger = session.project?.job.concepts.first?.trigger { return "\(trigger) portrait" }
        return session.project?.directory.lastPathComponent ?? "Project"
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text(projectTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(InstantPrint.frameText)
                .lineLimit(1).help(session.project?.directory.path ?? "")
            if let progress {
                Rectangle().fill(InstantPrint.frameRule).frame(width: 1, height: 34).padding(.horizontal, 22)
                Text(progress).font(.system(size: 16)).foregroundStyle(InstantPrint.frameItem).monospacedDigit()
            }
            if !session.message.isEmpty || session.busy {
                HStack(spacing: 10) {
                    if session.busy { ProgressView().controlSize(.small).tint(InstantPrint.frameText) }
                    Text(session.message).font(.system(size: 13.5)).foregroundStyle(InstantPrint.frameMuted)
                        .lineLimit(2).textSelection(.enabled)
                    if session.busy {
                        Button("Cancel") { session.cancel() }.buttonStyle(.plain)
                            .foregroundStyle(InstantPrint.frameText).font(.system(size: 13.5, weight: .semibold))
                    }
                }
                .padding(.leading, 28)
            }
            Spacer(minLength: 16)
            if session.gpu.hasRunningPod || session.gpu.isStopping {
                Text("GPU spend · \(StudioMoney.format(session.gpu.elapsedCost))")
                    .font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(InstantPrint.frameItem)
                    .padding(.trailing, 14)
                Button(session.gpu.isStopping ? "Stopping…" : "Stop everything") { session.requestStopEverything() }
                    .buttonStyle(PrintButtonStyle(kind: .secondary)).frame(width: 150)
                    .disabled(session.gpu.isStopping)
                    .help("Cancel work and stop the rented computer.")
                    .padding(.trailing, 12)
            }
            if session.step != .concepts, let following = session.nextStep {
                Button { session.goForward() } label: {
                    HStack(spacing: 10) {
                        Text("Next: \(following.title)")
                        Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
                    }
                }
                .buttonStyle(PrintButtonStyle(kind: .primary)).frame(width: 156, height: 42)
                .help("⌘]")
            }
        }
        .padding(.leading, 27).padding(.trailing, 17)
        .frame(height: 72)
        .background(InstantPrint.frame)
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
            GPUJourneyView(session: session, step: session.step ?? .pods, showsSpendControls: false)
        }
    }
}

extension StudioStep {
    var usesRentedComputer: Bool {
        [.pods, .training, .monitor].contains(self)
    }
}

extension StudioSession {
    /// Reads the RunPod and Hub keys from the Keychain once per GPU workspace (Settings re-reads after a key
    /// changes); later visits only refresh the project-derived training defaults.
    func prepareGPUStep() {
        guard project?.job.concepts.isEmpty != true else {
            step = .concepts
            errorMessage = "Add a concept before opening GPU training controls."
            return
        }
        guard gpuKeysLoadedFor !== gpu else {
            updateTrainingProjectDefaults()
            return
        }
        configureGPU()
        gpuKeysLoadedFor = gpu
    }
}

/// The open project folder paired with the GPU workspace it belongs to (the workspace is replaced per project).
private struct TrainingDestination: Equatable {
    let workspace: ObjectIdentifier
    let folder: URL?

    @MainActor init(_ session: StudioSession) {
        workspace = ObjectIdentifier(session.gpu)
        folder = session.demoMode ? nil : session.project?.directory
    }
}

/// The one presentation path for blocking failures: a window-attached alert. Progress and recoverable
/// states stay inline beside the work they describe.
struct StudioFailureAlert: ViewModifier {
    @Bindable var session: StudioSession
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert(
            session.chatGPTUsageLimitReached ? "ChatGPT usage limit reached" : "Could not complete the operation",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil; session.chatGPTUsageLimitReached = false } }
            )
        ) {
            if session.chatGPTUsageLimitReached {
                Button("Manage usage") { openURL(StudioSession.chatGPTUsageURL) }
                    .keyboardShortcut(.defaultAction)
                Button("Close", role: .cancel) { session.errorMessage = nil }
            } else {
                Button("OK") { session.errorMessage = nil }
            }
        } message: { Text(session.errorMessage ?? "") }
    }
}

/// Keeps window-lifetime session state in step with what is open: where training results are saved, GPU
/// failures routed to the one failure alert, and photo thumbnails dropped when the project changes.
struct StudioSessionHooks: ViewModifier {
    @Bindable var session: StudioSession

    func body(content: Content) -> some View {
        content
            .onChange(of: TrainingDestination(session), initial: true) { old, destination in
                // Results without a Hub token are saved inside the open project.
                session.gpu.projectFolder = destination.folder
                // A reopened project may hold photos edited outside the app under the same names.
                if old.folder != destination.folder { PhotoThumbnails.removeAll() }
            }
            .onChange(of: session.gpu.failure) { _, failure in
                guard let failure else { return }
                session.gpu.failure = nil
                if session.errorMessage == nil { session.errorMessage = failure }
            }
    }
}
