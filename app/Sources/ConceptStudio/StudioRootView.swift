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

    private var journey: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("ConceptStudio", systemImage: "square.stack.3d.up")
                        .font(.headline)
                    Text(session.demoMode ? "Practice project" : session.project?.directory
                        .lastPathComponent ?? "Project")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .lineLimit(2).help(session.project?.directory.path ?? "")
                }.padding(20)
                List(selection: $session.step) {
                    Section("Prepare training data") { steps(StudioStep.allCases.prefix(3)) }
                    Section("Write captions") { steps(StudioStep.allCases.dropFirst(3).prefix(3)) }
                    Section("Train your model") { steps(StudioStep.allCases.suffix(3)) }
                }
                .listStyle(.sidebar)
                Divider()
                Button("Close project", systemImage: "rectangle.portrait.and.arrow.right") {
                    session.requestClose()
                }
                .buttonStyle(.plain).foregroundStyle(StudioStyle.supportingText).padding(20)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                screen.padding(24)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .background(StudioStyle.canvas)
                Divider()
                footer
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .toolbar {
                ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") } }
            }
            .onChange(of: session.step, initial: true) { _, step in
                if let step, step.usesRentedComputer { session.prepareGPUStep() }
            }
        }
    }

    private func steps(_ steps: some Sequence<StudioStep>) -> some View {
        ForEach(Array(steps)) { step in
            HStack(spacing: 10) {
                Image(systemName: step.symbol).frame(width: 20)
                Text(step.title)
                Spacer(minLength: 4)
                Text("\(step.rawValue + 1)").font(.caption).monospacedDigit()
                    .foregroundStyle(StudioStyle.supportingText)
            }
            .padding(.vertical, 5)
            .tag(step)
            .accessibilityLabel("\(step.title), step \(step.rawValue + 1) of \(StudioStep.allCases.count)")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text((session.step ?? .images).title).font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text((session.step ?? .images).explanation)
                    .foregroundStyle(StudioStyle.supportingText).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 660, alignment: .leading)
            }
            Spacer(minLength: 0)
            if session.demoMode { DemoBadge() }
        }.padding(24)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.message.isEmpty || session.busy {
                HStack(alignment: .top, spacing: 10) {
                    if session.busy { ProgressView().controlSize(.small) }
                    Text(session.message).font(.callout).foregroundStyle(StudioStyle.supportingText)
                        .lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if session.busy { Button("Cancel") { session.cancel() } }
                }
            }
            HStack(spacing: 12) {
                Button(session.gpu.isStopping ? "Stopping…" : "Stop everything", systemImage: "stop.circle") {
                    session.requestStopEverything()
                }
                .disabled(session.gpu.isStopping)
                .help("Cancel work and stop the rented computer.")
                if session.gpu.hasRunningPod {
                    Text("GPU spend · \(StudioMoney.format(session.gpu.elapsedCost))")
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
                Spacer(minLength: 8)
                let current = session.step ?? .images
                if let previous = current.stepBefore {
                    Button("Back") { session.step = previous }.help("Back to \(previous.title) (⌘[)")
                }
                if let following = current.stepAfter {
                    Button("Next: \(following.title)") { session.step = following }.help("⌘]")
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
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
    /// Journey order comes from `allCases`, so no view hard-codes the number of screens.
    var stepBefore: StudioStep? {
        let steps = Self.allCases
        guard let index = steps.firstIndex(of: self), index > steps.startIndex else { return nil }
        return steps[steps.index(before: index)]
    }

    var stepAfter: StudioStep? {
        let steps = Self.allCases
        guard let index = steps.firstIndex(of: self), steps.index(after: index) < steps.endIndex else { return nil }
        return steps[steps.index(after: index)]
    }

    var usesRentedComputer: Bool {
        [.pods, .training, .monitor].contains(self)
    }
}

extension StudioSession {
    /// Reads the RunPod and Hub keys from the Keychain once per GPU workspace (Settings re-reads after a key
    /// changes); later visits only refresh the project-derived training defaults.
    func prepareGPUStep() {
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
