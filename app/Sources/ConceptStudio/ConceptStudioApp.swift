import SwiftUI

@main
struct ConceptStudioApp: App {
    @State private var session = StudioSession()
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
                Button("New project…") { session.createProject() }.keyboardShortcut("n")
                Button("Open project…") { session.openProject() }.keyboardShortcut("o")
                Button("Save project") { session.saveProject() }.keyboardShortcut("s")
                    .disabled(session.project == nil || session.busy)
                Button("Close project") { session.requestClose() }.disabled(session.project == nil)
            }
        }
        Settings { StudioSettingsView(session: session) }
    }
}
