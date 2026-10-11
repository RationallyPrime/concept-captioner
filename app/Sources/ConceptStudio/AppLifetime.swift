import AppKit
import SwiftUI

/// A confirmation the session needs from the person. The window presents it as a SwiftUI alert;
/// `StudioSession.ask(_:)` suspends until it is answered. Nothing here blocks the app modally.
struct StudioPrompt: Identifiable {
    struct RunningWork {
        /// A rented computer is billing.
        let hasRunningPod: Bool
        /// The provider's hourly price for the running computer, when known.
        let hourlyRate: Double?
        /// Estimated GPU spend since the computer was created.
        let spent: Double
        /// Offer to leave the computer running (quitting or closing the window, never on Close project).
        let offerKeepRunning: Bool
        let purpose: StudioClosePurpose
    }

    enum Kind {
        case discardCaptionDrafts(warning: String)
        case stopWork(RunningWork)
        /// Stop everything while a trained result has been neither pushed nor saved.
        case stopWithPendingResult
        /// Raise the spending limit of a running computer.
        case raiseBudget(from: Double, to: Double, hourlyRate: Double?)
    }

    let id = UUID()
    let kind: Kind
    let reply: StudioPromptReply

    var title: String {
        switch kind {
        case .discardCaptionDrafts: "Discard unsaved caption edits?"
        case let .stopWork(work):
            work.hasRunningPod
                ? "Stop the rented computer before \(work.purpose.verb)?"
                : "Cancel the current work before \(work.purpose.verb)?"
        case .stopWithPendingResult: "Your trained model has not been collected yet"
        case let .raiseBudget(_, to, _): "Raise the spending limit to \(StudioMoney.format(to))?"
        }
    }

    var message: String {
        switch kind {
        case let .discardCaptionDrafts(warning): return warning
        case let .stopWork(work): return Self.stopMessage(work)
        case .stopWithPendingResult:
            return "Stopping now can lose the trained model that is still on the rented computer. "
                + "Retrieve it first, or stop anyway if you no longer need it."
        case let .raiseBudget(from, to, rate):
            let hours = rate.map { $0 > 0 ? " That is about \(Self.hours((to - from) / $0)) more at this price." : "" }
                ?? ""
            return "The computer stops automatically at \(StudioMoney.format(to)) "
                + "instead of \(StudioMoney.format(from))." + hours
        }
    }

    var confirmTitle: String {
        switch kind {
        case .discardCaptionDrafts: "Discard edits"
        case let .stopWork(work):
            work.hasRunningPod ? "Stop and \(work.purpose.shortVerb)" : "Cancel work and \(work.purpose.shortVerb)"
        case .stopWithPendingResult: "Retrieve the model first"
        case .raiseBudget: "Raise limit"
        }
    }

    var confirmIsDestructive: Bool {
        if case .discardCaptionDrafts = kind { return true }
        return false
    }

    /// Return answers with the confirm button only where confirming is the safe choice: stopping a billing
    /// computer (the owner's decision) and retrieving a trained model. Discarding edits and spending more
    /// leave Return on the cancel button.
    var confirmIsDefault: Bool {
        switch kind {
        case .stopWork, .stopWithPendingResult: true
        case .discardCaptionDrafts, .raiseBudget: false
        }
    }

    var alternateTitle: String? {
        switch kind {
        case let .stopWork(work) where work.offerKeepRunning: "Keep the computer running"
        case .stopWithPendingResult: "Stop anyway"
        default: nil
        }
    }

    var cancelTitle: String {
        switch kind {
        case .discardCaptionDrafts: "Keep editing"
        case .stopWork, .stopWithPendingResult, .raiseBudget: "Cancel"
        }
    }

    private static func stopMessage(_ work: RunningWork) -> String {
        guard work.hasRunningPod else {
            return "Completed captions are saved. Work still in progress will be cancelled first."
        }
        let price = work.hourlyRate.map { "It costs \(StudioMoney.format($0)) per hour" } ?? "It is still billing"
        var text = "\(price) and has used about \(StudioMoney.format(work.spent)) so far. "
            + "Stop ends GPU billing; saved network storage remains. "
            + "If the stop cannot be confirmed, ConceptStudio stays open so you can retry."
        if work.offerKeepRunning {
            text += "\n\nIf you keep it running, it keeps billing after ConceptStudio closes, and your budget "
                + "and idle limits are not enforced. Reopen ConceptStudio to stop it."
        }
        return text
    }

    private static func hours(_ value: Double) -> String {
        value < 1 ? "\(Int((value * 60).rounded())) minutes" : String(format: "%.1f hours", value)
    }
}

enum StudioPromptChoice {
    case confirm, alternate, cancel
}

enum StudioClosePurpose {
    case closeProject, closeWindow, quit

    var verb: String {
        switch self {
        case .closeProject: "closing the project"
        case .closeWindow: "closing"
        case .quit: "quitting"
        }
    }

    var shortVerb: String {
        switch self {
        case .closeProject, .closeWindow: "close"
        case .quit: "quit"
        }
    }
}

enum StudioCloseDecision: Equatable {
    /// Cancel local work and stop the rented computer. `discardingPendingResult` is set when the person chose
    /// to stop although a trained model has not been collected.
    case stop(discardingPendingResult: Bool)
    /// Cancel local work but leave the rented computer billing; the app shows it again on next launch.
    case keepRunning
}

/// Resumes the awaiting `ask(_:)` exactly once.
@MainActor
final class StudioPromptReply {
    fileprivate var continuation: CheckedContinuation<StudioPromptChoice, Never>?
    /// Set by the first answer; later answers are ignored.
    private(set) var isAnswered = false

    func resolve(_ choice: StudioPromptChoice) {
        isAnswered = true
        continuation?.resume(returning: choice)
        continuation = nil
    }
}

@MainActor
extension StudioSession {
    /// Presents a confirmation in the window and waits for the answer. A newer prompt cancels an older one,
    /// and cancelling the waiting task answers `.cancel` and withdraws the prompt.
    func ask(_ kind: StudioPrompt.Kind) async -> StudioPromptChoice {
        pendingPrompt?.reply.resolve(.cancel)
        let prompt = StudioPrompt(kind: kind, reply: StudioPromptReply())
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .cancel) }
                prompt.reply.continuation = continuation
                pendingPrompt = prompt
            }
        } onCancel: {
            Task { @MainActor in self.answer(prompt, .cancel) }
        }
    }

    func answer(_ prompt: StudioPrompt, _ choice: StudioPromptChoice) {
        if pendingPrompt?.id == prompt.id { pendingPrompt = nil }
        prompt.reply.resolve(choice)
    }

    func discardAllCaptionDrafts() {
        for image in project?.images ?? [] {
            discardCaptionDraft(for: image)
        }
    }

    // INTEGRATION (lane app-contract): that lane gates `useDemo()`, `createProject(at:)` and
    // `openProject(url:)` on its own `pendingConfirmation` / `confirm(_:)` / `whenConfirmed(_:_:)`, which no
    // view presents. Keep one mechanism, this one: implement its `confirm(c)` as `await ask(kind) == .confirm`
    // and `whenConfirmed(c, action)` as a Task doing the same before `action()`, mapping
    // `.discardCaptionDrafts(count:)` to `.discardCaptionDrafts(warning: captionDiscardWarning)`; delete
    // `pendingConfirmation`, `PendingConfirmation` and `resolveConfirmation`. Then the session gates itself, so
    // delete `afterConfirmingDraftDiscard`, `runWithDraftDiscardConfirmed`, `confirmDiscardCaptionDrafts` and
    // `draftDiscardConfirmed`, and call the session methods directly from the menus and Settings.

    /// Runs `action` after the person agrees to discard unsaved caption edits, or at once if there are none.
    /// Every view-level New, Open, Open Recent and demo entry point goes through this.
    ///
    /// The drafts are not cleared here: the action can still refuse (a computer is running), be cancelled
    /// (the folder chooser) or fail (a stale bookmark), and the edits must survive that. `releaseProject()`
    /// clears them when the project really changes.
    func afterConfirmingDraftDiscard(_ action: @escaping @MainActor () -> Void) {
        guard let warning = captionDiscardWarning else { action(); return }
        Task {
            guard await ask(.discardCaptionDrafts(warning: warning)) == .confirm else { return }
            runWithDraftDiscardConfirmed(action)
        }
    }

    /// Runs the synchronous start of `action` with the discard already confirmed, then withdraws the
    /// confirmation so it cannot leak to a later, unconfirmed action.
    func runWithDraftDiscardConfirmed(_ action: @MainActor () -> Void) {
        draftDiscardConfirmed = true
        defer { draftDiscardConfirmed = false }
        action()
    }

    /// Synchronous guard kept for session methods. Views confirm first through `afterConfirmingDraftDiscard`,
    /// so this only refuses (and asks) if a caller skipped that step.
    func confirmDiscardCaptionDrafts() -> Bool {
        if draftDiscardConfirmed { return true }
        guard let warning = captionDiscardWarning else { return true }
        Task {
            guard await ask(.discardCaptionDrafts(warning: warning)) == .confirm else { return }
            discardAllCaptionDrafts()
            message = "Unsaved caption edits discarded. Choose the action again to continue."
        }
        return false
    }

    /// Asks what to do with unsaved edits and running work. `nil` means keep the project open.
    func decideClose(_ purpose: StudioClosePurpose) async -> StudioCloseDecision? {
        if let warning = captionDiscardWarning {
            guard await ask(.discardCaptionDrafts(warning: warning)) == .confirm else { return nil }
        }
        var decision = StudioCloseDecision.stop(discardingPendingResult: false)
        if gpu.hasRunningPod || busy || chatGPT.isBusy || gpu.isBusy {
            let work = StudioPrompt.RunningWork(
                hasRunningPod: gpu.hasRunningPod,
                hourlyRate: gpu.pod.map(\.cost).flatMap { $0 > 0 ? $0 : nil },
                spent: gpu.elapsedCost,
                offerKeepRunning: purpose != .closeProject && gpu.hasRunningPod && !gpu.isBusy && !gpu.isStopping,
                purpose: purpose
            )
            switch await ask(.stopWork(work)) {
            case .confirm: break
            case .alternate: decision = .keepRunning
            case .cancel: return nil
            }
        }
        if decision != .keepRunning, gpu.resultNeedsSaving {
            switch await ask(.stopWithPendingResult) {
            case .confirm:
                await gpu.retrieveResult()
                guard !gpu.resultNeedsSaving else { return nil }
            case .alternate: decision = .stop(discardingPendingResult: true)
            case .cancel: return nil
            }
        }
        // Drafts are left alone: `closeProject()` clears them through `releaseProject()` only once the
        // project really closes, so a stop that cannot be confirmed keeps them.
        return decision
    }

    /// Carries out a close decision. Returns false when the computer could not be confirmed stopped,
    /// in which case the project stays open and the alert explains why.
    func carryOut(_ decision: StudioCloseDecision) async -> Bool {
        switch decision {
        case let .stop(discardingPendingResult):
            if discardingPendingResult {
                await leaveComputerRunning()
                await gpu.stopEverything(discardingPendingResult: true)
            }
            await closeProject()
            return !gpu.hasRunningPod
        case .keepRunning:
            await leaveComputerRunning()
            return true
        }
    }

    /// Cancels local work but leaves the rented computer billing. Its saved record brings it back on next launch.
    /// INTEGRATION (lane app-contract): also cancel and await `editTask` and `analysisTask` once they exist.
    func leaveComputerRunning() async {
        chatGPTWorkGeneration += 1
        await chatGPT.cancelAndWait()
        task?.cancel()
        await task?.value
    }

    func requestClose() {
        Task {
            guard let decision = await decideClose(.closeProject) else { return }
            _ = await carryOut(decision)
        }
    }
}

/// Presents `session.pendingPrompt` as a window-attached alert. The default button is always the safe choice
/// (see `StudioPrompt.confirmIsDefault`).
///
/// Only the buttons answer a prompt; Escape runs the cancel button. The dismissal setter never answers and
/// never touches an unanswered prompt, so it cannot cancel the next prompt in a chain (discard, then stop,
/// then pending result) whatever order SwiftUI calls it in relative to the button action.
struct StudioPromptPresenter: ViewModifier {
    @Bindable var session: StudioSession

    func body(content: Content) -> some View {
        content.alert(
            session.pendingPrompt?.title ?? "",
            isPresented: Binding(
                get: { session.pendingPrompt != nil },
                set: { presented in
                    if !presented, let prompt = session.pendingPrompt, prompt.reply.isAnswered {
                        session.pendingPrompt = nil
                    }
                }
            ),
            presenting: session.pendingPrompt
        ) { prompt in
            Button(prompt.confirmTitle, role: prompt.confirmIsDestructive ? .destructive : nil) {
                session.answer(prompt, .confirm)
            }
            .keyboardShortcut(prompt.confirmIsDefault ? .defaultAction : nil)
            if let alternate = prompt.alternateTitle {
                Button(alternate) { session.answer(prompt, .alternate) }
            }
            Button(prompt.cancelTitle, role: .cancel) { session.answer(prompt, .cancel) }
                .keyboardShortcut(prompt.confirmIsDefault ? nil : .defaultAction)
        } message: { prompt in
            Text(prompt.message)
        }
    }
}

@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var session: StudioSession?

    /// The first pass asks in the window and cancels; the answer re-sends terminate. A confirmed stop then
    /// replies later, once the provider confirms the computer stopped; if it cannot, the app stays open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        switch session.quitDecision {
        case .keepRunning:
            return .terminateNow
        case let .stop(discardingPendingResult)?:
            session.quitDecision = nil
            Task {
                let stopped = await session.carryOut(.stop(discardingPendingResult: discardingPendingResult))
                sender.reply(toApplicationShouldTerminate: stopped)
            }
            return .terminateLater
        case nil:
            guard session.needsCloseConfirmation else { return .terminateNow }
            Task {
                guard let decision = await session.decideClose(.quit) else { return }
                if decision == .keepRunning { _ = await session.carryOut(.keepRunning) }
                session.quitDecision = decision
                sender.terminate(nil)
            }
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Guards closing the studio window. It inserts itself in front of SwiftUI's window delegate and forwards
/// everything else to it, so SwiftUI's own window handling keeps working.
struct WindowCloseGuard: NSViewRepresentable {
    let session: StudioSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSView {
        let view = AttachmentView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.attach(to: view.window)
    }

    final class AttachmentView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let session: StudioSession
        private var allowed = false
        /// SwiftUI's delegate; every message this guard does not handle goes to it.
        private nonisolated(unsafe) var original: (any NSWindowDelegate)?

        init(session: StudioSession) {
            self.session = session
        }

        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            original = window.delegate
            window.delegate = self
        }

        override nonisolated func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || original?.responds(to: aSelector) == true
        }

        override nonisolated func forwardingTarget(for aSelector: Selector!) -> Any? {
            original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowed || !session.needsCloseConfirmation {
                return original?.windowShouldClose?(sender) ?? true
            }
            Task {
                guard let decision = await session.decideClose(.closeWindow),
                      await session.carryOut(decision) else { return }
                // Closing the last window quits; the quit pass must not ask again.
                if decision == .keepRunning { session.quitDecision = .keepRunning }
                allowed = true
                sender.performClose(nil)
            }
            return false
        }
    }
}
