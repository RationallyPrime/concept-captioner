import SwiftUI

@main
struct ConceptStudioApp: App {
    @State private var session = StudioSession()
    @FocusedValue(\.captionSaveAction) private var captionSaveAction
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate

    var body: some Scene {
        Window("ConceptStudio", id: "studio") {
            StudioRootView(session: session).onAppear {
                delegate.session = session
                session.restoreStartupComputer()
            }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New project…") { session.afterConfirmingDraftDiscard { session.createProject() } }
                    .keyboardShortcut("n")
                Button("Open project…") { session.afterConfirmingDraftDiscard { session.openProject() } }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(session.recentPaths, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) {
                            session.afterConfirmingDraftDiscard { session.openRecent(path) }
                        }
                        .help(path)
                    }
                }
                .disabled(session.recentPaths.isEmpty || session.busy)
                Divider()
                Button("Try the demo") { session.afterConfirmingDraftDiscard { session.useDemo() } }
                    .disabled(session.busy || session.gpu.hasRunningPod || session.gpu.isBusy)
            }
            CommandGroup(replacing: .saveItem) {
                Button(captionSaveAction == nil ? "Save project" : "Save caption") {
                    if let captionSaveAction { captionSaveAction.save() } else { session.saveProject() }
                }.keyboardShortcut("s")
                    .disabled(captionSaveAction?.disabled ?? (session.project == nil || session.busy))
                Button("Close project") { session.requestClose() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(session.project == nil)
            }
            JourneyCommands(session: session)
        }
        Settings { StudioSettingsView(session: session) }
    }
}

@MainActor
extension StudioSession {
    func goBack() {
        if let earlier = (step ?? .images).stepBefore { step = earlier }
    }

    func goForward() {
        if let later = (step ?? .images).stepAfter { step = later }
    }
}

/// Go menu: Back and Next through the journey, and a direct shortcut to each screen.
struct JourneyCommands: Commands {
    let session: StudioSession

    var body: some Commands {
        CommandMenu("Go") {
            let current = session.step ?? .images
            // The actions read the step when pressed, not when the menu body was last evaluated.
            Button("Back") { session.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(session.project == nil || current.stepBefore == nil)
            Button("Next") { session.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session.project == nil || current.stepAfter == nil)
            Divider()
            ForEach(Array(StudioStep.allCases.enumerated()), id: \.element) { index, step in
                let button = Button(step.title) { session.step = step }.disabled(session.project == nil)
                if index < 9 {
                    button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    button
                }
            }
        }
    }
}
