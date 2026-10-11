import SwiftUI

@main
struct ConceptStudioApp: App {
    @State private var session = StudioSession()
    @FocusedValue(\.captionSaveAction) private var captionSaveAction
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

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
                Button("New project…") {
                    if let url = ProjectAccess
                        .chooseFolder(prompt: "Create project here") { session.createProject(at: url) }
                }
                .keyboardShortcut("n")
                Button("Open project…") {
                    if let url = ProjectAccess.chooseFolder(prompt: "Open project") { session.openProject(url: url) }
                }
                .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(session.recentPaths, id: \.self) { path in
                        Button(RecentProjects.menuLabel(path, among: session.recentPaths)) {
                            session.openRecent(path)
                        }
                        .help(path)
                    }
                }
                .disabled(session.recentPaths.isEmpty || session.busy)
                Divider()
                Button("Try the demo") { session.useDemo() }
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
            CommandGroup(replacing: .help) {
                Button("ConceptStudio Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
        Settings { StudioSettingsView(session: session) }
        Window("ConceptStudio Help", id: "help") {
            StudioHelpView()
        }
        .defaultSize(width: 780, height: 720)
    }
}

@MainActor
extension StudioSession {
    func next() {
        goForward()
    }

    var journeySteps: [StudioStep] {
        StudioStep.allCases.filter { $0 != .mapping || project?.job.requiresLocatorMapping != false }
    }

    var previousStep: StudioStep? {
        let current = step ?? .images
        return journeySteps.last { $0.rawValue < current.rawValue }
    }

    var nextStep: StudioStep? {
        let current = step ?? .images
        return journeySteps.first { $0.rawValue > current.rawValue }
    }

    func goBack() {
        if let earlier = previousStep { step = earlier }
    }

    func goForward() {
        if let later = nextStep { step = later }
    }
}

/// Go menu: Back and Next through the journey, and a direct shortcut to each screen.
struct JourneyCommands: Commands {
    let session: StudioSession

    var body: some Commands {
        CommandMenu("Go") {
            // The actions read the step when pressed, not when the menu body was last evaluated.
            Button("Back") { session.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(session.project == nil || session.previousStep == nil)
            Button("Next") { session.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session.project == nil || session.nextStep == nil)
            Divider()
            ForEach(session.journeySteps) { step in
                let button = Button(step.title) { session.step = step }.disabled(session.project == nil)
                button.keyboardShortcut(KeyEquivalent(Character("\(step.rawValue + 1)")), modifiers: .command)
            }
        }
    }
}
