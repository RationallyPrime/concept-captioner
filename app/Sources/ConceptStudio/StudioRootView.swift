import ConceptCore
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
                    VStack(spacing: 0) {
                        if session.step != .review { header }
                        if session.step == .review {
                            screen
                        } else {
                            screen.padding(24)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .background(session.step == .review ? InstantPrint.ground : StudioStyle.canvas)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    stepGroup("Prepare training data", session.journeySteps.filter { $0.rawValue < 3 }, top: 22)
                    if session.project?.job.concepts.isEmpty != true {
                        stepGroup("Write captions", Array(StudioStep.allCases.dropFirst(3).prefix(3)), top: 36)
                        stepGroup("Train your model", Array(StudioStep.allCases.suffix(3)), top: 36)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(InstantPrint.frame)
    }

    private func stepGroup(_ title: String, _ steps: [StudioStep], top: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(InstantPrint.frameMuted)
                .padding(.leading, 23).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            ForEach(steps) { step in stepRow(step) }
        }
        .padding(.top, top)
    }

    private func stepRow(_ step: StudioStep) -> some View {
        let selected = (session.step ?? .images) == step
        return Button { session.step = step } label: {
            HStack(spacing: 14) {
                Image(systemName: step.symbol).font(.system(size: 18, weight: .light)).frame(width: 26)
                Text(step.title).font(.system(size: 15))
            }
            .foregroundStyle(selected ? Color.white : InstantPrint.frameItem)
            .padding(.leading, 14)
            .frame(width: 197, height: 44, alignment: .leading)
            .background { if selected { RoundedRectangle(cornerRadius: 8).fill(InstantPrint.selectedStep) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            if selected { UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                .fill(InstantPrint.developer).frame(width: 8, height: 44)
            }
        }
        .accessibilityLabel("\(step.title), step \(step.rawValue + 1) of \(StudioStep.allCases.count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(step.title) (⌘\(step.rawValue + 1))")
    }

    /// Screens built in the Instant Print language explain themselves here, in one sentence; the others
    /// still carry their own header until they are rebuilt.
    private var titleStrip: some View {
        HStack(spacing: 10) {
            if session.step == .review, let step = session.step {
                Text(step.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(InstantPrint.frameText)
                    .accessibilityAddTraits(.isHeader)
                Text(step.explanation).font(.system(size: 13.5)).foregroundStyle(InstantPrint.frameMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if session.demoMode { DemoBadge() }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(InstantPrint.frame)
        .contentShape(Rectangle()).gesture(WindowDragGesture())
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text((session.step ?? .images).title).font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text((session.step ?? .images).explanation)
                    .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 660, alignment: .leading)
                StudioTermsHelp(terms: (session.step ?? .images).definitionTerms)
                    .id(session.step)
            }
            Spacer(minLength: 0)
        }.padding([.horizontal, .top], 24)
    }

    /// What the footer reports for the open step, beside the project name.
    private var progress: String? {
        guard let project = session.project else { return nil }
        switch session.step ?? .images {
        case .review:
            return "\(project.images.filter(\.isFinal).count) of \(project.images.count) final"
        case .images:
            return "\(project.images.count) samples"
        default:
            return nil
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
