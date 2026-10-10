import AppKit
import SwiftUI

@MainActor
extension StudioSession {
    func confirmDiscardCaptionDrafts() -> Bool {
        guard let warning = captionDiscardWarning else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved caption edits?"
        alert.informativeText = warning
        alert.addButton(withTitle: "Keep editing")
        alert.addButton(withTitle: "Discard edits")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func confirmClose() -> Bool {
        guard confirmDiscardCaptionDrafts() else { return false }
        guard gpu.hasRunningPod || busy || gpu.isBusy else { return true }
        let alert = NSAlert()
        alert.messageText = gpu.hasRunningPod ? "Stop the rented computer before closing?" : "Cancel the current work?"
        alert.informativeText = gpu.hasRunningPod
            ? "The computer is still running and costing money. Closing will cancel local work and stop it. "
            + "If the stop cannot be confirmed, this project will stay open."
            : "Completed captions are saved. Work still in progress will be cancelled before the project closes."
        alert.addButton(withTitle: "Stop and close")
        alert.addButton(withTitle: "Keep open")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func requestClose() {
        guard confirmClose() else { return }
        Task { await closeProject() }
    }
}

@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var session: StudioSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session, session.needsCloseConfirmation else { return .terminateNow }
        guard session.confirmClose() else { return .terminateCancel }
        Task {
            await session.closeProject()
            sender.reply(toApplicationShouldTerminate: !session.gpu.hasRunningPod)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    let session: StudioSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = context.coordinator }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let session: StudioSession
        var allowed = false
        init(session: StudioSession) {
            self.session = session
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowed { return true }
            guard session.confirmClose() else { return false }
            Task {
                await session.closeProject()
                guard !session.gpu.hasRunningPod else { return }
                allowed = true
                sender.performClose(nil)
            }
            return false
        }
    }
}
